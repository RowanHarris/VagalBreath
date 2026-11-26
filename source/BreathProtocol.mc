import Toybox.Lang;
import Toybox.Math;

//! Pure, unit-testable breathing protocol catalog and pacing state machine
//! with built-in psychophysiology Lab Mode (2m Pre-Baseline -> Active Breathing -> 5m Post-Recovery).
//!
//! Includes the top 5 peer-reviewed vagal-tone / stress-reduction protocols,
//! with full per-stage duration customization (stored in milliseconds):
//!   1. Cyclic Sighing (default: 3s inhale + 1s sharp nasal top-off -> 7s slow exhale)
//!   2. Resonance 0.1Hz (default: 5.5s inhale -> 5.5s exhale)
//!   3. Vagal 4-6 (default: 4s inhale -> 6s exhale)
//!   4. 4-7-8 Relax (default: 4s inhale -> 7s hold -> 8s exhale)
//!   5. Box 4-4-4-4 (default: 4s inhale -> 4s hold -> 4s exhale -> 4s hold)
class BreathProtocol {

    // -------------------------------------------------------------------------
    // Protocol IDs (1..5, persisted in Application.Storage & logged to FIT)
    // -------------------------------------------------------------------------

    public static const PROTO_CYCLIC_SIGH as Number = 1;
    public static const PROTO_RESONANCE as Number = 2;
    public static const PROTO_VAGAL_4_6 as Number = 3;
    public static const PROTO_4_7_8 as Number = 4;
    public static const PROTO_BOX as Number = 5;

    // -------------------------------------------------------------------------
    // Breath Phase Types
    // -------------------------------------------------------------------------

    public static const PHASE_INHALE as Number = 0;
    public static const PHASE_INHALE_TOP_OFF as Number = 1;
    public static const PHASE_HOLD_IN as Number = 2;
    public static const PHASE_EXHALE as Number = 3;
    public static const PHASE_HOLD_OUT as Number = 4;

    // -------------------------------------------------------------------------
    // Lab Mode Macro-Stages (written to FIT stage_code field)
    // -------------------------------------------------------------------------

    public static const STAGE_BASELINE as Number = 1;
    public static const STAGE_BREATHING as Number = 2;
    public static const STAGE_RECOVERY as Number = 3;

    public static const BASELINE_DURATION_MS as Number = 120000; // 2 min spontaneous baseline
    public static const RECOVERY_DURATION_MS as Number = 300000; // 5 min spontaneous recovery

    // -------------------------------------------------------------------------
    // Session States
    // -------------------------------------------------------------------------

    public static const STATE_READY as Number = 0;
    public static const STATE_ACTIVE as Number = 1;
    public static const STATE_PAUSED as Number = 2;
    public static const STATE_COMPLETE as Number = 3;

    // -------------------------------------------------------------------------
    // Tick Events
    // -------------------------------------------------------------------------

    public static const EVENT_NONE as Number = 0;
    public static const EVENT_PHASE_CHANGED as Number = 1;
    public static const EVENT_ENTER_BREATHING as Number = 2;
    public static const EVENT_ENTER_RECOVERY as Number = 3;
    public static const EVENT_SESSION_COMPLETE as Number = 4;

    // -------------------------------------------------------------------------
    // Duration Presets (minutes) & Bounds (ms)
    // -------------------------------------------------------------------------

    public static const DURATION_2_MIN as Number = 2;
    public static const DURATION_5_MIN as Number = 5;
    public static const DURATION_10_MIN as Number = 10;

    public static const MIN_PHASE_DURATION_MS as Number = 500;
    public static const MAX_PHASE_DURATION_MS as Number = 15000;

    // -------------------------------------------------------------------------
    // Instance State
    // -------------------------------------------------------------------------

    private var _protocolId as Number;
    private var _durationMinutes as Number;
    private var _breathingTargetMs as Number;
    private var _labModeEnabled as Boolean;

