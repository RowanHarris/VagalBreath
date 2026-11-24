import Toybox.Lang;
import Toybox.WatchUi;

//! Input & menu delegates for VagalBreath on Garmin Venu 3.
//!
//! Controls:
//!   - Ready Screen:
//!       * Top-Right (KEY_ENTER) or Tap: Start session immediately
//!       * Swipe Up/Down or Menu: Open Protocol & Duration Setup Menu2
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
        // Swallow accidental touch taps while eyes are closed during an active session
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
            return false; // Exit cleanly before starting
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
        var durLabel = WatchUi.loadResource(Rez.Strings.MenuDuration) as String;
        var startLabel = WatchUi.loadResource(Rez.Strings.MenuStart) as String;

        var protoSub = BreathProtocol.getProtocolShortName(proto.getProtocolId());
        var durSub = proto.getDurationMinutes().format("%d") + " min";

        var menu = new WatchUi.Menu2({ :title => title });
        menu.addItem(new WatchUi.MenuItem(protoLabel, protoSub, :protocol, null));
        menu.addItem(new WatchUi.MenuItem(durLabel, durSub, :duration, null));
        menu.addItem(new WatchUi.MenuItem(startLabel, null, :start, null));

        WatchUi.pushView(menu, new BreathSetupMenuDelegate(_app), WatchUi.SLIDE_UP);
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

//! Setup menu delegate routing to Protocol Picker, Duration Picker, or immediate Start.
class BreathSetupMenuDelegate extends WatchUi.Menu2InputDelegate {

    private var _app as BreathApp;

    public function initialize(app as BreathApp) {
        Menu2InputDelegate.initialize();
        _app = app;
    }

    public function onSelect(item as WatchUi.MenuItem) as Void {
        var id = item.getId();
        if (id == :protocol) {
            pushProtocolPicker(item);
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

    private function pushProtocolPicker(parentItem as WatchUi.MenuItem) as Void {
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

        WatchUi.pushView(menu, new BreathProtocolPickerDelegate(_app, parentItem), WatchUi.SLIDE_LEFT);
    }

    private function pushDurationPicker(parentItem as WatchUi.MenuItem) as Void {
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

        WatchUi.pushView(menu, new BreathDurationPickerDelegate(_app, parentItem), WatchUi.SLIDE_LEFT);
    }
}

class BreathProtocolPickerDelegate extends WatchUi.Menu2InputDelegate {

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
            _app.selectProtocol(id);
            _parentItem.setSubLabel(BreathProtocol.getProtocolShortName(id));
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
