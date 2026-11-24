import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

//! Serene, high-contrast Venu 3 (454x454 AMOLED) breathing pacer & live vagal biofeedback UI.
//!
//! Screens:
//!   - READY:    Selected protocol, cadence, duration, and quick Start / Setup hints
//!   - ACTIVE:   Outer session progress arc, smooth cosine-eased expanding/contracting
//!               breathing circle (with crisp bright surge on Cyclic Sigh's Top-Off inhale),
//!               phase instruction + countdown, and live HR (with delta) + RMSSD HRV (ms)
//!   - COMPLETE: Summary of HR drop, Vagal RMSSD HRV, Stress score, and completed cycles
class BreathView extends WatchUi.View {

    // Bioluminescent calm palette on true black AMOLED
    private static const COLOR_INHALE as Number = 0x00D4C8;
    private static const COLOR_TOP_OFF as Number = 0xB8FFFF;
    private static const COLOR_HOLD as Number = 0x8A9EFF;
    private static const COLOR_EXHALE as Number = 0x2D8CFF;
    private static const COLOR_PROGRESS_BG as Number = 0x1D2830;
    private static const COLOR_HALO_DIM as Number = 0x12262B;
    private static const COLOR_TEXT_MUTED as Number = 0xA8BCC6;
    private static const COLOR_GOOD_DROP as Number = 0x4CE6A0;
    private static const COLOR_PAUSED_RING as Number = 0xFFAA00;

    // Breathing circle radius range on 454x454 display
    private static const CIRCLE_MIN_RADIUS as Float = 66.0;
    private static const CIRCLE_MAX_RADIUS as Float = 158.0;

    private var _app as BreathApp;

    private var _fontTitle as Graphics.FontType;
    private var _fontPhase as Graphics.FontType;
    private var _fontCount as Graphics.FontType;
    private var _fontBio as Graphics.FontType;
    private var _fontSmall as Graphics.FontType;
    private var _fontSummaryVal as Graphics.FontType;

    public function initialize(app as BreathApp) {
        View.initialize();
        _app = app;

        _fontTitle = Graphics.FONT_SMALL;
        _fontPhase = Graphics.FONT_MEDIUM;
        _fontCount = Graphics.FONT_NUMBER_HOT;
        _fontBio = Graphics.FONT_SMALL;
        _fontSmall = Graphics.FONT_XTINY;
        _fontSummaryVal = Graphics.FONT_MEDIUM;

        loadDisplayFonts();
    }

    private function loadDisplayFonts() as Void {
        var textFaces = ["RobotoRegular"] as Array<String>;
        var numFaces = ["YantramanavRegular", "RobotoRegular"] as Array<String>;

        var vTitle = loadVectorFont(textFaces, 30);
        var vPhase = loadVectorFont(textFaces, 42);
        var vCount = loadVectorFont(numFaces, 74);
        var vBio = loadVectorFont(textFaces, 28);
        var vSmall = loadVectorFont(textFaces, 24);
        var vSumVal = loadVectorFont(numFaces, 54);

        if (vTitle != null && vPhase != null && vCount != null &&
            vBio != null && vSmall != null && vSumVal != null) {
            _fontTitle = vTitle;
            _fontPhase = vPhase;
            _fontCount = vCount;
            _fontBio = vBio;
            _fontSmall = vSmall;
            _fontSummaryVal = vSumVal;
        }
    }

    private function loadVectorFont(faces as Array<String>, sizePx as Number) as Graphics.VectorFont? {
        var opts = {
            :face => faces,
            :size => sizePx
        } as Graphics.VectorFontOptions;
        return Graphics.getVectorFont(opts);
    }

    public function onUpdate(dc as Graphics.Dc) as Void {
        var width = dc.getWidth();
        var height = dc.getHeight();
        var cx = width / 2;
        var cy = height / 2;

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_BLACK);
        dc.clear();
        dc.setAntiAlias(true);

        var proto = _app.getProtocol();
        var state = proto.getState();