    private var _phaseTypes as Array<Number>;
    private var _phaseDurationsMs as Array<Number>;
    private var _phaseStartFill as Array<Float>;
    private var _phaseEndFill as Array<Float>;

    private var _state as Number;
    private var _activeStage as Number;
    private var _stageElapsedMs as Number;
    private var _phaseIndex as Number;
    private var _phaseElapsedMs as Number;
    private var _totalElapsedMs as Number;
    private var _completedCycles as Number;

    public function initialize(protocolId as Number, durationMinutes as Number, labModeEnabled as Boolean) {
        _protocolId = PROTO_CYCLIC_SIGH;
        _durationMinutes = DURATION_5_MIN;
        _breathingTargetMs = DURATION_5_MIN * 60000;
        _labModeEnabled = labModeEnabled;

        _phaseTypes = [] as Array<Number>;
        _phaseDurationsMs = [] as Array<Number>;
        _phaseStartFill = [] as Array<Float>;
        _phaseEndFill = [] as Array<Float>;

        _state = STATE_READY;
        _activeStage = _labModeEnabled ? STAGE_BASELINE : STAGE_BREATHING;
        _stageElapsedMs = 0;
        _phaseIndex = 0;
        _phaseElapsedMs = 0;
        _totalElapsedMs = 0;
        _completedCycles = 0;

        setProtocol(protocolId);
        setDurationMinutes(durationMinutes);
    }

    //! Configure the active breathing protocol with its clinical default timings.
    public function setProtocol(protocolId as Number) as Void {
        if (protocolId < PROTO_CYCLIC_SIGH || protocolId > PROTO_BOX) {
            protocolId = PROTO_CYCLIC_SIGH;
        }
        _protocolId = protocolId;

        if (protocolId == PROTO_CYCLIC_SIGH) {
            _phaseTypes = [PHASE_INHALE, PHASE_INHALE_TOP_OFF, PHASE_EXHALE] as Array<Number>;
            _phaseDurationsMs = [3000, 1000, 7000] as Array<Number>;
            _phaseStartFill = [0.0, 0.78, 1.0] as Array<Float>;
            _phaseEndFill = [0.78, 1.0, 0.0] as Array<Float>;
        } else if (protocolId == PROTO_RESONANCE) {
            _phaseTypes = [PHASE_INHALE, PHASE_EXHALE] as Array<Number>;
            _phaseDurationsMs = [5500, 5500] as Array<Number>;
            _phaseStartFill = [0.0, 1.0] as Array<Float>;
            _phaseEndFill = [1.0, 0.0] as Array<Float>;
        } else if (protocolId == PROTO_VAGAL_4_6) {
            _phaseTypes = [PHASE_INHALE, PHASE_EXHALE] as Array<Number>;
            _phaseDurationsMs = [4000, 6000] as Array<Number>;
            _phaseStartFill = [0.0, 1.0] as Array<Float>;
            _phaseEndFill = [1.0, 0.0] as Array<Float>;
        } else if (protocolId == PROTO_4_7_8) {
            _phaseTypes = [PHASE_INHALE, PHASE_HOLD_IN, PHASE_EXHALE] as Array<Number>;
            _phaseDurationsMs = [4000, 7000, 8000] as Array<Number>;
            _phaseStartFill = [0.0, 1.0, 1.0] as Array<Float>;
            _phaseEndFill = [1.0, 1.0, 0.0] as Array<Float>;
        } else {
            _phaseTypes = [PHASE_INHALE, PHASE_HOLD_IN, PHASE_EXHALE, PHASE_HOLD_OUT] as Array<Number>;
            _phaseDurationsMs = [4000, 4000, 4000, 4000] as Array<Number>;
            _phaseStartFill = [0.0, 1.0, 1.0, 0.0] as Array<Float>;
            _phaseEndFill = [1.0, 1.0, 0.0, 0.0] as Array<Float>;
        }

        resetSession();
    }

