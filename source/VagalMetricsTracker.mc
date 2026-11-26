import Toybox.Lang;
import Toybox.Math;

//! Real-time autonomic & vagal biofeedback tracker with per-stage Lab Mode
//! breakdowns (Pre-Baseline vs. Active Breathing vs. Post-Recovery) and full-session
//! time-series buffers + lossless beat-to-beat R-R capture for FIT export.
class VagalMetricsTracker {

    // Physiological R-R interval bounds (ms): 300ms (200 bpm) .. 2000ms (30 bpm)
    public static const MIN_VALID_RR_MS as Number = 300;
    public static const MAX_VALID_RR_MS as Number = 2000;

    // Artifact rejection: discard single-beat jumps > 25% or > 250ms (wrist-PPG noise/ectopy)
    public static const MAX_RR_JUMP_RATIO as Float = 0.25;
    public static const MAX_RR_JUMP_MS as Number = 250;

    // Rolling RMSSD window (30 successive beat diffs ~ 30s of live vagal tone)
    public static const ROLLING_DIFF_WINDOW as Number = 30;
    public static const MIN_DIFFS_FOR_RMSSD as Number = 5;

    // Max time-series points stored (1 point every 2s -> 540 pts = 18 full minutes)
    public static const MAX_HISTORY_POINTS as Number = 540;

    private static const BASELINE_HR_SAMPLES as Number = 5;

    private var _activeStage as Number; // 1=Baseline, 2=Breathing, 3=Recovery

    private var _startHrSum as Number;
    private var _startHrCount as Number;
    private var _startHrAvg as Float?;
    private var _currentHr as Number?;
    private var _minHr as Number?;
    private var _maxHr as Number?;
    private var _hrSum as Number;
    private var _hrCount as Number;

    // Per-stage accumulators indexed by (stage - 1): 0=Baseline, 1=Breathing, 2=Recovery
    private var _stageHrSum as Array<Number>;
    private var _stageHrCount as Array<Number>;
    private var _stageSqDiffSum as Array<Float>;
    private var _stageSqDiffCount as Array<Number>;

    private var _lastValidRrMs as Number?;
    private var _rollingSqDiffs as Array<Float>;
    private var _sessionSqDiffSum as Float;
    private var _sessionSqDiffCount as Number;

    // Most recent 1-second batch of raw R-R intervals (ms) for FIT record export
    private var _lastBatchRr1 as Number;
    private var _lastBatchRr2 as Number;

    private var _startStress as Number?;
    private var _currentStress as Number?;
    private var _startAutoStress as Number?;
    private var _currentAutoStress as Number?;

    // Post-session graph time-series buffers (-1 means metric not yet available at that sample)
    private var _hrHistory as Array<Number>;
    private var _stressHistory as Array<Number>;
    private var _rmssdHistory as Array<Number>;
    private var _stageHistory as Array<Number>;

    public function initialize() {
        _activeStage = BreathProtocol.STAGE_BASELINE;
        _startHrSum = 0;
        _startHrCount = 0;
        _startHrAvg = null;
        _currentHr = null;
        _minHr = null;
        _maxHr = null;
        _hrSum = 0;
        _hrCount = 0;

        _stageHrSum = [0, 0, 0] as Array<Number>;
        _stageHrCount = [0, 0, 0] as Array<Number>;
        _stageSqDiffSum = [0.0, 0.0, 0.0] as Array<Float>;
        _stageSqDiffCount = [0, 0, 0] as Array<Number>;

        _lastValidRrMs = null;
        _rollingSqDiffs = [] as Array<Float>;
        _sessionSqDiffSum = 0.0;
        _sessionSqDiffCount = 0;

        _lastBatchRr1 = 0;
        _lastBatchRr2 = 0;

        _startStress = null;
        _currentStress = null;
        _startAutoStress = null;
        _currentAutoStress = null;

        _hrHistory = [] as Array<Number>;
        _stressHistory = [] as Array<Number>;
        _rmssdHistory = [] as Array<Number>;
        _stageHistory = [] as Array<Number>;
    }

