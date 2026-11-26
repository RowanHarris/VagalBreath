import Toybox.Activity;
import Toybox.ActivityMonitor;
import Toybox.ActivityRecording;
import Toybox.Application;
import Toybox.Application.Storage;
import Toybox.Attention;
import Toybox.FitContributor;
import Toybox.Lang;
import Toybox.Math;
import Toybox.Sensor;
import Toybox.System;
import Toybox.Timer;
import Toybox.WatchUi;

//! Main entry point and session controller for VagalBreath (Garmin Venu 3).
//!
//! Includes Lab Mode (default ON): 2 min Pre-Baseline -> Active Breathing -> 5 min Post-Recovery,
//! partitioned by session.addLap() and logged at 1 Hz with raw beat-to-beat R-R intervals,
//! stage codes, live RMSSD, live Autonomic Stress, and Baseline vs. Recovery session summaries.
class BreathApp extends Application.AppBase {

    public static const SUMMARY_PAGE_COUNT as Number = 4;

    private static const STORAGE_KEY_PROTOCOL as String = "vb_protocol_id";
    private static const STORAGE_KEY_DURATION as String = "vb_duration_min";
    private static const STORAGE_KEY_LAB_MODE as String = "vb_lab_mode";

    // Developer FIT field IDs matching resources/fitcontributions/fitContributions.xml
    private static const FIT_FIELD_PROTOCOL_ID as Number = 0;
    private static const FIT_FIELD_HR_DROP_ID as Number = 1;
    private static const FIT_FIELD_RMSSD_ID as Number = 2;
    private static const FIT_FIELD_CYCLES_ID as Number = 3;
    private static const FIT_FIELD_LIVE_RMSSD_ID as Number = 4;
    private static const FIT_FIELD_LIVE_STRESS_ID as Number = 5;
    private static const FIT_FIELD_STAGE_CODE_ID as Number = 6;
    private static const FIT_FIELD_RR1_ID as Number = 7;
    private static const FIT_FIELD_RR2_ID as Number = 8;
    private static const FIT_FIELD_BASE_RMSSD_ID as Number = 9;
    private static const FIT_FIELD_REC_RMSSD_ID as Number = 10;
    private static const FIT_FIELD_BASE_HR_ID as Number = 11;
    private static const FIT_FIELD_REC_HR_ID as Number = 12;

    // 100ms animation tick (10 Hz) for smooth breathing circle pacing on AMOLED
    private static const TICK_INTERVAL_MS as Number = 100;

    private var _protocol as BreathProtocol;
    private var _tracker as VagalMetricsTracker;
    private var _session as ActivityRecording.Session?;

    private var _fitProtocol as FitContributor.Field?;
    private var _fitHrDrop as FitContributor.Field?;
    private var _fitRmssd as FitContributor.Field?;
    private var _fitCycles as FitContributor.Field?;
    private var _fitLiveRmssd as FitContributor.Field?;
    private var _fitLiveStress as FitContributor.Field?;
    private var _fitStageCode as FitContributor.Field?;
    private var _fitRr1 as FitContributor.Field?;
    private var _fitRr2 as FitContributor.Field?;
    private var _fitBaseRmssd as FitContributor.Field?;
    private var _fitRecRmssd as FitContributor.Field?;
    private var _fitBaseHr as FitContributor.Field?;
    private var _fitRecHr as FitContributor.Field?;

    private var _tickTimer as Timer.Timer?;
    private var _lastTickMs as Number?;
    private var _sensorPollCounter as Number;
    private var _historyPollCounter as Number;
    private var _liveReadyHr as Number?;
    private var _summaryPage as Number;

