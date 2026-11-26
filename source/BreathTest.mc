import Toybox.Lang;
import Toybox.Test;

//! Connect IQ (:test) unit tests for BreathProtocol, VagalMetricsTracker, and BreathView helpers.
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

        var bp = new BreathProtocol(BreathProtocol.PROTO_CYCLIC_SIGH, 2);
        Test.assert(bp.getActiveCadenceText().equals("3 + 1 - 7 s"));
        bp.start();

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
        var res = new BreathProtocol(BreathProtocol.PROTO_RESONANCE, 5);
        res.start();
        Test.assertEqual(BreathProtocol.PHASE_INHALE, res.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, res.tick(5500));
        Test.assertEqual(BreathProtocol.PHASE_EXHALE, res.getCurrentPhaseType());
        Test.assertEqual(BreathProtocol.EVENT_PHASE_CHANGED, res.tick(5500));
        Test.assertEqual(1, res.getCompletedCycles());

        // 4-7-8 Relax
        var p478 = new BreathProtocol(BreathProtocol.PROTO_4_7_8, 2);
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
        var box = new BreathProtocol(BreathProtocol.PROTO_BOX, 5);
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
    public static function testVagalRmssdAndArtifactFiltering(logger as Test.Logger) as Boolean {
        logger.debug("Testing HR baseline/delta and Malik artifact-filtered RMSSD HRV");

        var tracker = new VagalMetricsTracker();

        // Seed 5 baseline HR samples at 70 bpm, then drop to 62 bpm (-8 bpm)
        for (var i = 0; i < 5; i++) {
            tracker.recordHeartRate(70);
        }
        tracker.recordHeartRate(62);
        Test.assertEqual(70, tracker.getStartHeartRateRounded());
        Test.assertEqual(62, tracker.getCurrentHeartRate());
        Test.assertEqual(-8, tracker.getHeartRateDelta());

        // Feed alternating R-R intervals differing by exactly 50ms: [900, 950, 900, 950, 900, 950]
        // 5 valid diffs of +/-50ms -> exact RMSSD = 50.0 ms
        var cleanRr = [900, 950, 900, 950, 900, 950] as Array<Number>;
        tracker.recordHeartBeatIntervals(cleanRr);
        Test.assertEqual(5, tracker.getValidRrPairCount());
        assertFloatNear(tracker.getRollingRmssdMs(), 50.0, 0.1, "Exact 50ms alternating R-R -> 50ms RMSSD");
        assertFloatNear(tracker.getSessionRmssdMs(), 50.0, 0.1, "Session RMSSD = 50ms");

        // Feed wrist-PPG artifact spike (1500ms = +550ms jump > 250ms) and out-of-range (200ms)
        Test.assert(!tracker.recordSingleRrInterval(1500));
        Test.assert(!tracker.recordSingleRrInterval(200));
        // Valid pair count and RMSSD must remain unpolluted at 50.0 ms
        Test.assertEqual(5, tracker.getValidRrPairCount());
        assertFloatNear(tracker.getRollingRmssdMs(), 50.0, 0.1, "Artifact spikes rejected from RMSSD");

        // Formatting checks
        Test.assert(BreathView.formatHrWithDelta(62, -8).equals("62 bpm (-8)"));
        Test.assert(BreathView.formatRmssdLine(50.2).equals("HRV 50 ms"));
        Test.assert(BreathView.formatMinuteSecond(125.0).equals("02:05"));

        // Autonomic Stress ln(RMSSD) mapping & history snapshot checks
        var highStress = VagalMetricsTracker.computeStressFromRmssd(10.0);
        var lowStress = VagalMetricsTracker.computeStressFromRmssd(85.0);
        Test.assert(highStress > 80);
        Test.assert(lowStress <= 25);

        tracker.recordHistorySnapshot();
        Test.assertEqual(1, tracker.getHrHistory().size());
        Test.assertEqual(62, tracker.getHrHistory()[0]);
        Test.assertEqual(1, tracker.getRmssdHistory().size());
        Test.assertEqual(50, tracker.getRmssdHistory()[0]);
        Test.assertEqual(1, tracker.getStressHistory().size());

        return true;
    }
}