    //! Customize the duration (ms) of a single stage in the current protocol.
    public function setPhaseDurationMs(phaseIndex as Number, durationMs as Number) as Boolean {
        if (phaseIndex < 0 || phaseIndex >= _phaseDurationsMs.size()) {
            return false;
        }
        if (durationMs < MIN_PHASE_DURATION_MS || durationMs > MAX_PHASE_DURATION_MS) {
            return false;
        }
        _phaseDurationsMs[phaseIndex] = durationMs;
        return true;
    }

    //! Reset the current protocol's stage durations back to its clinical defaults.
    public function resetCurrentProtocolDefaults() as Void {
        setProtocol(_protocolId);
    }

    //! Configure target active breathing length in minutes (2, 5, or 10).
    public function setDurationMinutes(minutes as Number) as Void {
        if (minutes < 1) {
            minutes = DURATION_5_MIN;
        }
        _durationMinutes = minutes;
        _breathingTargetMs = minutes * 60000;
    }

    //! Enable or disable Lab Mode (2m Pre-Baseline -> Active Breathing -> 5m Post-Recovery).
    public function setLabModeEnabled(enabled as Boolean) as Void {
        _labModeEnabled = enabled;
        if (_state == STATE_READY) {
            _activeStage = _labModeEnabled ? STAGE_BASELINE : STAGE_BREATHING;
        }
    }

    public function isLabModeEnabled() as Boolean {
        return _labModeEnabled;
    }

    public function resetSession() as Void {
        _state = STATE_READY;
        _activeStage = _labModeEnabled ? STAGE_BASELINE : STAGE_BREATHING;
        _stageElapsedMs = 0;
        _phaseIndex = 0;
        _phaseElapsedMs = 0;
        _totalElapsedMs = 0;
        _completedCycles = 0;
    }

    public function start() as Void {
        _state = STATE_ACTIVE;
        _activeStage = _labModeEnabled ? STAGE_BASELINE : STAGE_BREATHING;
        _stageElapsedMs = 0;
        _phaseIndex = 0;
        _phaseElapsedMs = 0;
        _totalElapsedMs = 0;
        _completedCycles = 0;
    }

    public function pause() as Void {
        if (_state == STATE_ACTIVE) {
            _state = STATE_PAUSED;
        }
    }

    public function resume() as Void {
        if (_state == STATE_PAUSED) {
            _state = STATE_ACTIVE;
        }
    }

    public function completeEarly() as Void {
        if (_state == STATE_ACTIVE || _state == STATE_PAUSED) {
            _state = STATE_COMPLETE;
        }
    }

    //! Advance the session clock across Baseline -> Breathing -> Recovery.
    public function tick(deltaMs as Number) as Number {
        if (_state != STATE_ACTIVE || deltaMs <= 0) {
            return EVENT_NONE;
        }

        _totalElapsedMs += deltaMs;
        _stageElapsedMs += deltaMs;

        // Stage 1: 2-minute spontaneous Pre-Baseline
        if (_activeStage == STAGE_BASELINE) {
            if (_stageElapsedMs >= BASELINE_DURATION_MS) {
                _activeStage = STAGE_BREATHING;
                _stageElapsedMs = 0;
                _phaseIndex = 0;
                _phaseElapsedMs = 0;
                return EVENT_ENTER_BREATHING;
            }
            return EVENT_NONE;
        }

        // Stage 3: 5-minute spontaneous Post-Recovery
        if (_activeStage == STAGE_RECOVERY) {
            if (_stageElapsedMs >= RECOVERY_DURATION_MS) {
                _stageElapsedMs = RECOVERY_DURATION_MS;
                _state = STATE_COMPLETE;
                return EVENT_SESSION_COMPLETE;
            }
            return EVENT_NONE;
        }

        // Stage 2: Active Paced Breathing
        _phaseElapsedMs += deltaMs;

        var phaseDurMs = _phaseDurationsMs[_phaseIndex];
        if (_phaseElapsedMs < phaseDurMs) {
            return EVENT_NONE;
        }

        var phaseChanged = false;
        while (_phaseElapsedMs >= phaseDurMs) {
            _phaseElapsedMs -= phaseDurMs;
            _phaseIndex += 1;

            if (_phaseIndex >= _phaseTypes.size()) {
                _phaseIndex = 0;
                _completedCycles += 1;

                // Finish active breathing calmly at the end of a full breath cycle
                if (_stageElapsedMs >= _breathingTargetMs) {
                    _phaseElapsedMs = 0;
                    if (_labModeEnabled) {
                        _activeStage = STAGE_RECOVERY;
                        _stageElapsedMs = 0;
                        return EVENT_ENTER_RECOVERY;
                    }
                    _state = STATE_COMPLETE;
                    return EVENT_SESSION_COMPLETE;
                }
            }

            phaseChanged = true;
            phaseDurMs = _phaseDurationsMs[_phaseIndex];
        }

        return phaseChanged ? EVENT_PHASE_CHANGED : EVENT_NONE;
    }

