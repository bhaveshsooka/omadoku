import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar button. Owns the plugin's single IPC target and the icon; the board,
// the game state, and the save file all live in Panel.qml, which this loads
// eagerly so a game keeps its clock running while the popup is closed.
BarWidget {
  id: root

  moduleName: "io.github.bhaveshsooka.omadoku"

  // Moving a bar widget briefly overlaps the retiring instance with its
  // replacement. Registering the IPC target immediately would collide with the
  // copy that has not been torn down yet, so wait a tick for the slot to clear.
  property bool ipcRegistrationReady: false

  readonly property var panel: panelLoader.item
  readonly property bool opened: panel ? panel.opened === true : false
  readonly property bool started: panel ? panel.started === true : false
  readonly property bool solved: panel ? panel.solved === true : false
  readonly property bool paused: panel ? panel.paused === true : false
  readonly property string gameState: panel ? panel.gameState : "idle"
  readonly property real elapsedMs: panel ? panel.elapsedMs : 0
  readonly property string difficulty: panel ? panel.difficulty : "Medium"
  readonly property int filled: panel ? panel.filled : 0
  readonly property int hintsUsed: panel ? panel.hintsUsed : 0
  readonly property bool showTimer: setting("showTimer", true) === true

  // Popout switching is the bar's one-popup-at-a-time coordination; forward it
  // so opening another widget's popup closes the board cleanly.
  readonly property bool popoutSwitchClosing: panel ? panel.popoutSwitchClosing === true : false

  function injectPanel() {
    var target = panelLoader.item
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
  }

  function open() { if (panel) panel.open() }
  function close() { if (panel) panel.close() }
  function togglePanel() { if (panel) panel.toggle() }
  function closeForPopoutSwitch() { if (panel) panel.closeForPopoutSwitch() }

  function newGame(difficulty) {
    if (!panel) return "unavailable"
    panel.newGame(difficulty)
    return panel.difficulty
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: ipcRegistrationTimer.start()

  Timer {
    id: ipcRegistrationTimer
    interval: 100
    onTriggered: root.ipcRegistrationReady = true
  }

  // Loaded eagerly, not on first summon: the panel holds the clock and the save
  // file, and a game in progress has to keep ticking with the popup shut.
  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      // The bar assigns `bar` and `settings` across two ticks on first mount;
      // a second pass catches whichever landed after the loader completed.
      Qt.callLater(root.injectPanel)
    }
  }

  IpcHandler {
    enabled: root.ipcRegistrationReady
    target: root.moduleName

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.togglePanel() }

    // `omarchy-shell io.github.bhaveshsooka.omadoku newGame Hard`. An unrecognised
    // name falls back to the configured difficulty rather than erroring, so a
    // keybinding with a typo still deals a playable game. (`new` is a reserved
    // word, so the method cannot simply be called that.)
    function newGame(difficulty: string): string { return root.newGame(difficulty) }
    function pause(): string {
      if (!root.panel) return "unavailable"
      root.panel.togglePause()
      return root.panel.paused ? "paused" : "running"
    }
    function hint(): string {
      if (!root.panel) return "unavailable"
      root.panel.hint()
      return String(root.panel.hintsUsed)
    }
    function status(): string {
      return Model.tooltip({
        started: root.started,
        state: root.gameState,
        difficulty: root.difficulty,
        elapsedMs: root.elapsedMs,
        filled: root.filled,
        hintsUsed: root.hintsUsed
      })
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    text: Model.barLabel({
      state: root.gameState,
      showTimer: root.showTimer,
      vertical: root.vertical,
      started: root.started,
      elapsedMs: root.elapsedMs
    })

    // The timer label paints a text block wider than a bare icon, so widen the
    // slot to match rather than letting the digits crowd the neighbours.
    slotSize: Style.bar.iconSlot * (root.showTimer && root.started && !root.vertical ? 2 : 1)

    // A finished board is worth a colour change; a game in progress is not,
    // since the bar should not nag while you think.
    active: root.solved
    dimmed: root.paused

    tooltipText: Model.tooltip({
      started: root.started,
      state: root.gameState,
      difficulty: root.difficulty,
      elapsedMs: root.elapsedMs,
      filled: root.filled,
      hintsUsed: root.hintsUsed
    })

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton) root.newGame(root.difficulty)
      else if (pressedButton === Qt.MiddleButton && root.panel) root.panel.togglePause()
      else root.togglePanel()
    }
  }
}
