import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// The bar button. Owns the plugin's single IPC target and the icon; the board,
// the game state, and the save file all live in Panel.qml, which this loads
// eagerly so a game keeps its clock running while the popup is closed.
//
// The loader/injectPanel scaffolding and the deferred IPC registration below
// follow OmaWarden's BarWidget.qml (MIT, (c) 2026 Salem Sayed),
// https://github.com/salemsayed/omawarden - it is that project's solution to
// two Omarchy quirks: the host assigning `bar` and `settings` across separate
// ticks, and a moved widget briefly overlapping its own replacement on the
// process-wide IPC target.
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
  readonly property bool canStart: panel ? panel.canStart === true : false
  // Mark is the default: the wordmark is 73px of bar for a game, which is more
  // than it is worth beside a clock. Wordmark keeps the old look for anyone who
  // wants it, Icon falls back to the Nerd Font glyph.
  readonly property string barStyle: setting("barStyle", "Mark")
  // A 58px wordmark cannot fit a 28px vertical bar, so that orientation gets
  // the mark instead - it is square, so it fits either way, and it reads far
  // better than the glyph it used to fall back to.
  readonly property string effectiveStyle: barStyle === "Wordmark" && vertical ? "Mark" : barStyle
  readonly property bool wordmark: effectiveStyle === "Wordmark"
  readonly property bool drawn: effectiveStyle !== "Icon"

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

  // Dealing over a board with work on it asks first. When the popup is shut,
  // that means opening it onto the question rather than silently doing nothing
  // or silently destroying the game.
  function requestNewGame(difficulty) {
    if (!panel) return "unavailable"
    // Nothing armed: open the panel so a difficulty can be picked, rather than
    // failing silently at a bar icon with no way to explain itself.
    if (!difficulty && !panel.canStart) {
      panel.open()
      return "choose a difficulty"
    }
    if (panel.needsConfirm) {
      panel.requestNewGame(difficulty)
      panel.open()
      return "confirm"
    }
    panel.newGame(difficulty)
    return panel.difficulty
  }

  function requestAbandon() {
    if (!panel) return "unavailable"
    if (!panel.started) return "no game"
    // A won board is not abandonable, the same as at the button.
    if (!panel.canAbandon) return "already solved"
    if (panel.needsConfirm) {
      panel.requestAbandon()
      panel.open()
      return "confirm"
    }
    panel.abandon()
    return "ok"
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
    function newGame(difficulty: string): string { return root.requestNewGame(difficulty) }
    // Clearing keeps the puzzle and is undoable, so it needs no confirmation.
    function clear(): string {
      if (!root.panel) return "unavailable"
      if (!root.panel.canClear) return root.panel.solved ? "already solved" : "nothing to clear"
      root.panel.restart()
      return "ok"
    }
    function abandon(): string { return root.requestAbandon() }
    function stats(): string {
      if (!root.panel) return "unavailable"
      var s = root.panel.stats
      return s.solved + "/" + s.started + " solved, " + Model.winRate(s)
        + "% win rate, streak " + s.streak + " (best " + s.bestStreak + ")"
    }
    // Puts a finished board away. Nothing is lost, so unlike abandon it needs
    // no confirmation and costs no streak.
    function done(): string {
      if (!root.panel) return "unavailable"
      if (!root.panel.started) return "no game"
      if (!root.panel.solved) return "not solved"
      root.panel.finishBoard()
      return "ok"
    }
    // Irreversible, so it asks in the panel where the question can be read,
    // exactly as newGame and abandon do.
    function resetStats(): string {
      if (!root.panel) return "unavailable"
      if (root.panel.stats.started === 0) return "nothing to reset"
      root.panel.requestResetStats()
      root.panel.open()
      return "confirm"
    }
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

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar

    // Only the Icon style falls back to WidgetButton's own label and glyph;
    // both drawn styles carry their own art in the Row below.
    labelVisible: !root.drawn
    text: root.drawn ? "" : Model.glyph(root.gameState)
    hasVisualContent: true
    fontSize: Style.bar.iconFont
    fixedWidth: root.drawn ? Math.round(content.implicitWidth + Style.spaceReal(9)) : (root.vertical ? -1 : Style.bar.iconSlot)
    fixedHeight: root.vertical ? Style.bar.iconSlot : -1

    // A finished board is worth a colour change; a game in progress is not,
    // since the bar should not nag while you think.
    active: root.solved
    // WidgetButton's activeColor defaults to bar.urgent - the colour this bar
    // reserves for things that are wrong. A solved sudoku is the opposite of
    // that, so it takes the theme's accent instead. Deliberately not a green:
    // the palette has no success token, so any green would be a fixed colour
    // sitting in a widget that otherwise follows the theme everywhere.
    activeColor: Color.accent
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
      // Middle click does nothing on purpose, and neither does right click deal
      // a board any more: dealing from the bar put a destructive action one slip
      // away, in the one place the confirmation prompt cannot be seen.
      if (pressedButton === Qt.RightButton && root.panel) root.panel.togglePause()
      else if (pressedButton === Qt.LeftButton) root.togglePanel()
    }

    Row {
      id: content
      visible: root.drawn
      anchors.centerIn: parent
      spacing: Style.spaceReal(6)

      // Both marks take the same three inputs, so which one is on screen is
      // the only difference between the two styles.
      Icon {
        visible: root.wordmark
        anchors.verticalCenter: parent.verticalCenter
        barSize: root.barSize
        solved: root.solved
        fontFamily: root.bar ? root.bar.fontFamily : Style.font.family
        // Track the button's own colour so solved and paused states carry
        // through to the wordmark rather than only to the timer beside it.
        foreground: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }

      Mark {
        visible: !root.wordmark
        anchors.verticalCenter: parent.verticalCenter
        barSize: root.barSize
        solved: root.solved
        foreground: button.active && button.useActiveColor ? button.activeColor : button.foreground
      }

      Text {
        anchors.verticalCenter: parent.verticalCenter
        // The mark fits a vertical bar, the timer beside it does not.
        visible: root.showTimer && root.started && !root.vertical
        textFormat: Text.PlainText
        text: Model.formatTime(root.elapsedMs)
        color: button.active && button.useActiveColor ? button.activeColor : button.foreground
        font.family: root.bar ? root.bar.fontFamily : Style.font.family
        font.pixelSize: Style.bar.iconFont
        renderType: Text.NativeRendering
      }
    }
  }
}