        if (state == BreathProtocol.STATE_READY) {
            drawReadyScreen(dc, width, height, cx, cy, proto);
        } else if (state == BreathProtocol.STATE_COMPLETE) {
            drawCompleteScreen(dc, width, height, cx, cy, proto);
        } else {
            drawActiveScreen(dc, width, height, cx, cy, proto, state == BreathProtocol.STATE_PAUSED);
        }
    }

    // -------------------------------------------------------------------------
    // Ready Screen (Protocol + Duration + Start / Setup)
    // -------------------------------------------------------------------------

    private function drawReadyScreen(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        cy as Number,
        proto as BreathProtocol
    ) as Void {
        var protoId = proto.getProtocolId();

        // Calm concentric halo border
        dc.setColor(COLOR_INHALE, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(5);
        dc.drawCircle(cx, cy, cx - 10);

        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 19) / 100,
            _fontSmall,
            "VAGAL BREATH",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 37) / 100,
            _fontPhase,
            BreathProtocol.getProtocolShortName(protoId),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(COLOR_INHALE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 51) / 100,
            _fontTitle,
            BreathProtocol.getProtocolCadenceText(protoId) + "  •  " + proto.getDurationMinutes().format("%d") + " MIN",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Live pre-session heart rate
        var hr = _app.getDisplayHeartRate();
        var hrText = (hr != null) ? (hr.format("%d") + " bpm") : "-- bpm";
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 66) / 100,
            _fontTitle,
            hrText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 81) / 100,
            _fontSmall,
            "TOP/TAP: START  •  SWIPE: SETUP",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // -------------------------------------------------------------------------
    // Active / Paused Breathing Pacer Screen
    // -------------------------------------------------------------------------

    private function drawActiveScreen(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        cy as Number,
        proto as BreathProtocol,
        isPaused as Boolean
    ) as Void {
        var phaseType = proto.getCurrentPhaseType();
        var phaseColor = colorForPhase(phaseType);

        // 1. Outer bezel progress ring (amber when paused; smooth progress arc when active)
        var outerR = cx - 6;
        if (isPaused) {
            dc.setColor(COLOR_PAUSED_RING, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(8);
            dc.drawCircle(cx, cy, outerR);
        } else {
            dc.setColor(COLOR_PROGRESS_BG, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(5);
            dc.drawCircle(cx, cy, outerR);

            var progress = proto.getSessionProgressFraction();
            drawProgressArc(dc, cx, cy, outerR, progress, phaseColor, 5);
        }

        // 2. Smooth expanding/contracting breathing circle
        var fill = proto.getLungFillFraction();
        var radius = Math.round(CIRCLE_MIN_RADIUS + ((CIRCLE_MAX_RADIUS - CIRCLE_MIN_RADIUS) * fill)).toNumber();

        // Soft background lung-capacity reference guide (subtle outer max ring)
        dc.setColor(COLOR_HALO_DIM, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(2);
        dc.drawCircle(cx, cy, CIRCLE_MAX_RADIUS.toNumber());

        // Inner breathing halo (bright crisp thicker stroke during Cyclic Sigh's TOP-OFF!)
        var ringWidth = (phaseType == BreathProtocol.PHASE_INHALE_TOP_OFF) ? 14 : 9;
        dc.setColor(phaseColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(ringWidth);
        dc.drawCircle(cx, cy, radius);

        // Subtle inner secondary echo ring for visual depth
        if (radius > 22) {
            dc.setColor(COLOR_HALO_DIM, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(4);
            dc.drawCircle(cx, cy, radius - 14);
        }

        // 3. Top header: protocol name + session time remaining
        var topText = BreathProtocol.getProtocolShortName(proto.getProtocolId()) +
            "  " + BreathView.formatMinuteSecond(proto.getSessionRemainingSeconds());
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 11) / 100,
            _fontSmall,
            topText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // 4. Center phase prompt + phase countdown
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 43) / 100,
            _fontPhase,
            isPaused ? "PAUSED" : proto.getCurrentPhaseLabel(),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var phaseSec = Math.ceil(proto.getPhaseRemainingSeconds()).toNumber();
        if (phaseSec < 1) {
            phaseSec = 1;
        }
        dc.drawText(
            cx,
            (height * 57) / 100,
            _fontCount,
            phaseSec.format("%d"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // 5. Bottom live vagal biofeedback strip: HR (with live delta) + RMSSD HRV
        var tracker = _app.getTracker();
        var hrLine = BreathView.formatHrWithDelta(tracker.getCurrentHeartRate(), tracker.getHeartRateDelta());
        var delta = tracker.getHeartRateDelta();
        var hrColor = (delta != null && delta < 0) ? COLOR_GOOD_DROP : Graphics.COLOR_WHITE;

        dc.setColor(hrColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 81) / 100,
            _fontBio,
            hrLine,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var hrvLine = BreathView.formatRmssdLine(tracker.getRollingRmssdMs());
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 89) / 100,
            _fontSmall,
            hrvLine,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // -------------------------------------------------------------------------
    // Post-Session Summary Screen
    // -------------------------------------------------------------------------

    private function drawCompleteScreen(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        cy as Number,
        proto as BreathProtocol
    ) as Void {
        dc.setColor(COLOR_GOOD_DROP, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(6);
        dc.drawCircle(cx, cy, cx - 8);

        var tracker = _app.getTracker();

        dc.setColor(COLOR_GOOD_DROP, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 16) / 100,
            _fontTitle,
            "COMPLETE",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 25) / 100,
            _fontSmall,
            BreathProtocol.getProtocolShortName(proto.getProtocolId()) +
                "  •  " + proto.getCompletedCycles().format("%d") + " CYCLES",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Start -> End HR and Delta
        var startHr = tracker.getStartHeartRateRounded();
        var endHr = tracker.getCurrentHeartRate();
        var deltaHr = tracker.getHeartRateDelta();
        var hrSummary = "-- bpm";
        if (startHr != null && endHr != null) {
            hrSummary = startHr.format("%d") + " -> " + endHr.format("%d") + " bpm";
            if (deltaHr != null) {
                var sign = (deltaHr > 0) ? "+" : "";
                hrSummary = hrSummary + " (" + sign + deltaHr.format("%d") + ")";
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 43) / 100,
            _fontTitle,
            hrSummary,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Session Vagal RMSSD HRV
        var rmssd = tracker.getSessionRmssdMs();
        var rmssdText = (rmssd != null)
            ? ("HRV " + Math.round(rmssd).toNumber().format("%d") + " ms")
            : "HRV -- ms";
        dc.setColor(COLOR_INHALE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 58) / 100,
            _fontSummaryVal,
            rmssdText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        // Optional Garmin Stress summary if available
        var endStress = tracker.getCurrentStress();
        if (endStress != null) {
            var startStress = tracker.getStartStress();
            var stressText = (startStress != null)
                ? ("STRESS " + startStress.format("%d") + " -> " + endStress.format("%d"))
                : ("STRESS " + endStress.format("%d"));
            dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                cx,
                (height * 72) / 100,
                _fontSmall,
                stressText,
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
        }

        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 85) / 100,
            _fontSmall,
            "TOP / TAP: SAVE OR DISCARD",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // -------------------------------------------------------------------------
    // Drawing & Pure Formatting Helpers
    // -------------------------------------------------------------------------

    private function colorForPhase(phaseType as Number) as Number {
        if (phaseType == BreathProtocol.PHASE_INHALE) {
            return COLOR_INHALE;
        }
        if (phaseType == BreathProtocol.PHASE_INHALE_TOP_OFF) {
            return COLOR_TOP_OFF;
        }
        if (phaseType == BreathProtocol.PHASE_HOLD_IN || phaseType == BreathProtocol.PHASE_HOLD_OUT) {
            return COLOR_HOLD;
        }
        return COLOR_EXHALE;
    }

    private function drawProgressArc(
        dc as Graphics.Dc,
        cx as Number,
        cy as Number,
        radius as Number,
        progress as Float,
        color as Number,
        penWidth as Number
    ) as Void {
        if (progress <= 0.005) {
            return;
        }
        dc.setColor(color, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(penWidth);

        if (progress >= 0.995) {
            dc.drawCircle(cx, cy, radius);
            return;
        }

        var sweepDeg = Math.round(progress * 360.0).toNumber();
        if (sweepDeg < 1) {
            return;
        }
        var endDeg = 90 - sweepDeg;
        while (endDeg < 0) {
            endDeg += 360;
        }
        dc.drawArc(cx, cy, radius, Graphics.ARC_CLOCKWISE, 90, endDeg);
    }

    public static function formatMinuteSecond(totalSeconds as Float) as String {
        var whole = Math.ceil(totalSeconds).toNumber();
        if (whole < 0) {
            whole = 0;
        }
        var mins = whole / 60;
        var secs = whole % 60;
        return mins.format("%02d") + ":" + secs.format("%02d");
    }

    public static function formatHrWithDelta(hr as Number?, delta as Number?) as String {
        if (hr == null) {
            return "-- bpm";
        }
        var base = hr.format("%d") + " bpm";
        if (delta == null) {
            return base;
        }
        var sign = (delta > 0) ? "+" : "";
        return base + " (" + sign + delta.format("%d") + ")";
    }

    public static function formatRmssdLine(rmssdMs as Float?) as String {
        if (rmssdMs == null) {
            return "HRV -- ms";
        }
        return "HRV " + Math.round(rmssdMs).toNumber().format("%d") + " ms";
    }
}
