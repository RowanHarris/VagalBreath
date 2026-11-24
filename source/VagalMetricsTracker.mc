import Toybox.Lang;
import Toybox.Math;

//! Real-time autonomic & vagal biofeedback tracker.
//!
//! Computes:
//!   - Baseline Start HR (averaged over initial 5 valid samples) and live HR Change (bpm)
//!   - Rolling & Session-Mean RMSSD HRV (ms) from beat-to-beat R-R intervals
//!     (Sensor.HeartRateData.heartBeatIntervals) with Malik physiological artifact filtering
//!   - Start & End Garmin Stress Score (1..100) when available
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

    // Baseline Start HR averaging sample count
    private static const BASELINE_HR_SAMPLES as Number = 5;

    private var _startHrSum as Number;
    private var _startHrCount as Number;
    private var _startHrAvg as Float?;
    private var _currentHr as Number?;
    private var _minHr as Number?;
    private var _hrSum as Number;
    private var _hrCount as Number;

    private var _lastValidRrMs as Number?;
    private var _rollingSqDiffs as Array<Float>;
    private var _sessionSqDiffSum as Float;
    private var _sessionSqDiffCount as Number;

    private var _startStress as Number?;
    private var _currentStress as Number?;

    public function initialize() {
        _startHrSum = 0;
        _startHrCount = 0;
        _startHrAvg = null;
        _currentHr = null;
        _minHr = null;
        _hrSum = 0;
        _hrCount = 0;

        _lastValidRrMs = null;
        _rollingSqDiffs = [] as Array<Float>;
        _sessionSqDiffSum = 0.0;
        _sessionSqDiffCount = 0;

        _startStress = null;
        _currentStress = null;
    }

    public function reset() as Void {
        _startHrSum = 0;
        _startHrCount = 0;
        _startHrAvg = null;
        _currentHr = null;
        _minHr = null;
        _hrSum = 0;
        _hrCount = 0;

        _lastValidRrMs = null;
        _rollingSqDiffs = [] as Array<Float>;
        _sessionSqDiffSum = 0.0;
        _sessionSqDiffCount = 0;

        _startStress = null;
        _currentStress = null;
    }

    // -------------------------------------------------------------------------
    // Sensor Ingestion
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
    }

    //! Validate and ingest one R-R interval (ms) with Malik physiological artifact filtering.
    public function recordSingleRrInterval(rrMs as Number) as Boolean {
        if (rrMs < MIN_VALID_RR_MS || rrMs > MAX_VALID_RR_MS) {
            // Break pair continuity on out-of-range artifact
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
            // Artifact spike: re-anchor without polluting RMSSD squared differences
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

    //! Record Garmin stress score (1..100) from ActivityMonitor.getInfo().stressScore.
    public function recordStressScore(stress as Number?) as Void {
        if (stress == null || stress < 1 || stress > 100) {
            return;
        }
        if (_startStress == null) {
            _startStress = stress;
        }
        _currentStress = stress;
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
    //! Returns null until at least MIN_DIFFS_FOR_RMSSD (5) valid successive pairs exist.
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

    public function getStartStress() as Number? {
        return _startStress;
    }

    public function getCurrentStress() as Number? {
        return _currentStress;
    }
}