    // -------------------------------------------------------------------------
    // Pure Easing & Presentation Helpers
    // -------------------------------------------------------------------------

    //! Smooth sinusoidal ease-in-out curve mapping linear progress [0, 1] -> [0, 1].
    public static function easeInOutSine(t as Float) as Float {
        if (t <= 0.0) {
            return 0.0;
        }
        if (t >= 1.0) {
            return 1.0;
        }
        var piFloat = Math.PI.toFloat();
        return 0.5 * (1.0 - Math.cos(t * piFloat).toFloat());
    }

    //! Returns smooth eased lung fill level in [0.0, 1.0] for the visual breathing circle.
    public function getLungFillFraction() as Float {
        if (_state == STATE_READY || _activeStage != STAGE_BREATHING) {
            return 0.35;
        }
        if (_state == STATE_COMPLETE) {
            return 0.5;
        }
        var phaseDurMs = _phaseDurationsMs[_phaseIndex];
        var linearT = (phaseDurMs > 0) ? (_phaseElapsedMs.toFloat() / phaseDurMs.toFloat()) : 1.0;
        var eased = BreathProtocol.easeInOutSine(linearT);
        var startFill = _phaseStartFill[_phaseIndex];
        var endFill = _phaseEndFill[_phaseIndex];
        return startFill + ((endFill - startFill) * eased);
    }

    public static function getPhaseLabel(phaseType as Number) as String {
        if (phaseType == PHASE_INHALE) {
            return "INHALE";
        }
        if (phaseType == PHASE_INHALE_TOP_OFF) {
            return "TOP-OFF";
        }
        if (phaseType == PHASE_HOLD_IN || phaseType == PHASE_HOLD_OUT) {
            return "HOLD";
        }
        return "EXHALE";
    }

    public static function getPhaseMenuTitle(phaseType as Number) as String {
        if (phaseType == PHASE_INHALE) {
            return "Inhale";
        }
        if (phaseType == PHASE_INHALE_TOP_OFF) {
            return "Top-Off Breath";
        }
        if (phaseType == PHASE_HOLD_IN) {
            return "Hold (Full)";
        }
        if (phaseType == PHASE_HOLD_OUT) {
            return "Hold (Empty)";
        }
        return "Exhale";
    }

    public static function formatDurationSec(ms as Number) as String {
        var whole = ms / 1000;
        var rem = ms % 1000;
        if (rem == 0) {
            return whole.format("%d");
        }
        var tenths = rem / 100;
        return whole.format("%d") + "." + tenths.format("%d");
    }

    public function getActiveCadenceText() as String {
        var count = _phaseDurationsMs.size();
        if (count == 0) {
            return "";
        }
        var text = BreathProtocol.formatDurationSec(_phaseDurationsMs[0]);
        for (var i = 1; i < count; i++) {
            var sep = (_phaseTypes[i] == PHASE_INHALE_TOP_OFF) ? " + " : " - ";
            text = text + sep + BreathProtocol.formatDurationSec(_phaseDurationsMs[i]);
        }
        return text + " s";
    }