    public function initialize() {
        AppBase.initialize();

        var savedProto = BreathProtocol.PROTO_CYCLIC_SIGH;
        var rawProto = Storage.getValue(STORAGE_KEY_PROTOCOL);
        if (rawProto instanceof Number) {
            savedProto = rawProto;
        }

        var savedDur = BreathProtocol.DURATION_5_MIN;
        var rawDur = Storage.getValue(STORAGE_KEY_DURATION);
        if (rawDur instanceof Number) {
            savedDur = rawDur;
        }

        // Lab Mode defaults ON so every protocol trial captures 2m Baseline + 5m Recovery
        var savedLabMode = true;
        var rawLab = Storage.getValue(STORAGE_KEY_LAB_MODE);
        if (rawLab instanceof Boolean) {
            savedLabMode = rawLab;
        }

        _protocol = new BreathProtocol(savedProto, savedDur, savedLabMode);
        loadSavedPhaseTimings(savedProto);
        _tracker = new VagalMetricsTracker();
        _session = null;

        _fitProtocol = null;
        _fitHrDrop = null;
        _fitRmssd = null;
        _fitCycles = null;
        _fitLiveRmssd = null;
        _fitLiveStress = null;
        _fitStageCode = null;
        _fitRr1 = null;
        _fitRr2 = null;
        _fitBaseRmssd = null;
        _fitRecRmssd = null;
        _fitBaseHr = null;
        _fitRecHr = null;

        _tickTimer = null;
        _lastTickMs = null;
        _sensorPollCounter = 0;
        _historyPollCounter = 0;
        _liveReadyHr = null;
        _summaryPage = 0;
    }

