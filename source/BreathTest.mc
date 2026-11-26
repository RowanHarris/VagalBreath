import Toybox.Lang;
import Toybox.Test;

//! Connect IQ (:test) unit tests for BreathProtocol, Lab Mode, VagalMetricsTracker, and BreathView helpers.
(:test)
class BreathTest {

    private static function assertFloatNear(
        actual as Float?,
        expected as Float,
        epsilon as Float,
        message as String
    ) as Void {
        Test.assertMessage(actual != null, message + " (was null)");
        if (actual != null) {
            var diff = actual - expected;
            if (diff < 0.0) {
                diff = -diff;
            }
            Test.assertMessage(
                diff <= epsilon,
                message + " (expected=" + expected.toString() + ", actual=" + actual.toString() + ")"
            );
        }
    }

    (:test)
    public static function testCyclicSighPhasesAndCustomTiming(logger as Test.Logger) as Boolean {
        logger.debug("Testing Huberman Cyclic Sigh default (3+1-7s) and custom (3+2-8s) timings");

        var bp = new BreathProtocol(BreathProtocol.PROTO_CYCLIC_SIGH, 2, false);
        Test.assert(bp.getActiveCadenceText().equals("3 + 1 - 7 s"));
        bp.start();
        Test.assertEqual(BreathProtocol.STAGE_BREATHING, bp.getActiveStage());

        // Starts in INHALE (0.0 fill)
        Test.assertEqual(BreathProtocol.PHASE_INHALE, bp.getCurrentPhaseType());
        assertFloatNear(bp.getLungFillFraction(), 0.0, 0.01, "Start of inhale is 0.0");

        // Halfway through 3s inhale -> ~0.39 fill
        Test.assertEqual(BreathProtocol.EVENT_NONE, bp.tick(1500));
        assertFloatNear(bp.getLungFillFraction(), 0.39, 0.02, "Mid inhale fill ~0.39");

        // At 3.0s -> transitions to TOP-OFF (starts at 0.78 fill)
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, bp.tick(1500));
        Test.assertEqual(BreathProtocol.PHASE_INHALE_TOP_OFF, bp.getCurrentPhaseType());
        assertFloatNear(bp.getLungFillFraction(), 0.78, 0.02, "Start of top-off is 0.78");

