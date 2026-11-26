import Toybox.Graphics;
import Toybox.Lang;
import Toybox.Math;
import Toybox.WatchUi;

//! Serene, high-contrast Venu 3 (454x454 AMOLED) breathing pacer & post-session graph UI.
//!
//! Full-screen dynamic ring geometry:
//!   - Fully exhaled (0% fill): shrinks down to a tight 26px inner core circle
//!   - Fully inhaled (100% fill): expands all the way out to the full bezel ring
//!
//! Scrollable Post-Session Pages (Swipe Up/Down after completing a session):
//!   - Page 0: Numeric Overview (HR drop, Session Vagal RMSSD, Autonomic Stress)
//!   - Page 1: Heart Rate Graph (bpm curve over full session)
//!   - Page 2: Autonomic Stress Graph (0-100 Garmin-style color-coded zone bars)
//!   - Page 3: Vagal Tone / RMSSD HRV Graph (ms curve showing parasympathetic lift)
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

    // Graph palette
    private static const COLOR_GRID as Number = 0x26323A;
    private static const COLOR_HR_LINE as Number = 0xFF5272;
    private static const COLOR_HR_FILL as Number = 0x3D141F;
    private static const COLOR_HRV_LINE as Number = 0x00D4C8;
    private static const COLOR_HRV_FILL as Number = 0x0C2D30;

    // Garmin-style Stress Zone colors (0-25 Rest, 26-50 Low, 51-75 Med, 76-100 High)
    private static const COLOR_STRESS_REST as Number = 0x3B9EFF;
    private static const COLOR_STRESS_LOW as Number = 0xFFB84D;
    private static const COLOR_STRESS_MED as Number = 0xFF7B29;
    private static const COLOR_STRESS_HIGH as Number = 0xFF3B30;

    // Compact fully-exhaled core radius; full-inhale expands dynamically to outer bezel radius
    private static const CIRCLE_MIN_RADIUS as Float = 26.0;
    private static const BEZEL_INSET_PX as Number = 8;

    private var _app as BreathApp;

    private var _fontTitle as Graphics.FontType;
    private var _fontPhase as Graphics.FontType;
    private var _fontCount as Graphics.FontType;
    private var _fontBio as Graphics.FontType;
    private var _fontSmall as Graphics.FontType;
    private var _fontTiny as Graphics.FontType;
    private var _fontSummaryVal as Graphics.FontType;

    public function initialize(app as BreathApp) {
        View.initialize();
        _app = app;

        _fontTitle = Graphics.FONT_SMALL;
        _fontPhase = Graphics.FONT_MEDIUM;
        _fontCount = Graphics.FONT_NUMBER_HOT;
        _fontBio = Graphics.FONT_SMALL;
        _fontSmall = Graphics.FONT_XTINY;
        _fontTiny = Graphics.FONT_XTINY;
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
        var vTiny = loadVectorFont(textFaces, 20);
        var vSumVal = loadVectorFont(numFaces, 54);

        if (vTitle != null && vPhase != null && vCount != null &&
            vBio != null && vSmall != null && vTiny != null && vSumVal != null) {
            _fontTitle = vTitle;
            _fontPhase = vPhase;
            _fontCount = vCount;
            _fontBio = vBio;
            _fontSmall = vSmall;
            _fontTiny = vTiny;
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
            drawPostSessionPage(dc, width, height, cx, cy, proto);
        } else {
            drawActiveScreen(dc, width, height, cx, cy, proto, state == BreathProtocol.STATE_PAUSED);
        }
    }

    // -------------------------------------------------------------------------
    // Ready Screen
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
            proto.getActiveCadenceText() + "  •  " + proto.getDurationMinutes().format("%d") + " MIN",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

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
    // Active / Paused Full-Range Breathing Pacer Screen
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

        var maxRadius = (cx - BEZEL_INSET_PX).toFloat();
        var outerR = cx - BEZEL_INSET_PX;

        if (isPaused) {
            dc.setColor(COLOR_PAUSED_RING, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(8);
            dc.drawCircle(cx, cy, outerR);
        } else {
            dc.setColor(COLOR_PROGRESS_BG, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(4);
            dc.drawCircle(cx, cy, outerR);

            var progress = proto.getSessionProgressFraction();
            drawProgressArc(dc, cx, cy, outerR, progress, COLOR_TEXT_MUTED, 4);
        }

        var fill = proto.getLungFillFraction();
        var radius = Math.round(CIRCLE_MIN_RADIUS + ((maxRadius - CIRCLE_MIN_RADIUS) * fill)).toNumber();

        if (radius > 44) {
            dc.setColor(COLOR_HALO_DIM, Graphics.COLOR_TRANSPARENT);
            dc.setPenWidth(5);
            dc.drawCircle(cx, cy, radius - 14);
        }

        var ringWidth = (phaseType == BreathProtocol.PHASE_INHALE_TOP_OFF) ? 14 : 10;
        dc.setColor(phaseColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(ringWidth);
        dc.drawCircle(cx, cy, radius);

        var topText = BreathProtocol.getProtocolShortName(proto.getProtocolId()) +
            "  " + BreathView.formatMinuteSecond(proto.getSessionRemainingSeconds());
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 13) / 100,
            _fontSmall,
            topText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 37) / 100,
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
            (height * 64) / 100,
            _fontCount,
            phaseSec.format("%d"),
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var tracker = _app.getTracker();
        var hrLine = BreathView.formatHrWithDelta(tracker.getCurrentHeartRate(), tracker.getHeartRateDelta());
        var delta = tracker.getHeartRateDelta();
        var hrColor = (delta != null && delta < 0) ? COLOR_GOOD_DROP : Graphics.COLOR_WHITE;

        dc.setColor(hrColor, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 80) / 100,
            _fontBio,
            hrLine,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var hrvLine = BreathView.formatRmssdLine(tracker.getRollingRmssdMs());
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 88) / 100,
            _fontSmall,
            hrvLine,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // -------------------------------------------------------------------------
    // Scrollable Post-Session Summary & Graph Pages (Pages 0..3)
    // -------------------------------------------------------------------------

    private function drawPostSessionPage(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        cy as Number,
        proto as BreathProtocol
    ) as Void {
        var page = _app.getSummaryPage();
        if (page == 0) {
            drawOverviewPage(dc, width, height, cx, cy, proto);
        } else if (page == 1) {
            drawHeartRateGraphPage(dc, width, height, cx, proto);
        } else if (page == 2) {
            drawStressGraphPage(dc, width, height, cx, proto);
        } else {
            drawHrvGraphPage(dc, width, height, cx, proto);
        }

        drawPageIndicatorDots(dc, width, cy, page, BreathApp.SUMMARY_PAGE_COUNT);
    }

    //! Page 0: Numeric Overview Summary
    private function drawOverviewPage(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        cy as Number,
        proto as BreathProtocol
    ) as Void {
        dc.setColor(COLOR_GOOD_DROP, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(5);
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
            (height * 42) / 100,
            _fontTitle,
            hrSummary,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var rmssd = tracker.getSessionRmssdMs();
        var rmssdText = (rmssd != null)
            ? ("HRV " + Math.round(rmssd).toNumber().format("%d") + " ms")
            : "HRV -- ms";
        dc.setColor(COLOR_INHALE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 57) / 100,
            _fontSummaryVal,
            rmssdText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var startS = tracker.getStartEffectiveStress();
        var endS = tracker.getCurrentEffectiveStress();
        var stressText = "STRESS --";
        if (startS != null && endS != null) {
            stressText = "STRESS " + startS.format("%d") + " -> " + endS.format("%d");
        } else if (endS != null) {
            stressText = "STRESS " + endS.format("%d");
        }
        dc.setColor(COLOR_STRESS_LOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 71) / 100,
            _fontSmall,
            stressText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 84) / 100,
            _fontTiny,
            "SWIPE: GRAPHS  •  TOP: SAVE",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! Page 1: Heart Rate Over Time Graph
    private function drawHeartRateGraphPage(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        proto as BreathProtocol
    ) as Void {
        var tracker = _app.getTracker();
        var hrHist = tracker.getHrHistory();

        dc.setColor(COLOR_HR_LINE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 12) / 100,
            _fontTitle,
            "HEART RATE",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var startHr = tracker.getStartHeartRateRounded();
        var endHr = tracker.getCurrentHeartRate();
        var deltaHr = tracker.getHeartRateDelta();
        var subText = "bpm";
        if (startHr != null && endHr != null) {
            subText = startHr.format("%d") + " -> " + endHr.format("%d") + " bpm";
            if (deltaHr != null) {
                var sign = (deltaHr > 0) ? "+" : "";
                subText = subText + " (" + sign + deltaHr.format("%d") + ")";
            }
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 21) / 100,
            _fontSmall,
            subText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var chartX = (width * 17) / 100;
        var chartY = (height * 29) / 100;
        var chartW = (width * 67) / 100;
        var chartH = (height * 42) / 100;

        drawLineGraph(
            dc,
            hrHist,
            chartX,
            chartY,
            chartW,
            chartH,
            COLOR_HR_LINE,
            COLOR_HR_FILL,
            null,
            null,
            proto.getTotalElapsedSeconds()
        );

        var minHr = tracker.getMinHeartRate();
        var avgHr = tracker.getAvgHeartRateRounded();
        var maxHr = tracker.getMaxHeartRate();
        var foot = "MIN " + ((minHr != null) ? minHr.format("%d") : "--") +
            "   AVG " + ((avgHr != null) ? avgHr.format("%d") : "--") +
            "   MAX " + ((maxHr != null) ? maxHr.format("%d") : "--");
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 84) / 100,
            _fontTiny,
            foot,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! Page 2: Garmin-Style Autonomic Stress Graph (0-100 Color-Coded Zones)
    private function drawStressGraphPage(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        proto as BreathProtocol
    ) as Void {
        var tracker = _app.getTracker();
        var stressHist = tracker.getStressHistory();

        dc.setColor(COLOR_STRESS_LOW, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 12) / 100,
            _fontTitle,
            "STRESS LEVEL",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var startS = tracker.getStartEffectiveStress();
        var endS = tracker.getCurrentEffectiveStress();
        var subText = "0 - 100 (HRV Derived)";
        if (startS != null && endS != null) {
            var diff = endS - startS;
            var sign = (diff > 0) ? "+" : "";
            subText = startS.format("%d") + " -> " + endS.format("%d") + " (" + sign + diff.format("%d") + ")";
        }
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 21) / 100,
            _fontSmall,
            subText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var chartX = (width * 17) / 100;
        var chartY = (height * 29) / 100;
        var chartW = (width * 67) / 100;
        var chartH = (height * 42) / 100;

        drawStressBarGraph(dc, stressHist, chartX, chartY, chartW, chartH, proto.getTotalElapsedSeconds());

        var stats = computeArrayStats(stressHist);
        var avgStr = (stats[0] > 0) ? stats[2].format("%d") : "--";
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 84) / 100,
            _fontTiny,
            "REST <25   •   AVG " + avgStr,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    //! Page 3: Vagal Tone / Rolling RMSSD HRV Graph (ms)
    private function drawHrvGraphPage(
        dc as Graphics.Dc,
        width as Number,
        height as Number,
        cx as Number,
        proto as BreathProtocol
    ) as Void {
        var tracker = _app.getTracker();
        var hrvHist = tracker.getRmssdHistory();

        dc.setColor(COLOR_HRV_LINE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 12) / 100,
            _fontTitle,
            "VAGAL HRV",
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var sessRmssd = tracker.getSessionRmssdMs();
        var subText = (sessRmssd != null)
            ? ("AVG " + Math.round(sessRmssd).toNumber().format("%d") + " ms (RMSSD)")
            : "RMSSD (ms)";
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 21) / 100,
            _fontSmall,
            subText,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );

        var chartX = (width * 17) / 100;
        var chartY = (height * 29) / 100;
        var chartW = (width * 67) / 100;
        var chartH = (height * 42) / 100;

        drawLineGraph(
            dc,
            hrvHist,
            chartX,
            chartY,
            chartW,
            chartH,
            COLOR_HRV_LINE,
            COLOR_HRV_FILL,
            null,
            null,
            proto.getTotalElapsedSeconds()
        );

        var stats = computeArrayStats(hrvHist);
        var foot = (stats[0] > 0)
            ? ("MIN " + stats[1].format("%d") + "   AVG " + stats[2].format("%d") + "   PEAK " + stats[3].format("%d"))
            : "MIN --   AVG --   PEAK --";
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(
            cx,
            (height * 84) / 100,
            _fontTiny,
            foot,
            Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    // -------------------------------------------------------------------------
    // Chart Rendering Primitives
    // -------------------------------------------------------------------------

    //! Draws a shaded line graph with auto-scaled (or fixed) Y-axis and time X-axis.
    private function drawLineGraph(
        dc as Graphics.Dc,
        values as Array<Number>,
        x as Number,
        y as Number,
        w as Number,
        h as Number,
        lineColor as Number,
        fillColor as Number,
        fixedMin as Number?,
        fixedMax as Number?,
        totalSec as Float
    ) as Void {
        var stats = computeArrayStats(values);
        var validCount = stats[0];
        var dataMin = stats[1];
        var dataMax = stats[3];

        // Subtle horizontal grid lines (top, mid, bottom)
        dc.setColor(COLOR_GRID, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        dc.drawLine(x, y, x + w, y);
        dc.drawLine(x, y + (h / 2), x + w, y + (h / 2));
        dc.drawLine(x, y + h, x + w, y + h);

        drawTimeAxis(dc, x, y + h + 16, w, totalSec);

        if (validCount < 2) {
            dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                x + (w / 2),
                y + (h / 2),
                _fontSmall,
                "Collecting data...",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        var yMin = (fixedMin != null) ? fixedMin : (dataMin - 3);
        var yMax = (fixedMax != null) ? fixedMax : (dataMax + 3);
        if (yMin < 0) {
            yMin = 0;
        }
        if ((yMax - yMin) < 6) {
            yMax = yMin + 6;
        }

        // Y-axis max & min tick labels on the left
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x - 8, y, _fontTiny, yMax.format("%d"), Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x - 8, y + h, _fontTiny, yMin.format("%d"), Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        var n = values.size();
        var span = (yMax - yMin).toFloat();

        // Pass 1: Soft under-curve shading
        dc.setColor(fillColor, Graphics.COLOR_TRANSPARENT);
        var stepPen = (n > 0 && w / n > 2) ? (w / n) : 2;
        if (stepPen > 6) {
            stepPen = 6;
        }
        dc.setPenWidth(stepPen);
        for (var i = 0; i < n; i++) {
            var v = values[i];
            if (v >= 0) {
                var px = x + ((i * (w - 1)) / (n - 1));
                var py = mapValueToY(v, yMin, span, y, h);
                dc.drawLine(px, py, px, y + h - 1);
            }
        }

        // Pass 2: Crisp 3px polyline
        dc.setColor(lineColor, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(3);
        var prevX = -1;
        var prevY = -1;
        for (var i = 0; i < n; i++) {
            var v = values[i];
            if (v >= 0) {
                var px = x + ((i * (w - 1)) / (n - 1));
                var py = mapValueToY(v, yMin, span, y, h);
                if (prevX >= 0) {
                    dc.drawLine(prevX, prevY, px, py);
                }
                prevX = px;
                prevY = py;
            }
        }
    }

    //! Draws a Garmin-style 0-100 Stress bar chart color-coded by autonomic stress zone.
    private function drawStressBarGraph(
        dc as Graphics.Dc,
        values as Array<Number>,
        x as Number,
        y as Number,
        w as Number,
        h as Number,
        totalSec as Float
    ) as Void {
        // Horizontal zone guide lines at 100, 75, 50, 25, 0
        dc.setColor(COLOR_GRID, Graphics.COLOR_TRANSPARENT);
        dc.setPenWidth(1);
        for (var q = 0; q <= 4; q++) {
            var gy = y + ((h * q) / 4);
            dc.drawLine(x, gy, x + w, gy);
        }

        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x - 8, y, _fontTiny, "100", Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x - 8, y + (h / 2), _fontTiny, "50", Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(x - 8, y + h, _fontTiny, "0", Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER);

        drawTimeAxis(dc, x, y + h + 16, w, totalSec);

        var stats = computeArrayStats(values);
        if (stats[0] < 1) {
            dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
            dc.drawText(
                x + (w / 2),
                y + (h / 2),
                _fontSmall,
                "Collecting HRV...",
                Graphics.TEXT_JUSTIFY_CENTER | Graphics.TEXT_JUSTIFY_VCENTER
            );
            return;
        }

        // Bucket into at most 36 crisp vertical bars across the chart width
        var n = values.size();
        var maxBars = 36;
        var numBars = (n < maxBars) ? n : maxBars;
        var slotW = w.toFloat() / numBars.toFloat();
        var barW = Math.floor(slotW).toNumber() - 2;
        if (barW < 2) {
            barW = 2;
        }

        for (var b = 0; b < numBars; b++) {
            var startIdx = (b * n) / numBars;
            var endIdx = ((b + 1) * n) / numBars;
            if (endIdx <= startIdx) {
                endIdx = startIdx + 1;
            }
            if (endIdx > n) {
                endIdx = n;
            }

            var sum = 0;
            var cnt = 0;
            for (var k = startIdx; k < endIdx; k++) {
                var v = values[k];
                if (v >= 0) {
                    sum += v;
                    cnt += 1;
                }
            }

            if (cnt > 0) {
                var avgVal = sum / cnt;
                if (avgVal > 100) {
                    avgVal = 100;
                }
                var barH = Math.round((avgVal.toFloat() / 100.0) * h.toFloat()).toNumber();
                if (barH < 3) {
                    barH = 3;
                }
                var bx = x + Math.round(b.toFloat() * slotW).toNumber() + 1;
                var by = y + h - barH;

                dc.setColor(colorForStressZone(avgVal), Graphics.COLOR_TRANSPARENT);
                dc.fillRectangle(bx, by, barW, barH);
            }
        }
    }

    private function drawTimeAxis(
        dc as Graphics.Dc,
        x as Number,
        y as Number,
        w as Number,
        totalSec as Float
    ) as Void {
        dc.setColor(COLOR_TEXT_MUTED, Graphics.COLOR_TRANSPARENT);
        dc.drawText(x, y, _fontTiny, "0:00", Graphics.TEXT_JUSTIFY_LEFT | Graphics.TEXT_JUSTIFY_VCENTER);
        dc.drawText(
            x + w,
            y,
            _fontTiny,
            BreathView.formatMinuteSecond(totalSec),
            Graphics.TEXT_JUSTIFY_RIGHT | Graphics.TEXT_JUSTIFY_VCENTER
        );
    }

    private function drawPageIndicatorDots(
        dc as Graphics.Dc,
        width as Number,
        cy as Number,
        activePage as Number,
        totalPages as Number
    ) as Void {
        var dotX = width - 20;
        var spacing = 18;
        var startY = cy - (((totalPages - 1) * spacing) / 2);
        for (var i = 0; i < totalPages; i++) {
            var dotY = startY + (i * spacing);
            if (i == activePage) {
                dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(dotX, dotY, 4);
            } else {
                dc.setColor(COLOR_GRID, Graphics.COLOR_TRANSPARENT);
                dc.fillCircle(dotX, dotY, 3);
            }
        }
    }

    private function mapValueToY(val as Number, yMin as Number, span as Float, y as Number, h as Number) as Number {
        var frac = (val - yMin).toFloat() / span;
        var py = y + h - Math.round(frac * h.toFloat()).toNumber();
        if (py < y) {
            py = y;
        } else if (py > (y + h)) {
            py = y + h;
        }
        return py;
    }

    private function colorForStressZone(stress as Number) as Number {
        if (stress <= 25) {
            return COLOR_STRESS_REST;
        }
        if (stress <= 50) {
            return COLOR_STRESS_LOW;
        }
        if (stress <= 75) {
            return COLOR_STRESS_MED;
        }
        return COLOR_STRESS_HIGH;
    }

    //! Computes [validCount, min, avg, max] across non-negative entries in an integer series.
    private function computeArrayStats(values as Array<Number>) as Array<Number> {
        var count = 0;
        var minV = 0;
        var maxV = 0;
        var sum = 0;
        var n = values.size();
        for (var i = 0; i < n; i++) {
            var v = values[i];
            if (v >= 0) {
                if (count == 0) {
                    minV = v;
                    maxV = v;
                } else {
                    if (v < minV) {
                        minV = v;
                    }
                    if (v > maxV) {
                        maxV = v;
                    }
                }
                sum += v;
                count += 1;
            }
        }
        var avgV = (count > 0) ? Math.round(sum.toFloat() / count.toFloat()).toNumber() : 0;
        return [count, minV, avgV, maxV] as Array<Number>;
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