    public function onStart(state as Dictionary?) as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE] as Array<Sensor.SensorType>);
        Sensor.enableSensorEvents(method(:onSensorEvent));

        try {
            Sensor.registerSensorDataListener(
                method(:onSensorData),
                {
                    :period => 1,
                    :heartBeatIntervals => { :enabled => true }
                }
            );
        } catch (ex) {
        }

        var tickTimer = new Timer.Timer();
        tickTimer.start(method(:onTickTimer), TICK_INTERVAL_MS, true);
        _tickTimer = tickTimer;
    }

    public function onStop(state as Dictionary?) as Void {
        var tickTimer = _tickTimer;
        if (tickTimer != null) {
            tickTimer.stop();
            _tickTimer = null;
        }

        try {
            Sensor.unregisterSensorDataListener();
        } catch (ex) {
        }
        Sensor.enableSensorEvents(null);

        var session = _session;
        if (session != null && session.isRecording()) {
            syncFitFields();
            session.stop();
        }
    }

    public function getInitialView() as [WatchUi.Views] or [WatchUi.Views, WatchUi.InputDelegates] {
        var view = new BreathView(self);
        var delegate = new BreathDelegate(self);
        return [view, delegate];
    }

    // -------------------------------------------------------------------------
    // Sensor & Animation Tick Callbacks
    // -------------------------------------------------------------------------

    public function onSensorEvent(sensorInfo as Sensor.Info) as Void {
        var hr = sensorInfo.heartRate;
        if (hr != null && hr > 0) {
            _liveReadyHr = hr;
            if (_protocol.getState() == BreathProtocol.STATE_ACTIVE) {
                _tracker.recordHeartRate(hr);
            }
        }
    }

    public function onSensorData(data as Sensor.SensorData) as Void {
        if (_protocol.getState() != BreathProtocol.STATE_ACTIVE) {
            return;
        }
        var hrData = data.heartRateData;
        if (hrData != null) {
            _tracker.recordHeartBeatIntervals(hrData.heartBeatIntervals);
            syncRawRrFitFields();
        }
    }

    public function onTickTimer() as Void {
        var state = _protocol.getState();

        // Sample HR, Stress, and per-second FIT record fields once per second
        _sensorPollCounter += 1;
        if (_sensorPollCounter >= 10) {
            _sensorPollCounter = 0;
            pollVitals(state == BreathProtocol.STATE_ACTIVE);
            if (state == BreathProtocol.STATE_ACTIVE) {
                syncRecordFitFields();
                _historyPollCounter += 1;
                if (_historyPollCounter >= 2) {
                    _historyPollCounter = 0;
                    _tracker.recordHistorySnapshot();
                }
            }
        }

        if (state != BreathProtocol.STATE_ACTIVE) {
            return;
        }

        var nowMs = System.getTimer();
        var deltaMs = TICK_INTERVAL_MS;
        var prevTick = _lastTickMs;
        if (prevTick != null) {
            var diff = nowMs - prevTick;
            if (diff > 0 && diff < 5000) {
                deltaMs = diff;
            }
        }
        _lastTickMs = nowMs;

        var ev = _protocol.tick(deltaMs);
        if (ev == BreathProtocol.EVENT_PHASE_CHANGED) {
            vibrateForPhase(_protocol.getCurrentPhaseType());
            syncFitFields();
        } else if (ev == BreathProtocol.EVENT_ENTER_BREATHING) {
            markFitLapBoundary(BreathProtocol.STAGE_BREATHING);
            vibrateStageStartBreathing();
            syncFitFields();
        } else if (ev == BreathProtocol.EVENT_ENTER_RECOVERY) {
            markFitLapBoundary(BreathProtocol.STAGE_RECOVERY);
            vibrateStageEnterRecovery();
            syncFitFields();
        } else if (ev == BreathProtocol.EVENT_SESSION_COMPLETE) {
            finalizeCompletedSession();
        }

        WatchUi.requestUpdate();
    }

    // -------------------------------------------------------------------------
    // Settings, Summary Navigation & Session Lifecycle
    // -------------------------------------------------------------------------

    public function selectProtocol(protocolId as Number) as Void {
        _protocol.setProtocol(protocolId);
        loadSavedPhaseTimings(_protocol.getProtocolId());
        Storage.setValue(STORAGE_KEY_PROTOCOL, _protocol.getProtocolId());
        WatchUi.requestUpdate();
    }

    public function setCustomPhaseDuration(phaseIndex as Number, durationMs as Number) as Void {
        if (_protocol.setPhaseDurationMs(phaseIndex, durationMs)) {
            Storage.setValue(phaseStorageKey(_protocol.getProtocolId(), phaseIndex), durationMs);
            WatchUi.requestUpdate();
        }
    }

    public function resetCurrentProtocolTimings() as Void {
        var protoId = _protocol.getProtocolId();
        var count = _protocol.getPhaseCount();
        for (var i = 0; i < count; i++) {
            Storage.deleteValue(phaseStorageKey(protoId, i));
        }
        _protocol.resetCurrentProtocolDefaults();
        WatchUi.requestUpdate();
    }

    public function toggleLabMode() as Boolean {
        var next = !_protocol.isLabModeEnabled();
        _protocol.setLabModeEnabled(next);
        Storage.setValue(STORAGE_KEY_LAB_MODE, next);
        WatchUi.requestUpdate();
        return next;
    }

    private function phaseStorageKey(protocolId as Number, phaseIndex as Number) as String {
        return "vb_p" + protocolId.format("%d") + "_d" + phaseIndex.format("%d");
    }

    private function loadSavedPhaseTimings(protocolId as Number) as Void {
        var count = _protocol.getPhaseCount();
        for (var i = 0; i < count; i++) {
            var raw = Storage.getValue(phaseStorageKey(protocolId, i));
            if (raw instanceof Number) {
                _protocol.setPhaseDurationMs(i, raw);
            }
        }
    }

    public function selectDurationMinutes(minutes as Number) as Void {
        _protocol.setDurationMinutes(minutes);
        Storage.setValue(STORAGE_KEY_DURATION, _protocol.getDurationMinutes());
        WatchUi.requestUpdate();
    }

    public function nextSummaryPage() as Void {
        _summaryPage = (_summaryPage + 1) % SUMMARY_PAGE_COUNT;
        WatchUi.requestUpdate();
    }

    public function prevSummaryPage() as Void {
        _summaryPage = (_summaryPage + SUMMARY_PAGE_COUNT - 1) % SUMMARY_PAGE_COUNT;
        WatchUi.requestUpdate();
    }

    public function getSummaryPage() as Number {
        return _summaryPage;
    }

    public function startSession() as Void {
        if (_protocol.getState() != BreathProtocol.STATE_READY) {
            return;
        }

        _protocol.start();
        var initialStage = _protocol.getActiveStage();

        _tracker.reset(initialStage);
        _sensorPollCounter = 0;
        _historyPollCounter = 0;
        _summaryPage = 0;

        pollVitals(true);
        _tracker.recordHistorySnapshot();

        var sessionName = BreathProtocol.getProtocolShortName(_protocol.getProtocolId());
        if (_protocol.isLabModeEnabled()) {
            sessionName = sessionName + " Lab";
        }

        var session = ActivityRecording.createSession({
            :name => sessionName,
            :sport => Activity.SPORT_TRAINING,
            :subSport => Activity.SUB_SPORT_BREATHING
        });

        _fitProtocol = session.createField(
            "breath_protocol",
            FIT_FIELD_PROTOCOL_ID,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "id" }
        );

        _fitHrDrop = session.createField(
            "hr_drop_bpm",
            FIT_FIELD_HR_DROP_ID,
            FitContributor.DATA_TYPE_SINT16,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "bpm" }
        );

        _fitRmssd = session.createField(
            "vagal_rmssd",
            FIT_FIELD_RMSSD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "ms" }
        );

        _fitCycles = session.createField(
            "breath_cycles",
            FIT_FIELD_CYCLES_ID,
            FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "cycles" }
        );

        _fitLiveRmssd = session.createField(
            "live_rmssd",
            FIT_FIELD_LIVE_RMSSD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "ms" }
        );

        _fitLiveStress = session.createField(
            "live_stress",
            FIT_FIELD_LIVE_STRESS_ID,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "pts" }
        );

        _fitStageCode = session.createField(
            "stage_code",
            FIT_FIELD_STAGE_CODE_ID,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "stage" }
        );

        _fitRr1 = session.createField(
            "rr1_ms",
            FIT_FIELD_RR1_ID,
            FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "ms" }
        );

        _fitRr2 = session.createField(
            "rr2_ms",
            FIT_FIELD_RR2_ID,
            FitContributor.DATA_TYPE_UINT16,
            { :mesgType => FitContributor.MESG_TYPE_RECORD, :units => "ms" }
        );

        _fitBaseRmssd = session.createField(
            "base_rmssd",
            FIT_FIELD_BASE_RMSSD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "ms" }
        );

        _fitRecRmssd = session.createField(
            "rec_rmssd",
            FIT_FIELD_REC_RMSSD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "ms" }
        );

        _fitBaseHr = session.createField(
            "base_hr",
            FIT_FIELD_BASE_HR_ID,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "bpm" }
        );

        _fitRecHr = session.createField(
            "rec_hr",
            FIT_FIELD_REC_HR_ID,
            FitContributor.DATA_TYPE_UINT8,
            { :mesgType => FitContributor.MESG_TYPE_SESSION, :units => "bpm" }
        );

        _session = session;
        session.start();

        _lastTickMs = System.getTimer();
        syncRecordFitFields();
        syncFitFields();

        if (initialStage == BreathProtocol.STAGE_BASELINE) {
            vibrateSoftStart();
        } else {
            vibrateForPhase(_protocol.getCurrentPhaseType());
        }
        WatchUi.requestUpdate();
    }

    public function pauseSession() as Void {
        if (_protocol.getState() != BreathProtocol.STATE_ACTIVE) {
            return;
        }
        _protocol.pause();
        _lastTickMs = null;

        var session = _session;
        if (session != null && session.isRecording()) {
            session.stop();
        }
        syncFitFields();
        WatchUi.requestUpdate();
    }

    public function resumeSession() as Void {
        if (_protocol.getState() != BreathProtocol.STATE_PAUSED) {
            return;
        }
        var session = _session;
        if (session != null && !session.isRecording()) {
            session.start();
        }
        _protocol.resume();
        _lastTickMs = System.getTimer();
        if (_protocol.getActiveStage() == BreathProtocol.STAGE_BREATHING) {
            vibrateForPhase(_protocol.getCurrentPhaseType());
        } else {
            vibrateSoftStart();
        }
        WatchUi.requestUpdate();
    }

    public function finishToReview() as Void {
        _protocol.completeEarly();
        finalizeCompletedSession();
        WatchUi.requestUpdate();
    }

    public function finishAndSave() as Void {
        pollVitals(true);
        syncFitFields();

        var session = _session;
        if (session != null) {
            if (session.isRecording()) {
                session.stop();
            }
            session.save();
            _session = null;
        }

        _protocol.resetSession();
        System.exit();
    }

    public function discardAndExit() as Void {
        var session = _session;
        if (session != null) {
            if (session.isRecording()) {
                session.stop();
            }
            session.discard();
            _session = null;
        }

        _protocol.resetSession();
        System.exit();
    }

    // -------------------------------------------------------------------------
    // Public Getters
    // -------------------------------------------------------------------------

    public function getProtocol() as BreathProtocol {
        return _protocol;
    }

    public function getTracker() as VagalMetricsTracker {
        return _tracker;
    }

    public function getDisplayHeartRate() as Number? {
        var tracked = _tracker.getCurrentHeartRate();
        if (tracked != null) {
            return tracked;
        }
        return _liveReadyHr;
    }

    // -------------------------------------------------------------------------
    // Internal FIT & Haptic Helpers
    // -------------------------------------------------------------------------

    private function markFitLapBoundary(newStage as Number) as Void {
        var session = _session;
        if (session != null && session.isRecording()) {
            session.addLap();
        }
        _tracker.setActiveStage(newStage);
        _tracker.recordHistorySnapshot();
        syncRecordFitFields();
    }

    private function finalizeCompletedSession() as Void {
        _lastTickMs = null;
        _summaryPage = 0;
        pollVitals(true);
        _tracker.recordHistorySnapshot();
        syncFitFields();

        var session = _session;
        if (session != null && session.isRecording()) {
            session.stop();
        }
        vibrateComplete();
    }

    private function pollVitals(recordIntoTracker as Boolean) as Void {
        var hr = null;
        var actInfo = Activity.getActivityInfo();
        if (actInfo != null && actInfo.currentHeartRate != null) {
            hr = actInfo.currentHeartRate;
        } else {
            var sInfo = Sensor.getInfo();
            var sensorHr = sInfo.heartRate;
            if (sensorHr != null) {
                hr = sensorHr;
            }
        }

        if (hr != null && hr > 0) {
            _liveReadyHr = hr;
            if (recordIntoTracker) {
                _tracker.recordHeartRate(hr);
            }
        }

        if (recordIntoTracker) {
            var amInfo = ActivityMonitor.getInfo();
            var stress = amInfo.stressScore;
            if (stress != null) {
                _tracker.recordStressScore(stress);
            }
        }
    }

    private function syncRawRrFitFields() as Void {
        var fRr1 = _fitRr1;
        if (fRr1 != null) {
            fRr1.setData(_tracker.getLastBatchRr1());
        }
        var fRr2 = _fitRr2;
        if (fRr2 != null) {
            fRr2.setData(_tracker.getLastBatchRr2());
        }
    }

    private function syncRecordFitFields() as Void {
        var fStage = _fitStageCode;
        if (fStage != null) {
            fStage.setData(_protocol.getActiveStage());
        }

        var rmssd = _tracker.getRollingRmssdMs();
        if (rmssd != null) {
            var fLiveRmssd = _fitLiveRmssd;
            if (fLiveRmssd != null) {
                fLiveRmssd.setData(rmssd);
            }
            var fLiveStress = _fitLiveStress;
            if (fLiveStress != null) {
                fLiveStress.setData(VagalMetricsTracker.computeStressFromRmssd(rmssd));
            }
        }
    }

    private function syncFitFields() as Void {
        var fProto = _fitProtocol;
        if (fProto != null) {
            fProto.setData(_protocol.getProtocolId());
        }

        // Prefer true Lab Mode (Recovery - Baseline) delta when available
        var fHrDrop = _fitHrDrop;
        if (fHrDrop != null) {
            var labDelta = _tracker.getLabHrDelta();
            var delta = (labDelta != null) ? labDelta : _tracker.getHeartRateDelta();
            fHrDrop.setData((delta != null) ? delta : 0);
        }

        var fRmssd = _fitRmssd;
        if (fRmssd != null) {
            var recRmssd = _tracker.getStageRmssdMs(BreathProtocol.STAGE_RECOVERY);
            var rmssd = (recRmssd != null) ? recRmssd : _tracker.getSessionRmssdMs();
            fRmssd.setData((rmssd != null) ? rmssd : 0.0);
        }

        var fCycles = _fitCycles;
        if (fCycles != null) {
            fCycles.setData(_protocol.getCompletedCycles());
        }

        var fBaseR = _fitBaseRmssd;
        if (fBaseR != null) {
            var br = _tracker.getStageRmssdMs(BreathProtocol.STAGE_BASELINE);
            fBaseR.setData((br != null) ? br : 0.0);
        }

        var fRecR = _fitRecRmssd;
        if (fRecR != null) {
            var rr = _tracker.getStageRmssdMs(BreathProtocol.STAGE_RECOVERY);
            fRecR.setData((rr != null) ? rr : 0.0);
        }

        var fBaseHr = _fitBaseHr;
        if (fBaseHr != null) {
            var bh = _tracker.getStageAvgHeartRate(BreathProtocol.STAGE_BASELINE);
            fBaseHr.setData((bh != null) ? bh : 0);
        }

        var fRecHr = _fitRecHr;
        if (fRecHr != null) {
            var rh = _tracker.getStageAvgHeartRate(BreathProtocol.STAGE_RECOVERY);
            fRecHr.setData((rh != null) ? rh : 0);
        }
    }

    private function vibrateSoftStart() as Void {
        var vibe = [new Attention.VibeProfile(35, 100)] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }

    private function vibrateStageStartBreathing() as Void {
        var vibe = [
            new Attention.VibeProfile(60, 100),
            new Attention.VibeProfile(0, 70),
            new Attention.VibeProfile(75, 150)
        ] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }

    private function vibrateStageEnterRecovery() as Void {
        var vibe = [
            new Attention.VibeProfile(55, 120),
            new Attention.VibeProfile(0, 80),
            new Attention.VibeProfile(25, 180)
        ] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }

    private function vibrateForPhase(phaseType as Number) as Void {
        var vibe = [] as Array<Attention.VibeProfile>;
        if (phaseType == BreathProtocol.PHASE_INHALE) {
            vibe = [
                new Attention.VibeProfile(30, 80),
                new Attention.VibeProfile(60, 120)
            ] as Array<Attention.VibeProfile>;
        } else if (phaseType == BreathProtocol.PHASE_INHALE_TOP_OFF) {
            vibe = [
                new Attention.VibeProfile(100, 50),
                new Attention.VibeProfile(0, 55),
                new Attention.VibeProfile(100, 50)
            ] as Array<Attention.VibeProfile>;
        } else if (phaseType == BreathProtocol.PHASE_HOLD_IN || phaseType == BreathProtocol.PHASE_HOLD_OUT) {
            vibe = [new Attention.VibeProfile(22, 45)] as Array<Attention.VibeProfile>;
        } else {
            vibe = [
                new Attention.VibeProfile(55, 110),
                new Attention.VibeProfile(22, 190)
            ] as Array<Attention.VibeProfile>;
        }
        Attention.vibrate(vibe);
    }

    private function vibrateComplete() as Void {
        var vibe = [
            new Attention.VibeProfile(70, 110),
            new Attention.VibeProfile(0, 85),
            new Attention.VibeProfile(45, 130),
            new Attention.VibeProfile(0, 85),
            new Attention.VibeProfile(25, 180)
        ] as Array<Attention.VibeProfile>;
        Attention.vibrate(vibe);
    }
}
