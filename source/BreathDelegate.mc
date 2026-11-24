import Toybox.Lang;
import Toybox.WatchUi;

//! Input & menu delegates for VagalBreath on Garmin Venu 3.
//!
//! Controls:
//!   - Ready Screen:
//!       * Top-Right (KEY_ENTER) or Tap: Start session immediately
//!       * Swipe Up/Down or Menu: Open Setup (Protocol, Customize Timing, Duration, Start)
//!       * Bottom-Right (KEY_ESC): Exit app
//!   - Active Session:
//!       * Touch taps/swipes ignored (safe for eyes-closed practice)
//!       * Top-Right (KEY_ENTER) or Bottom-Right (KEY_ESC): Pause & open Pause Menu
//!   - Complete Screen:
//!       * Top-Right, Tap, or Bottom-Right: Open Save / Discard Menu (with "Are you sure?" check)
class BreathDelegate extends WatchUi.BehaviorDelegate {

    private var _app as BreathApp;

    public function initialize(app as BreathApp) {
        BehaviorDelegate.initialize();
        _app = app;
    }

    public function onSelect() as Boolean {
        var state = _app.getProtocol().getState();
        if (state == BreathProtocol.STATE_READY) {
            _app.startSession();
            return true;
        }
        if (state == BreathProtocol.STATE_COMPLETE) {
            pushCompleteMenu();
            return true;
        }
        // During active session, yield so physical KEY_ENTER pauses while screen taps are ignored
        return false;
    }

    public function onTap(clickEvent as WatchUi.ClickEvent) as Boolean {
        return true;
    }

    public function onKey(keyEvent as WatchUi.KeyEvent) as Boolean {
        var key = keyEvent.getKey();
        var state = _app.getProtocol().getState();

        if (key == WatchUi.KEY_ENTER) {
            if (state == BreathProtocol.STATE_ACTIVE) {
                _app.pauseSession();
                pushPausedMenu();
                return true;
            }
            if (state == BreathProtocol.STATE_PAUSED) {
                pushPausedMenu();
                return true;
            }
            if (state == BreathProtocol.STATE_COMPLETE) {
                pushCompleteMenu();
                return true;
            }
        }
        return false;
    }

    public function onBack() as Boolean {
        var state = _app.getProtocol().getState();
        if (state == BreathProtocol.STATE_READY) {
            return false;
        }
        if (state == BreathProtocol.STATE_ACTIVE) {
            _app.pauseSession();
            pushPausedMenu();
            return true;
        }
        if (state == BreathProtocol.STATE_PAUSED) {
            pushPausedMenu();
            return true;
        }
        if (state == BreathProtocol.STATE_COMPLETE) {
            pushCompleteMenu();
            return true;
        }
        return true;
    }

    public function onMenu() as Boolean {
        if (_app.getProtocol().getState() == BreathProtocol.STATE_READY) {
            pushSetupMenu();
            return true;
        }
        return true;
    }

    public function onNextPage() as Boolean {
        if (_app.getProtocol().getState() == BreathProtocol.STATE_READY) {
            pushSetupMenu();
            return true;
        }
        return true;
    }

    public function onPreviousPage() as Boolean {
        if (_app.getProtocol().getState() == BreathProtocol.STATE_READY) {
            pushSetupMenu();
            return true;
        }
        return true;
    }

    // -------------------------------------------------------------------------
    // Setup, Paused, and Complete Menus
    // -------------------------------------------------------------------------