    public static function getOptionsMsForPhase(phaseType as Number) as Array<Number> {
        if (phaseType == PHASE_INHALE_TOP_OFF) {
            return [500, 1000, 1500, 2000, 2500, 3000] as Array<Number>;
        }
        if (phaseType == PHASE_EXHALE) {
            return [4000, 5000, 5500, 6000, 7000, 8000, 9000, 10000, 12000] as Array<Number>;
        }
        if (phaseType == PHASE_HOLD_IN || phaseType == PHASE_HOLD_OUT) {
            return [1000, 2000, 3000, 4000, 5000, 6000, 7000, 8000, 10000] as Array<Number>;
        }
        return [1500, 2000, 2500, 3000, 3500, 4000, 4500, 5000, 5500, 6000, 7000, 8000] as Array<Number>;
    }

    public static function getProtocolShortName(protocolId as Number) as String {
        if (protocolId == PROTO_CYCLIC_SIGH) {
            return "CYCLIC SIGH";
        }
        if (protocolId == PROTO_RESONANCE) {
            return "RESONANCE";
        }
        if (protocolId == PROTO_VAGAL_4_6) {
            return "VAGAL 4-6";
        }
        if (protocolId == PROTO_4_7_8) {
            return "4-7-8 RELAX";
        }
        return "BOX 4-4-4-4";
    }

    // -------------------------------------------------------------------------
    // Public Getters
    // -------------------------------------------------------------------------

    public function getProtocolId() as Number {
        return _protocolId;
    }

    public function getDurationMinutes() as Number {
        return _durationMinutes;
    }

    public function getState() as Number {
        return _state;
    }

    public function getActiveStage() as Number {
        return _activeStage;
    }

    public function getPhaseCount() as Number {
        return _phaseTypes.size();
    }

    public function getPhaseTypeAt(index as Number) as Number {
        return _phaseTypes[index];
    }

    public function getPhaseDurationMsAt(index as Number) as Number {
        return _phaseDurationsMs[index];
    }

    public function getCurrentPhaseType() as Number {
        return _phaseTypes[_phaseIndex];
    }

    public function getCurrentPhaseLabel() as String {
        return BreathProtocol.getPhaseLabel(getCurrentPhaseType());
    }

    public function getPhaseRemainingSeconds() as Float {
        var remMs = _phaseDurationsMs[_phaseIndex] - _phaseElapsedMs;
        if (remMs < 0) {
            remMs = 0;
        }
        return remMs.toFloat() / 1000.0;
    }

    //! Target duration (ms) of the currently executing macro-stage.
    public function getCurrentStageTargetMs() as Number {
        if (_activeStage == STAGE_BASELINE) {
            return BASELINE_DURATION_MS;
        }
        if (_activeStage == STAGE_RECOVERY) {
            return RECOVERY_DURATION_MS;
        }
        return _breathingTargetMs;
    }

    public function getStageRemainingSeconds() as Float {
        var remMs = getCurrentStageTargetMs() - _stageElapsedMs;
        if (remMs < 0) {
            remMs = 0;
        }
        return remMs.toFloat() / 1000.0;
    }

    public function getStageProgressFraction() as Float {
        var target = getCurrentStageTargetMs();
        if (target <= 0) {
            return 0.0;
        }
        var p = _stageElapsedMs.toFloat() / target.toFloat();
        if (p > 1.0) {
            return 1.0;
        }
        return p;
    }

    public function getTotalPlannedMinutes() as Number {
        if (_labModeEnabled) {
            return _durationMinutes + 7; // 2m Baseline + Breathing + 5m Recovery
        }
        return _durationMinutes;
    }

    public function getTotalElapsedSeconds() as Float {
        return _totalElapsedMs.toFloat() / 1000.0;
    }

    public function getCompletedCycles() as Number {
        return _completedCycles;
    }
}
