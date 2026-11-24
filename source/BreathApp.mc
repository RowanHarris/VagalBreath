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
//! Features:
//!   - 5 peer-reviewed vagal-tone / stress-reduction breathing protocols
//!   - Distinct eyes-closed tactile haptic signatures per breath phase
//!   - Live HR, HR drop (Start -> Current), Garmin Stress, and real beat-to-beat RMSSD HRV
//!   - Native Garmin Breathwork FIT recording (SPORT_TRAINING / SUB_SPORT_BREATHING)
class BreathApp extends Application.AppBase {

    private static const STORAGE_KEY_PROTOCOL as String = "vb_protocol_id";
    private static const STORAGE_KEY_DURATION as String = "vb_duration_min";

    // Developer FIT field IDs matching resources/fitcontributions/fitContributions.xml
    private static const FIT_FIELD_PROTOCOL_ID as Number = 0;
    private static const FIT_FIELD_HR_DROP_ID as Number = 1;
    private static const FIT_FIELD_RMSSD_ID as Number = 2;
    private static const FIT_FIELD_CYCLES_ID as Number = 3;

    // 100ms animation tick (10 Hz) for smooth breathing circle pacing on AMOLED
    private static const TICK_INTERVAL_MS as Number = 100;

    private var _protocol as BreathProtocol;
    private var _tracker as VagalMetricsTracker;
    private var _session as ActivityRecording.Session?;

    private var _fitProtocol as FitContributor.Field?;
    private var _fitHrDrop as FitContributor.Field?;
    private var _fitRmssd as FitContributor.Field?;
    private var _fitCycles as FitContributor.Field?;

    private var _tickTimer as Timer.Timer?;
    private var _lastTickMs as Number?;
    private var _sensorPollCounter as Number;
    private var _liveReadyHr as Number?;

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

        _protocol = new BreathProtocol(savedProto, savedDur);
        loadSavedPhaseTimings(savedProto);
        _tracker = new VagalMetricsTracker();
        _session = null;

        _fitProtocol = null;
        _fitHrDrop = null;
        _fitRmssd = null;
        _fitCycles = null;

        _tickTimer = null;
        _lastTickMs = null;
        _sensorPollCounter = 0;
        _liveReadyHr = null;
    }

    public function onStart(state as Dictionary?) as Void {
        Sensor.setEnabledSensors([Sensor.SENSOR_HEARTRATE] as Array<Sensor.SensorType>);
        Sensor.enableSensorEvents(method(:onSensorEvent));

        // Register 1 Hz beat-to-beat R-R interval stream for live RMSSD vagal HRV
        try {
            Sensor.registerSensorDataListener(
                method(:onSensorData),
                {
                    :period => 1,
                    :heartBeatIntervals => { :enabled => true }
                }
            );
        } catch (ex) {
            // Gracefully degrade if HBI listener is unavailable in simulator
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
        }
    }

    public function onTickTimer() as Void {
        var state = _protocol.getState();

        // Sample HR & Stress roughly once per second (every 10 ticks)
        _sensorPollCounter += 1;
        if (_sensorPollCounter >= 10) {
            _sensorPollCounter = 0;
            pollVitals(state == BreathProtocol.STATE_ACTIVE);
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
        } else if (ev == BreathProtocol.EVENT_SESSION_COMPLETE) {
            finalizeCompletedSession();
        }

        WatchUi.requestUpdate();
    }

    // -------------------------------------------------------------------------
    // Settings & Session Lifecycle Controls
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

    public function startSession() as Void {
        if (_protocol.getState() != BreathProtocol.STATE_READY) {
            return;
        }

        _tracker.reset();
        _sensorPollCounter = 0;

        // Seed baseline HR & Stress immediately if already available
        pollVitals(true);

        var session = ActivityRecording.createSession({
            :name => BreathProtocol.getProtocolShortName(_protocol.getProtocolId()),
            :sport => Activity.SPORT_TRAINING,
            :subSport => Activity.SUB_SPORT_BREATHING
        });

        _fitProtocol = session.createField(
            "breath_protocol",
            FIT_FIELD_PROTOCOL_ID,
            FitContributor.DATA_TYPE_UINT8,
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION,
                :units => "id"
            }
        );

        _fitHrDrop = session.createField(
            "hr_drop_bpm",
            FIT_FIELD_HR_DROP_ID,
            FitContributor.DATA_TYPE_SINT16,
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION,
                :units => "bpm"
            }
        );

        _fitRmssd = session.createField(
            "vagal_rmssd",
            FIT_FIELD_RMSSD_ID,
            FitContributor.DATA_TYPE_FLOAT,
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION,
                :units => "ms"
            }
        );

        _fitCycles = session.createField(
            "breath_cycles",
            FIT_FIELD_CYCLES_ID,
            FitContributor.DATA_TYPE_UINT16,
            {
                :mesgType => FitContributor.MESG_TYPE_SESSION,
                :units => "cycles"
            }
        );

        _session = session;
        session.start();

        _protocol.start();
        _lastTickMs = System.getTimer();
        syncFitFields();

        // Cue the opening Inhale phase immediately so user can close eyes right away
        vibrateForPhase(_protocol.getCurrentPhaseType());
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
        vibrateForPhase(_protocol.getCurrentPhaseType());
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
    // Internal Helpers & Eyes-Closed Tactile Haptic Signatures
    // -------------------------------------------------------------------------

    private function finalizeCompletedSession() as Void {
        _lastTickMs = null;
        pollVitals(true);
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

    private function syncFitFields() as Void {
        var fProto = _fitProtocol;
        if (fProto != null) {
            fProto.setData(_protocol.getProtocolId());
        }

        var fHrDrop = _fitHrDrop;
        if (fHrDrop != null) {
            var delta = _tracker.getHeartRateDelta();
            fHrDrop.setData((delta != null) ? delta : 0);
        }

        var fRmssd = _fitRmssd;
        if (fRmssd != null) {
            var rmssd = _tracker.getSessionRmssdMs();
            fRmssd.setData((rmssd != null) ? rmssd : 0.0);
        }

        var fCycles = _fitCycles;
        if (fCycles != null) {
            fCycles.setData(_protocol.getCompletedCycles());
        }
    }

    //! Distinct eyes-closed vibration patterns for every breath phase.
    private function vibrateForPhase(phaseType as Number) as Void {
        var vibe = [] as Array<Attention.VibeProfile>;
        if (phaseType == BreathProtocol.PHASE_INHALE) {
            // Smooth ascending pulse: begin deep nasal inhale
            vibe = [
                new Attention.VibeProfile(30, 80),
                new Attention.VibeProfile(60, 120)
            ] as Array<Attention.VibeProfile>;
        } else if (phaseType == BreathProtocol.PHASE_INHALE_TOP_OFF) {
            // Unmistakable crisp sharp double-tap: Huberman second nasal top-off sip!
            vibe = [
                new Attention.VibeProfile(100, 50),
                new Attention.VibeProfile(0, 55),
                new Attention.VibeProfile(100, 50)
            ] as Array<Attention.VibeProfile>;
        } else if (phaseType == BreathProtocol.PHASE_HOLD_IN || phaseType == BreathProtocol.PHASE_HOLD_OUT) {
            // Quiet subtle micro-tick: begin hold calmly
            vibe = [new Attention.VibeProfile(22, 45)] as Array<Attention.VibeProfile>;
        } else {
            // Gentle descending wave: slow extended vagal exhale
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
