import Toybox.Lang;
import Toybox.Math;

//! Real-time autonomic & vagal biofeedback tracker with full-session time-series
//! history for post-session Heart Rate, Autonomic Stress (0-100), and RMSSD HRV graphs.
//!
//! Computes:
//!   - Baseline Start HR (averaged over initial 5 valid samples), Min/Avg/Max HR, and live HR delta
//!   - Rolling & Session-Mean RMSSD HRV (ms) from beat-to-beat R-R intervals
//!     (Sensor.HeartRateData.heartBeatIntervals) with Malik physiological artifact filtering
//!   - Continuous HRV-derived Autonomic Stress Index (0-100) via ln(RMSSD) mapping
//!   - Downsampled/capped time-series buffers (every 2s, up to 320 points = >10 min)
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

    // Max time-series points stored (1 point every 2s -> 320 pts covers > 10.6 min)
    public static const MAX_HISTORY_POINTS as Number = 320;

    // Baseline Start HR averaging sample count
    private static const BASELINE_HR_SAMPLES as Number = 5;

    private var _startHrSum as Number;
    private var _startHrCount as Number;
    private var _startHrAvg as Float?;
    private var _currentHr as Number?;
    private var _minHr as Number?;
    private var _maxHr as Number?;
    private var _hrSum as Number;
    private var _hrCount as Number;

    private var _lastValidRrMs as Number?;
    private var _rollingSqDiffs as Array<Float>;
    private var _sessionSqDiffSum as Float;
    private var _sessionSqDiffCount as Number;

    private var _startStress as Number?;
    private var _currentStress as Number?;
    private var _startAutoStress as Number?;
    private var _currentAutoStress as Number?;

    // Post-session graph time-series buffers (-1 means metric not yet available at that sample)
    private var _hrHistory as Array<Number>;
    private var _stressHistory as Array<Number>;
    private var _rmssdHistory as Array<Number>;

    public function initialize() {
        _startHrSum = 0;
        _startHrCount = 0;
        _startHrAvg = null;
        _currentHr = null;
        _minHr = null;
        _maxHr = null;
        _hrSum = 0;
        _hrCount = 0;

        _lastValidRrMs = null;
        _rollingSqDiffs = [] as Array<Float>;
        _sessionSqDiffSum = 0.0;
        _sessionSqDiffCount = 0;

        _startStress = null;
        _currentStress = null;
        _startAutoStress = null;
        _currentAutoStress = null;

        _hrHistory = [] as Array<Number>;
        _stressHistory = [] as Array<Number>;
        _rmssdHistory = [] as Array<Number>;
    }

    public function reset() as Void {
        _startHrSum = 0;
        _startHrCount = 0;
        _startHrAvg = null;
        _currentHr = null;
        _minHr = null;
        _maxHr = null;
        _hrSum = 0;
        _hrCount = 0;

        _lastValidRrMs = null;
        _rollingSqDiffs = [] as Array<Float>;
        _sessionSqDiffSum = 0.0;
        _sessionSqDiffCount = 0;

        _startStress = null;
        _currentStress = null;
        _startAutoStress = null;
        _currentAutoStress = null;

        _hrHistory = [] as Array<Number>;
        _stressHistory = [] as Array<Number>;
        _rmssdHistory = [] as Array<Number>;
    }

    // -------------------------------------------------------------------------
    // Pure Physiological Conversion Helpers
    // -------------------------------------------------------------------------

    //! Maps vagal RMSSD (ms) onto a Garmin-style 1..100 Autonomic Stress Index using ln(RMSSD).
    //! Higher RMSSD (stronger vagal tone) -> lower Stress (<25 Rest, 26-50 Low, 51-75 Med, 76+ High).
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

    //! Ingest a live heart rate sample (bpm) during an active session.
    public function recordHeartRate(hr as Number?) as Void {
        if (hr == null || hr < 30 || hr > 220) {
            return;
        }
        _currentHr = hr;
        _hrSum += hr;
        _hrCount += 1;

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

    //! Ingest an array of beat-to-beat R-R intervals (ms) from SensorData.heartRateData.
    public function recordHeartBeatIntervals(intervals as Array<Number>?) as Void {
        if (intervals == null) {
            return;
        }
        var count = intervals.size();
        for (var i = 0; i < count; i++) {
            recordSingleRrInterval(intervals[i]);
        }
        updateAutonomicStress();
    }

    //! Validate and ingest one R-R interval (ms) with Malik physiological artifact filtering.
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
        pushRollingSqDiff(sqDiff);

        _lastValidRrMs = rrMs;
        return true;
    }

    //! Record Garmin all-day stress score (1..100) when available.
    public function recordStressScore(stress as Number?) as Void {
        if (stress == null || stress < 1 || stress > 100) {
            return;
        }
        if (_startStress == null) {
            _startStress = stress;
        }
        _currentStress = stress;
    }

    //! Append one synchronized snapshot of HR, Stress (0-100), and rolling RMSSD (ms)
    //! for the post-session graphs. Call every ~2 seconds while session is active.
    public function recordHistorySnapshot() as Void {
        if (_hrHistory.size() >= MAX_HISTORY_POINTS) {
            return;
        }

        var hrVal = _currentHr;
        _hrHistory.add((hrVal != null) ? hrVal : -1);

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
    // Computed Vagal & Cardiovascular Readouts
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

    //! Live heart rate change in bpm (currentHR - startHR). Negative indicates HR dropped.
    public function getHeartRateDelta() as Number? {
        var cur = _currentHr;
        var startAvg = _startHrAvg;
        if (cur == null || startAvg == null) {
            return null;
        }
        return Math.round(cur.toFloat() - startAvg).toNumber();
    }

    //! Rolling RMSSD HRV (ms) over recent ~30s of artifact-filtered beat-to-beat intervals.
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

    //! Full-session mean RMSSD HRV (ms) for post-session summary and FIT logging.
    public function getSessionRmssdMs() as Float? {
        if (_sessionSqDiffCount < MIN_DIFFS_FOR_RMSSD) {
            return null;
        }
        return Math.sqrt(_sessionSqDiffSum / _sessionSqDiffCount.toFloat()).toFloat();
    }

    public function getValidRrPairCount() as Number {
        return _sessionSqDiffCount;
    }

    //! Returns HRV-derived autonomic stress (1-100), falling back to Garmin stressScore if needed.
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

    public function getStartStress() as Number? {
        return _startStress;
    }

    public function getCurrentStress() as Number? {
        return _currentStress;
    }

    // -------------------------------------------------------------------------
    // Time-Series History Accessors (For Post-Session Graphs)
    // -------------------------------------------------------------------------

    public function getHrHistory() as Array<Number> {
        return _hrHistory;
    }

    public function getStressHistory() as Array<Number> {
        return _stressHistory;
    }

    public function getRmssdHistory() as Array<Number> {
        return _rmssdHistory;
    }
}