    public function reset(initialStage as Number) as Void {
        _activeStage = initialStage;
        _startHrSum = 0;
        _startHrCount = 0;
        _startHrAvg = null;
        _currentHr = null;
        _minHr = null;
        _maxHr = null;
        _hrSum = 0;
        _hrCount = 0;

        _stageHrSum = [0, 0, 0] as Array<Number>;
        _stageHrCount = [0, 0, 0] as Array<Number>;
        _stageSqDiffSum = [0.0, 0.0, 0.0] as Array<Float>;
        _stageSqDiffCount = [0, 0, 0] as Array<Number>;

        _lastValidRrMs = null;
        _rollingSqDiffs = [] as Array<Float>;
        _sessionSqDiffSum = 0.0;
        _sessionSqDiffCount = 0;

        _lastBatchRr1 = 0;
        _lastBatchRr2 = 0;

        _startStress = null;
        _currentStress = null;
        _startAutoStress = null;
        _currentAutoStress = null;

        _hrHistory = [] as Array<Number>;
        _stressHistory = [] as Array<Number>;
        _rmssdHistory = [] as Array<Number>;
        _stageHistory = [] as Array<Number>;
    }

    //! Notify tracker of a macro-stage boundary (Baseline -> Breathing -> Recovery).
    //! Breaks R-R pair continuity across stage boundaries for clean per-stage RMSSD.
    public function setActiveStage(stage as Number) as Void {
        if (stage >= BreathProtocol.STAGE_BASELINE && stage <= BreathProtocol.STAGE_RECOVERY) {
            _activeStage = stage;
            _lastValidRrMs = null;
        }
    }

    // -------------------------------------------------------------------------
    // Pure Physiological Conversion Helpers
    // -------------------------------------------------------------------------

    //! Maps vagal RMSSD (ms) onto a Garmin-style 1..100 Autonomic Stress Index using ln(RMSSD).
    public static function computeStressFromRmssd(rmssdMs as Float) as Number {
        var clamped = rmssdMs;
        if (clamped < 5.0) {
            clamped = 5.0;
        }
        var lnVal = Math.ln(clamped).toFloat();
        var raw = 100.0 - ((lnVal - 2.08) * (95.0 / 2.86));
        var score = Math.round(raw).toNumber();
        if (score < 1) {
            score = 1;
        } else if (score > 100) {
            score = 100;
        }
        return score;
    }

    // -------------------------------------------------------------------------
    // Sensor Ingestion & Time-Series Snapshotting
    // -------------------------------------------------------------------------

    public function recordHeartRate(hr as Number?) as Void {
        if (hr == null || hr < 30 || hr > 220) {
            return;
        }
        _currentHr = hr;
        _hrSum += hr;
        _hrCount += 1;

        var sIdx = _activeStage - 1;
        if (sIdx >= 0 && sIdx < 3) {
            _stageHrSum[sIdx] = _stageHrSum[sIdx] + hr;
            _stageHrCount[sIdx] = _stageHrCount[sIdx] + 1;
        }

        var minHr = _minHr;
        if (minHr == null || hr < minHr) {
            _minHr = hr;
        }
        var maxHr = _maxHr;
        if (maxHr == null || hr > maxHr) {
            _maxHr = hr;
        }

        if (_startHrCount < BASELINE_HR_SAMPLES) {
            _startHrSum += hr;
            _startHrCount += 1;
            _startHrAvg = _startHrSum.toFloat() / _startHrCount.toFloat();
        }
    }

    //! Ingest a 1-second batch of raw beat-to-beat R-R intervals (ms).
    public function recordHeartBeatIntervals(intervals as Array<Number>?) as Void {
        _lastBatchRr1 = 0;
        _lastBatchRr2 = 0;

        if (intervals == null) {
            return;
        }
        var count = intervals.size();
        var captured = 0;
        for (var i = 0; i < count; i++) {
            var rr = intervals[i];
            if (rr >= MIN_VALID_RR_MS && rr <= MAX_VALID_RR_MS) {
                if (captured == 0) {
                    _lastBatchRr1 = rr;
                    captured = 1;
                } else if (captured == 1) {
                    _lastBatchRr2 = rr;
                    captured = 2;
                }
            }
            recordSingleRrInterval(rr);
        }
        updateAutonomicStress();
    }