    private function pushSetupMenu() as Void {
        var proto = _app.getProtocol();
        var title = WatchUi.loadResource(Rez.Strings.MenuSetupTitle) as String;
        var protoLabel = WatchUi.loadResource(Rez.Strings.MenuProtocol) as String;
        var timingLabel = WatchUi.loadResource(Rez.Strings.MenuCustomizeTiming) as String;
        var durLabel = WatchUi.loadResource(Rez.Strings.MenuDuration) as String;
        var startLabel = WatchUi.loadResource(Rez.Strings.MenuStart) as String;

        var protoItem = new WatchUi.MenuItem(
            protoLabel,
            BreathProtocol.getProtocolShortName(proto.getProtocolId()),
            :protocol,
            null
        );
        var timingItem = new WatchUi.MenuItem(
            timingLabel,
            proto.getActiveCadenceText(),
            :timing,
            null
        );
        var durItem = new WatchUi.MenuItem(
            durLabel,
            proto.getDurationMinutes().format("%d") + " min",
            :duration,
            null
        );

        var menu = new WatchUi.Menu2({ :title => title });
        menu.addItem(protoItem);
        menu.addItem(timingItem);
        menu.addItem(durItem);
        menu.addItem(new WatchUi.MenuItem(startLabel, null, :start, null));

        WatchUi.pushView(menu, new BreathSetupMenuDelegate(_app, protoItem, timingItem), WatchUi.SLIDE_UP);
    }

    private function pushPausedMenu() as Void {
        var title = WatchUi.loadResource(Rez.Strings.MenuPausedTitle) as String;
        var resumeLabel = WatchUi.loadResource(Rez.Strings.MenuResume) as String;
        var saveLabel = WatchUi.loadResource(Rez.Strings.MenuSave) as String;
        var discardLabel = WatchUi.loadResource(Rez.Strings.MenuDiscard) as String;

        var menu = new WatchUi.Menu2({ :title => title });
        menu.addItem(new WatchUi.MenuItem(resumeLabel, null, :resume, null));
        menu.addItem(new WatchUi.MenuItem(saveLabel, null, :save, null));
        menu.addItem(new WatchUi.MenuItem(discardLabel, null, :discard, null));

        WatchUi.pushView(menu, new BreathSessionMenuDelegate(_app, true), WatchUi.SLIDE_UP);
    }

    private function pushCompleteMenu() as Void {
        var title = WatchUi.loadResource(Rez.Strings.MenuCompleteTitle) as String;
        var saveLabel = WatchUi.loadResource(Rez.Strings.MenuSave) as String;
        var discardLabel = WatchUi.loadResource(Rez.Strings.MenuDiscard) as String;

        var menu = new WatchUi.Menu2({ :title => title });
        menu.addItem(new WatchUi.MenuItem(saveLabel, null, :save, null));
        menu.addItem(new WatchUi.MenuItem(discardLabel, null, :discard, null));

        WatchUi.pushView(menu, new BreathSessionMenuDelegate(_app, false), WatchUi.SLIDE_UP);
    }
}