        // At 4.0s -> transitions to 7s EXHALE (starts at 1.00 fill)
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, bp.tick(1000));
        Test.assertEqual(BreathProtocol.PHASE_EXHALE, bp.getCurrentPhaseType());
        assertFloatNear(bp.getLungFillFraction(), 1.0, 0.02, "Start of exhale is 1.0");

        // At 11.0s (7s exhale) -> finishes cycle 1, returns to INHALE
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, bp.tick(7000));
        Test.assertEqual(1, bp.getCompletedCycles());
        Test.assertEqual(BreathProtocol.PHASE_INHALE, bp.getCurrentPhaseType());

        // Customize Top-Off to 2s and Exhale to 8s -> 3 + 2 - 8 s (13s cycle)
        Test.assert(bp.setPhaseDurationMs(1, 2000));
        Test.assert(bp.setPhaseDurationMs(2, 8000));
        Test.assert(bp.getActiveCadenceText().equals("3 + 2 - 8 s"));
        bp.start();
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, bp.tick(3000));
        Test.assertEqual(BreathProtocol.PHASE_INHALE_TOP_OFF, bp.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_NONE, bp.tick(1000));
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, bp.tick(1000));
        Test.assertEqual(BreathProtocol.PHASE_EXHALE, bp.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, bp.tick(8000));
        Test.assertEqual(1, bp.getCompletedCycles());

        // Reset defaults restores 3 + 1 - 7 s
        bp.resetCurrentProtocolDefaults();
        Test.assert(bp.getActiveCadenceText().equals("3 + 1 - 7 s"));

        return true;
    }

    (:test)
    public static function testAllOtherProtocolsCycleStructure(logger as Test.Logger) as Boolean {
        logger.debug("Testing Resonance 5.5s, Vagal 4-6, 4-7-8, and Box 4-4-4-4 phase sequences");

        // Resonance 5.5 - 5.5
        var res = new BreathProtocol(BreathProtocol.PROTO_RESONANCE, 5, false);
        res.start();
        Test.assertEqual(BreathProtocol.PHASE_INHALE, res.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, res.tick(5500));
        Test.assertEqual(BreathProtocol.PHASE_EXHALE, res.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, res.tick(5500));
        Test.assertEqual(1, res.getCompletedCycles());

        // 4-7-8 Relax
        var p478 = new BreathProtocol(BreathProtocol.PROTO_4_7_8, 2, false);
        p478.start();
        Test.assertEqual(BreathProtocol.PHASE_INHALE, p478.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, p478.tick(4000));
        Test.assertEqual(BreathProtocol.PHASE_HOLD_IN, p478.getCurrentPhaseType());
        assertFloatNear(p478.getLungFillFraction(), 1.0, 0.01, "Hold-in keeps full ring");
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, p478.tick(7000));
        Test.assertEqual(BreathProtocol.PHASE_EXHALE, p478.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, p478.tick(8000));
        Test.assertEqual(1, p478.getCompletedCycles());

        // Box 4-4-4-4
        var box = new BreathProtocol(BreathProtocol.PROTO_BOX, 5, false);
        box.start();
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, box.tick(4000));
        Test.assertEqual(BreathProtocol.PHASE_HOLD_IN, box.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, box.tick(4000));
        Test.assertEqual(BreathProtocol.PHASE_EXHALE, box.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, box.tick(4000));
        Test.assertEqual(BreathProtocol.PHASE_HOLD_OUT, box.getCurrentPhaseType());
        assertFloatNear(box.getLungFillFraction(), 0.0, 0.01, "Hold-out keeps empty ring");
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, box.tick(4000));
        Test.assertEqual(1, box.getCompletedCycles());

        return true;
    }

    (:test)
    public static function testLabModeBaselineBreathingRecovery(logger as Test.Logger) as Boolean {
        logger.debug("Testing Lab Mode 2m Pre-Baseline -> Active Breathing -> 5m Post-Recovery");

        // Vagal 4-6 for 1 min active breathing + Lab Mode (total planned = 8 min)
        var bp = new BreathProtocol(BreathProtocol.PROTO_VAGAL_4_6, 1, true);
        Test.assert(bp.isLabModeEnabled());
        Test.assertEqual(8, bp.getTotalPlannedMinutes());
        Test.assertEqual(BreathProtocol.STAGE_BASELINE, bp.getActiveStage());

        bp.start();
        Test.assertEqual(BreathProtocol.STAGE_BASELINE, bp.getActiveStage());

        // Halfway through 2-minute baseline -> still in baseline
        Test.assertEqual(BreathProtocol.EVENT_NONE, bp.tick(60000));
        Test.assertEqual(BreathProtocol.STAGE_BASELINE, bp.getActiveStage());
        assertFloatNear(bp.getStageRemainingSeconds(), 60.0, 0.1, "60s remaining in baseline");

        // At 120s -> enters Active Breathing stage
        Test.assertEqual(BreathProtocol.EVENT_ENTER_BREATHING, bp.tick(60000));
        Test.assertEqual(BreathProtocol.STAGE_BREATHING, bp.getActiveStage());
        Test.assertEqual(BreathProtocol.PHASE_INHALE, bp.getCurrentPhaseType());

        // Run 6 complete 10-second Vagal 4-6 cycles (60s total) -> enters Post-Recovery
        var lastEv = BreathProtocol.EVENT_NONE;
        for (var c = 0; c < 6; c++) {
            Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, bp.tick(4000));
            lastEv = bp.tick(6000);
        }
        Test.assertEqual(BreathProtocol.EVENT_ENTER_RECOVERY, lastEv);
        Test.assertEqual(6, bp.getCompletedCycles());
        Test.assertEqual(BreathProtocol.STAGE_RECOVERY, bp.getActiveStage());

        // Advance 4 minutes into recovery -> still recovering (60s left)
        Test.assertEqual(BreathProtocol.EVENT_NONE, bp.tick(240000));
        Test.assertEqual(BreathProtocol.STAGE_RECOVERY, bp.getActiveStage());
        assertFloatNear(bp.getStageRemainingSeconds(), 60.0, 0.1, "60s remaining in recovery");

        // Final 60s of recovery -> session completes
        Test.assertEqual(BreathProtocol.EVENT_SESSION_COMPLETE, bp.tick(60000));
        Test.assertEqual(BreathProtocol.STATE_COMPLETE, bp.getState());

        return true;
    }

    (:test)
    public static function testVagalRmssdAndLabStageIsolation(logger as Test.Logger) as Boolean {
        logger.debug("Testing HR baseline/delta, Malik artifact filter, raw RR capture, and per-stage RMSSD isolation");

        var tracker = new VagalMetricsTracker();
        tracker.reset(BreathProtocol.STAGE_BASELINE);

        // Stage 1 (Baseline): HR 72 bpm, R-R alternating by 20ms -> Baseline RMSSD = 20.0 ms
        for (var i = 0; i < 5; i++) {
            tracker.recordHeartRate(72);
        }
        tracker.recordHeartBeatIntervals([830, 850] as Array<Number>);
        Test.assertEqual(830, tracker.getLastBatchRr1());
        Test.assertEqual(850, tracker.getLastBatchRr2());
        tracker.recordHeartBeatIntervals([830, 850, 830, 850] as Array<Number>);
        assertFloatNear(tracker.getStageRmssdMs(BreathProtocol.STAGE_BASELINE), 20.0, 0.1, "Baseline RMSSD = 20ms");
        Test.assertEqual(72, tracker.getStageAvgHeartRate(BreathProtocol.STAGE_BASELINE));
        tracker.recordHistorySnapshot();

        // Stage 2 (Breathing): large jump from 850 -> 950 across boundary MUST NOT pollute RMSSD
        tracker.setActiveStage(BreathProtocol.STAGE_BREATHING);
        tracker.recordHeartRate(68);
        tracker.recordHeartBeatIntervals([950, 1010, 950, 1010, 950, 1010] as Array<Number>);
        assertFloatNear(tracker.getStageRmssdMs(BreathProtocol.STAGE_BREATHING), 60.0, 0.1, "Breathing RMSSD = 60ms");
        tracker.recordHistorySnapshot();

        // Stage 3 (Recovery): HR 64 bpm (-8 vs baseline), alternating by 50ms -> Recovery RMSSD = 50.0 ms (+30ms vs baseline)
        tracker.setActiveStage(BreathProtocol.STAGE_RECOVERY);
        tracker.recordHeartRate(64);
        tracker.recordHeartBeatIntervals([900, 950, 900, 950, 900, 950] as Array<Number>);

        // Feed wrist-PPG artifact spike (1500ms) and out-of-range (200ms)
        Test.assert(!tracker.recordSingleRrInterval(1500));
        Test.assert(!tracker.recordSingleRrInterval(200));

        assertFloatNear(tracker.getStageRmssdMs(BreathProtocol.STAGE_RECOVERY), 50.0, 0.1, "Recovery RMSSD = 50ms");
        Test.assertEqual(64, tracker.getStageAvgHeartRate(BreathProtocol.STAGE_RECOVERY));
        Test.assertEqual(-8, tracker.getLabHrDelta());
        assertFloatNear(tracker.getLabRmssdDeltaMs(), 30.0, 0.1, "Lab RMSSD delta = +30ms");

        // Formatting checks
        Test.assert(BreathView.formatHrWithDelta(64, -8).equals("64 bpm (-8)"));
        Test.assert(BreathView.formatRmssdLine(50.2).equals("HRV 50 ms"));
        Test.assert(BreathView.formatMinuteSecond(125.0).equals("02:05"));

        // Autonomic Stress ln(RMSSD) mapping & history snapshot checks
        var highStress = VagalMetricsTracker.computeStressFromRmssd(10.0);
        var lowStress = VagalMetricsTracker.computeStressFromRmssd(85.0);
        Test.assert(highStress > 80);
        Test.assert(lowStress <= 25);

        tracker.recordHistorySnapshot();
        Test.assertEqual(3, tracker.getHrHistory().size());
        Test.assertEqual(3, tracker.getStageHistory().size());
        Test.assertEqual(BreathProtocol.STAGE_BASELINE, tracker.getStageHistory()[0]);
        Test.assertEqual(BreathProtocol.STAGE_BREATHING, tracker.getStageHistory()[1]);
        Test.assertEqual(BreathProtocol.STAGE_RECOVERY, tracker.getStageHistory()[2]);

        return true;
    }
}
