/**
Message box implementation.


Synopsis:
---
// show message box with single Ok button
new MessageBox(window, "Dialog title"d, "Some message"d).show();

// show message box with OK and CANCEL buttons, cancel by default, and handle its result
new MessageBox(
    window,
    tr("Dialog title"), tr("Some message"),
    [ACTION_OK, ACTION_CANCEL], 1, (a) {
        if (a is ACTION_OK)
            Log.d("OK pressed");
        else if (a is ACTION_CANCEL)
            Log.d("CANCEL pressed");
    }
).show();
---

Copyright: Vadim Lopatin 2014-2017
License:   Boost License 1.0
Authors:   Vadim Lopatin
*/
module beamui.dialogs.messagebox;
/+
import beamui.core.actions;
import beamui.core.i18n;
import beamui.core.signals;
import beamui.core.stdaction;
import beamui.dialogs.dialog;
import beamui.platforms.common.platform;
import beamui.widgets.text;

/// Message box
class MessageBox : Dialog
{
    private dstring _message;
    private Action[] _actions;

    /// Create a message box with specified title and message
    this(Window parentWindow, dstring caption, dstring message,
            Action[] buttons = [ACTION_OK], int defaultButtonIndex = 0,
            void delegate(const Action result) handler = null)
    {
        super(caption, parentWindow, DialogFlag.modal |
            (platform.uiDialogDisplayMode & DialogDisplayMode.messageBoxInPopup ? DialogFlag.popup : 0));
        _message = message;
        _actions = buttons;
        _defaultButtonIndex = defaultButtonIndex;
        if (handler)
            onClose ~= handler;
    }

    override void initialize()
    {
        auto msg = new Label(_message);
        addChild(msg);
        addChild(createButtonsPanel(_actions, _defaultButtonIndex, 0));
    }
}
+/