//! Setup menu delegate routing to Protocol Picker, Per-Stage Timing Editor, Duration Picker, or Start.
class BreathSetupMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as BreathApp;
    private var _protoItem as WatchUi.MenuItem;
    private var _timingItem as WatchUi.MenuItem;

    public function initialize(
        app as BreathApp,
        protoItem as WatchUi.MenuItem,
        timingItem as WatchUi.MenuItem
    ) {
        Menu2InputDelegate.initialize();
        _app = app;
        _protoItem = protoItem;
        _timingItem = timingItem;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :protocol) {
            pushProtocolPicker();
        } else if (id == :timing) {
            pushStageTimingMenu();
        } else if (id == :duration) {
            pushDurationPicker(item);
        } else if (id == :start) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _app.startSession();
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
    }

    private function pushProtocolPicker() as Void {
        var title = WatchUi.loadResource(Rez.Strings.ProtoMenuTitle) as String;
        var menu = new WatchUi.Menu2({ :title => title });

        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.ProtoCyclicSigh) as String,
            WatchUi.loadResource(Rez.Strings.ProtoCyclicSighSub) as String,
            BreathProtocol.PROTO_CYCLIC_SIGH,
            null
        ));
        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.ProtoResonance) as String,
            WatchUi.loadResource(Rez.Strings.ProtoResonanceSub) as String,
            BreathProtocol.PROTO_RESONANCE,
            null
        ));
        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.ProtoVagal46) as String,
            WatchUi.loadResource(Rez.Strings.ProtoVagal46Sub) as String,
            BreathProtocol.PROTO_VAGAL_4_6,
            null
        ));
        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.Proto478) as String,
            WatchUi.loadResource(Rez.Strings.Proto478Sub) as String,
            BreathProtocol.PROTO_4_7_8,
            null
        ));
        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.ProtoBox) as String,
            WatchUi.loadResource(Rez.Strings.ProtoBoxSub) as String,
            BreathProtocol.PROTO_BOX,
            null
        ));

        WatchUi.pushView(
            menu,
            new BreathProtocolPickerDelegate(_app, _protoItem, _timingItem),
            WatchUi.SLIDE_LEFT
        );
    }

    private function pushStageTimingMenu() as Void {
        var proto = _app.getProtocol();
        var title = WatchUi.loadResource(Rez.Strings.TimingMenuTitle) as String;
        var menu = new WatchUi.Menu2({ :title => title });

        var count = proto.getPhaseCount();
        for (var i = 0; i < count; i++) {
            var pType = proto.getPhaseTypeAt(i);
            var pMs = proto.getPhaseDurationMsAt(i);
            menu.addItem(new WatchUi.MenuItem(
                BreathProtocol.getPhaseMenuTitle(pType),
                BreathProtocol.formatDurationSec(pMs) + " s",
                i,
                null
            ));
        }

        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.TimingResetDefaults) as String,
            WatchUi.loadResource(Rez.Strings.TimingResetDefaultsSub) as String,
            :reset_defaults,
            null
        ));

        WatchUi.pushView(
            menu,
            new BreathStageTimingListDelegate(_app, _timingItem),
            WatchUi.SLIDE_LEFT
        );
    }

    private function pushDurationPicker(durItem as WatchUi.MenuItem) as Void {
        var title = WatchUi.loadResource(Rez.Strings.DurMenuTitle) as String;
        var menu = new WatchUi.Menu2({ :title => title });

        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.Dur2Min) as String,
            WatchUi.loadResource(Rez.Strings.Dur2MinSub) as String,
            BreathProtocol.DURATION_2_MIN,
            null
        ));
        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.Dur5Min) as String,
            WatchUi.loadResource(Rez.Strings.Dur5MinSub) as String,
            BreathProtocol.DURATION_5_MIN,
            null
        ));
        menu.addItem(new WatchUi.MenuItem(
            WatchUi.loadResource(Rez.Strings.Dur10Min) as String,
            WatchUi.loadResource(Rez.Strings.Dur10MinSub) as String,
            BreathProtocol.DURATION_10_MIN,
            null
        ));

        WatchUi.pushView(menu, new BreathDurationPickerDelegate(_app, durItem), WatchUi.SLIDE_LEFT);
    }
}

class BreathProtocolPickerDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as BreathApp;
    private var _protoItem as WatchUi.MenuItem;
    private var _timingItem as WatchUi.MenuItem;

    public function initialize(
        app as BreathApp,
        protoItem as WatchUi.MenuItem,
        timingItem as WatchUi.MenuItem
    ) {
        Menu2InputDelegate.initialize();
        _app = app;
        _protoItem = protoItem;
        _timingItem = timingItem;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof Number) {
            _app.selectProtocol(id);
            _protoItem.setSubLabel(BreathProtocol.getProtocolShortName(id));
            _timingItem.setSubLabel(_app.getProtocol().getActiveCadenceText());
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

//! Lists every stage of the active protocol (e.g. Inhale / Top-Off / Exhale) for individual customization.
class BreathStageTimingListDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as BreathApp;
    private var _setupTimingItem as WatchUi.MenuItem;

    public function initialize(app as BreathApp, setupTimingItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        _app = app;
        _setupTimingItem = setupTimingItem;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :reset_defaults) {
            _app.resetCurrentProtocolTimings();
            _setupTimingItem.setSubLabel(_app.getProtocol().getActiveCadenceText());
            WatchUi.popView(WatchUi.SLIDE_RIGHT);
            return;
        }

        if (id instanceof Number) {
            var phaseIndex = id;
            var proto = _app.getProtocol();
            var pType = proto.getPhaseTypeAt(phaseIndex);
            var options = BreathProtocol.getOptionsMsForPhase(pType);

            var picker = new WatchUi.Menu2({ :title => BreathProtocol.getPhaseMenuTitle(pType) });
            for (var i = 0; i < options.size(); i++) {
                var optMs = options[i];
                picker.addItem(new WatchUi.MenuItem(
                    BreathProtocol.formatDurationSec(optMs) + " seconds",
                    null,
                    optMs,
                    null
                ));
            }

            WatchUi.pushView(
                picker,
                new BreathPhaseSecondsPickerDelegate(_app, phaseIndex, item, _setupTimingItem),
                WatchUi.SLIDE_LEFT
            );
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

//! Picks the exact duration (ms) for one breath stage and saves it persistently.
class BreathPhaseSecondsPickerDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as BreathApp;
    private var _phaseIndex as Number;
    private var _stageRowItem as WatchUi.MenuItem;
    private var _setupTimingItem as WatchUi.MenuItem;

    public function initialize(
        app as BreathApp,
        phaseIndex as Number,
        stageRowItem as WatchUi.MenuItem,
        setupTimingItem as WatchUi.MenuItem
    ) {
        Menu2InputDelegate.initialize();
        _app = app;
        _phaseIndex = phaseIndex;
        _stageRowItem = stageRowItem;
        _setupTimingItem = setupTimingItem;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof Number) {
            _app.setCustomPhaseDuration(_phaseIndex, id);
            _stageRowItem.setSubLabel(BreathProtocol.formatDurationSec(id) + " s");
            _setupTimingItem.setSubLabel(_app.getProtocol().getActiveCadenceText());
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

class BreathDurationPickerDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as BreathApp;
    private var _parentItem as WatchUi.MenuItem;

    public function initialize(app as BreathApp, parentItem as WatchUi.MenuItem) {
        Menu2InputDelegate.initialize();
        _app = app;
        _parentItem = parentItem;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id instanceof Number) {
            _app.selectDurationMinutes(id);
            _parentItem.setSubLabel(id.format("%d") + " min");
        }
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_RIGHT);
    }
}

//! Paused & Completion menu delegate with secondary "Are you sure?" Discard confirmation.
class BreathSessionMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as BreathApp;
    private var _isPausedMenu as Boolean;

    public function initialize(app as BreathApp, isPausedMenu as Boolean) {
        Menu2InputDelegate.initialize();
        _app = app;
        _isPausedMenu = isPausedMenu;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :resume) {
            WatchUi.popView(WatchUi.SLIDE_DOWN);
            _app.resumeSession();
        } else if (id == :save) {
            WatchUi.popView(WatchUi.SLIDE_IMMEDIATE);
            _app.finishAndSave();
        } else if (id == :discard) {
            var prompt = WatchUi.loadResource(Rez.Strings.ConfirmDiscardPrompt) as String;
            var dialog = new WatchUi.Confirmation(prompt);
            WatchUi.pushView(dialog, new BreathDiscardConfirmDelegate(_app), WatchUi.SLIDE_IMMEDIATE);
        }
    }

    public function onBack() as Void {
        WatchUi.popView(WatchUi.SLIDE_DOWN);
        if (_isPausedMenu && _app.getProtocol().getState() == BreathProtocol.STATE_PAUSED) {
            _app.resumeSession();
        }
    }
}

class BreathDiscardConfirmDelegate extends WatchUi.ConfirmationDelegate {

    private var _app as BreathApp;

    public function initialize(app as BreathApp) {
        ConfirmationDelegate.initialize();
        _app = app;
    }

    public function onResponse(response as WatchUi.Confirm) as Boolean {
        if (response == WatchUi.CONFIRM_YES) {
            _app.discardAndExit();
        }
        return true;
    }
}