    public function recordSingleRrInterval(rrMs as Number) as Boolean {
        if (rrMs < MIN_VALID_RR_MS || rrMs > MAX_VALID_RR_MS) {
            _lastValidRrMs = null;
            return false;
        }

        var prevRr = _lastValidRrMs;
        if (prevRr == null) {
            _lastValidRrMs = rrMs;
            return true;
        }

        var diff = rrMs - prevRr;
        var absDiff = (diff < 0) ? -diff : diff;
        var ratio = absDiff.toFloat() / prevRr.toFloat();

        if (absDiff > MAX_RR_JUMP_MS || ratio > MAX_RR_JUMP_RATIO) {
            _lastValidRrMs = rrMs;
            return false;
        }

        var sqDiff = diff.toFloat() * diff.toFloat();
        _sessionSqDiffSum += sqDiff;
        _sessionSqDiffCount += 1;

        var sIdx = _activeStage - 1;
        if (sIdx >= 0 && sIdx < 3) {
            _stageSqDiffSum[sIdx] = _stageSqDiffSum[sIdx] + sqDiff;
            _stageSqDiffCount[sIdx] = _stageSqDiffCount[sIdx] + 1;
        }

        pushRollingSqDiff(sqDiff);

        _lastValidRrMs = rrMs;
        return true;
    }

    public function recordStressScore(stress as Number?) as Void {
        if (stress == null || stress < 1 || stress > 100) {
            return;
        }
        if (_startStress == null) {
            _startStress = stress;
        }
        _currentStress = stress;
    }

    //! Append one synchronized snapshot of HR, Stress (0-100), RMSSD (ms), and macro-stage.
    public function recordHistorySnapshot() as Void {
        if (_hrHistory.size() >= MAX_HISTORY_POINTS) {
            return;
        }

        var hrVal = _currentHr;
        _hrHistory.add((hrVal != null) ? hrVal : -1);
        _stageHistory.add(_activeStage);

        var rmssd = getRollingRmssdMs();
        if (rmssd != null) {
            var rmssdInt = Math.round(rmssd).toNumber();
            _rmssdHistory.add(rmssdInt);
            var autoStress = VagalMetricsTracker.computeStressFromRmssd(rmssd);
            _stressHistory.add(autoStress);
            if (_startAutoStress == null) {
                _startAutoStress = autoStress;
            }
            _currentAutoStress = autoStress;
        } else {
            _rmssdHistory.add(-1);
            var fallbackStress = _currentStress;
            _stressHistory.add((fallbackStress != null) ? fallbackStress : -1);
        }
    }

    private function updateAutonomicStress() as Void {
        var rmssd = getRollingRmssdMs();
        if (rmssd != null) {
            var autoStress = VagalMetricsTracker.computeStressFromRmssd(rmssd);
            if (_startAutoStress == null) {
                _startAutoStress = autoStress;
            }
            _currentAutoStress = autoStress;
        }
    }

    private function pushRollingSqDiff(sqDiff as Float) as Void {
        if (_rollingSqDiffs.size() >= ROLLING_DIFF_WINDOW) {
            var trimmed = [] as Array<Float>;
            for (var i = 1; i < ROLLING_DIFF_WINDOW; i++) {
                trimmed.add(_rollingSqDiffs[i]);
            }
            trimmed.add(sqDiff);
            _rollingSqDiffs = trimmed;
        } else {
            _rollingSqDiffs.add(sqDiff);
        }
    }

    // -------------------------------------------------------------------------
    // Per-Stage Lab Comparison Getters (Baseline vs. Breathing vs. Recovery)
    // -------------------------------------------------------------------------

    public function getStageAvgHeartRate(stage as Number) as Number? {
        var idx = stage - 1;
        if (idx < 0 || idx >= 3 || _stageHrCount[idx] <= 0) {
            return null;
        }
        return Math.round(_stageHrSum[idx].toFloat() / _stageHrCount[idx].toFloat()).toNumber();
    }

