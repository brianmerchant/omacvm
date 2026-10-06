import QtQuick
import Quickshell
import Quickshell.Io
import qs.Ui

// The OmacVM item in Omarchy's bar: a click opens the control centre
// (omacvm, one window). Lit while a feature needs you or an update is out,
// as the control centre and its update notice last saw it
// (~/.cache/omacvm/attention.json).
BarWidget {
  id: root
  moduleName: "omacvm.control"

  property int problems: 0
  property int updates: 0

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  FileView {
    path: Quickshell.env("HOME") + "/.cache/omacvm/attention.json"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: {
      try {
        var a = JSON.parse(text())
        root.problems = a.problems || 0
        root.updates = a.updates || 0
      } catch (e) {
        root.problems = 0
        root.updates = 0
      }
    }
    onLoadFailed: { root.problems = 0; root.updates = 0 }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰘳"   // nf-md-apple_keyboard_command (U+F0633)
    active: root.problems > 0 || root.updates > 0
    tooltipText: root.problems > 0 ? "OmacVM: " + root.problems + (root.problems === 1 ? " feature needs" : " features need") + " a look"
               : root.updates > 0 ? "OmacVM: an update is out"
               : "OmacVM"
    onPressed: function(button) {
      if (root.bar) root.bar.run("omarchy-launch-or-focus-tui omacvm --window")
    }
  }
}