    public function getStageRmssdMs(stage as Number) as Float? {
        var idx = stage - 1;
        if (idx < 0 || idx >= 3 || _stageSqDiffCount[idx] < MIN_DIFFS_FOR_RMSSD) {
            return null;
        }
        return Math.sqrt(_stageSqDiffSum[idx] / _stageSqDiffCount[idx].toFloat()).toFloat();
    }

    public function getStageAutonomicStress(stage as Number) as Number? {
        var rmssd = getStageRmssdMs(stage);
        if (rmssd == null) {
            return null;
        }
        return VagalMetricsTracker.computeStressFromRmssd(rmssd);
    }

    //! True Lab Mode apples-to-apples HR delta: Recovery Avg HR - Baseline Avg HR.
    public function getLabHrDelta() as Number? {
        var baseHr = getStageAvgHeartRate(BreathProtocol.STAGE_BASELINE);
        var recHr = getStageAvgHeartRate(BreathProtocol.STAGE_RECOVERY);
        if (baseHr == null || recHr == null) {
            return null;
        }
        return recHr - baseHr;
    }

    //! True Lab Mode carried-over vagal delta: Recovery RMSSD - Baseline RMSSD (ms).
    public function getLabRmssdDeltaMs() as Float? {
        var baseR = getStageRmssdMs(BreathProtocol.STAGE_BASELINE);
        var recR = getStageRmssdMs(BreathProtocol.STAGE_RECOVERY);
        if (baseR == null || recR == null) {
            return null;
        }
        return recR - baseR;
    }

    // -------------------------------------------------------------------------
    // General Cardiovascular & Raw R-R Getters
    // -------------------------------------------------------------------------

    public function getCurrentHeartRate() as Number? {
        return _currentHr;
    }

    public function getStartHeartRateRounded() as Number? {
        var startAvg = _startHrAvg;
        if (startAvg == null) {
            return null;
        }
        return Math.round(startAvg).toNumber();
    }

    public function getMinHeartRate() as Number? {
        return _minHr;
    }

    public function getMaxHeartRate() as Number? {
        return _maxHr;
    }

    public function getAvgHeartRateRounded() as Number? {
        if (_hrCount <= 0) {
            return null;
        }
        return Math.round(_hrSum.toFloat() / _hrCount.toFloat()).toNumber();
    }

    public function getHeartRateDelta() as Number? {
        var cur = _currentHr;
        var startAvg = _startHrAvg;
        if (cur == null || startAvg == null) {
            return null;
        }
        return Math.round(cur.toFloat() - startAvg).toNumber();
    }

    public function getRollingRmssdMs() as Float? {
        var n = _rollingSqDiffs.size();
        if (n < MIN_DIFFS_FOR_RMSSD) {
            return null;
        }
        var sum = 0.0;
        for (var i = 0; i < n; i++) {
            sum += _rollingSqDiffs[i];
        }
        return Math.sqrt(sum / n.toFloat()).toFloat();
    }

    public function getSessionRmssdMs() as Float? {
        if (_sessionSqDiffCount < MIN_DIFFS_FOR_RMSSD) {
            return null;
        }
        return Math.sqrt(_sessionSqDiffSum / _sessionSqDiffCount.toFloat()).toFloat();
    }

    public function getValidRrPairCount() as Number {
        return _sessionSqDiffCount;
    }

    public function getLastBatchRr1() as Number {
        return _lastBatchRr1;
    }

    public function getLastBatchRr2() as Number {
        return _lastBatchRr2;
    }

    public function getStartEffectiveStress() as Number? {
        var autoStart = _startAutoStress;
        if (autoStart != null) {
            return autoStart;
        }
        return _startStress;
    }

    public function getCurrentEffectiveStress() as Number? {
        var autoCur = _currentAutoStress;
        if (autoCur != null) {
            return autoCur;
        }
        return _currentStress;
    }

    public function getHrHistory() as Array<Number> {
        return _hrHistory;
    }

    public function getStressHistory() as Array<Number> {
        return _stressHistory;
    }

    public function getRmssdHistory() as Array<Number> {
        return _rmssdHistory;
    }

    public function getStageHistory() as Array<Number> {
        return _stageHistory;
    }
}
