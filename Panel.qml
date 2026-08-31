import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Sudoku.js" as Sudoku
import "Model.js" as Model

// The board itself: a popup anchored to the bar button, holding game state,
// keyboard handling, and the save file. BarWidget.qml owns the icon and the
// plugin's single IPC target and drives this through the functions below.
Panel {
  id: root

  moduleName: "io.github.bhaveshsooka.omadoku"
  // The bar widget registers the one IpcHandler this plugin id is allowed.
  manageIpc: false

  // Injected by BarWidget.qml once the loader has produced this item.
  property Item anchorItem: null
  property var hostWidget: null

  // ------------------------------------------------------------- settings

  readonly property string difficultySetting: Model.normalizeDifficulty(setting("difficulty", "Medium"), "Medium")
  readonly property bool showTimer: setting("showTimer", true) === true
  readonly property int cellSetting: Math.max(22, Math.min(56, Math.round(setting("cellSize", 34))))
  readonly property bool highlightPeers: setting("highlightPeers", true) === true
  readonly property bool highlightSameDigit: setting("highlightSameDigit", true) === true
  readonly property bool markConflicts: setting("markConflicts", true) === true
  readonly property bool autoCleanNotes: setting("autoCleanNotes", true) === true
  readonly property bool pauseWhenClosed: setting("pauseWhenClosed", false) === true

  // ----------------------------------------------------------- game state

  property string difficulty: root.difficultySetting
  property var puzzle: Sudoku.emptyGrid()      // the clues; 0 where the player may write
  property var solution: Sudoku.emptyGrid()
  property var cells: Sudoku.emptyGrid()       // clues plus whatever the player has entered
  property var notes: Sudoku.emptyNotes()      // one 9-bit pencil-mark mask per cell
  property int selected: 40
  property bool notesMode: false
  property bool solved: false
  property bool paused: false
  property bool started: false
  property int hintsUsed: 0
  property var undoStack: []
  property var redoStack: []
  // Set when a game is restored from disk, so the clock waits for the player
  // to actually look at the board before it starts counting again.
  property bool resumeOnOpen: false

  // ---------------------------------------------------------------- clock
  //
  // Wall-clock based rather than tick-counted: a 1s timer that increments a
  // counter drifts, and stops entirely if the shell is busy. `tick` exists only
  // to give the elapsedMs binding something to recompute against.

  property real accumulatedMs: 0
  property real runningSince: 0
  property int tick: 0

  readonly property bool clockRunning: started && !solved && !paused
  readonly property real elapsedMs: {
    var recomputeOn = root.tick
    return root.accumulatedMs + (root.runningSince > 0 ? Math.max(0, Date.now() - root.runningSince) : 0)
  }

  function startClock() { if (runningSince <= 0) runningSince = Date.now() }
  function stopClock() {
    if (runningSince > 0) {
      accumulatedMs += Math.max(0, Date.now() - runningSince)
      runningSince = 0
    }
  }

  onClockRunningChanged: clockRunning ? startClock() : stopClock()

  Timer {
    interval: 500
    repeat: true
    running: root.clockRunning
    onTriggered: root.tick++
  }

  // Checkpoint the elapsed time periodically so a crash or a hard shell restart
  // costs seconds rather than the whole session.
  Timer {
    interval: 15000
    repeat: true
    running: root.clockRunning
    onTriggered: root.saveNow()
  }

  // -------------------------------------------------------------- derived

  readonly property var conflictMap: root.markConflicts ? Sudoku.conflicts(root.cells) : []
  readonly property int filled: Sudoku.filledCount(root.cells)
  readonly property var digitCounts: Sudoku.digitCounts(root.cells)
  readonly property string gameState: solved ? "solved" : (paused ? "paused" : (started ? "playing" : "idle"))
  readonly property bool canUndo: undoStack.length > 0
  readonly property bool canRedo: redoStack.length > 0

  readonly property color fg: bar ? bar.foreground : Color.popups.text
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property real cell: Style.spaceReal(root.cellSetting)
  readonly property real boardSize: cell * 9

  function shade(alpha) { return Qt.rgba(root.fg.r, root.fg.g, root.fg.b, alpha) }

  // --------------------------------------------------------------- undo
  //
  // Whole-grid snapshots. 81 ints twice per entry is nothing next to the
  // bookkeeping a per-move diff would need for hints and auto-tidied notes.

  function pushUndo() {
    var next = undoStack.slice()
    next.push({ cells: cells.slice(), notes: notes.slice(), hintsUsed: hintsUsed })
    if (next.length > 200) next.shift()
    undoStack = next
    redoStack = []
  }

  function undo() {
    if (undoStack.length === 0) return
    var stack = undoStack.slice()
    var entry = stack.pop()
    var redoNext = redoStack.slice()
    redoNext.push({ cells: cells.slice(), notes: notes.slice(), hintsUsed: hintsUsed })
    undoStack = stack
    redoStack = redoNext
    cells = entry.cells
    notes = entry.notes
    hintsUsed = entry.hintsUsed
    refreshSolved()
    scheduleSave()
  }

  function redo() {
    if (redoStack.length === 0) return
    var stack = redoStack.slice()
    var entry = stack.pop()
    var undoNext = undoStack.slice()
    undoNext.push({ cells: cells.slice(), notes: notes.slice(), hintsUsed: hintsUsed })
    redoStack = stack
    undoStack = undoNext
    cells = entry.cells
    notes = entry.notes
    hintsUsed = entry.hintsUsed
    refreshSolved()
    scheduleSave()
  }

  // --------------------------------------------------------------- moves

  function refreshSolved() {
    solved = Sudoku.isComplete(cells)
  }

  function firstEmptyCell() {
    for (var i = 0; i < 81; i++) if (cells[i] === 0) return i
    return 40
  }

  function editable(index) {
    return started && !solved && !paused && index >= 0 && index < 81 && puzzle[index] === 0
  }

  function setCell(index, digit) {
    if (!editable(index)) return
    // Re-entering the digit already there reads as "undo that", which is what
    // players expect from every other sudoku they have used.
    if (cells[index] === digit) { clearCell(index); return }
    pushUndo()
    var next = cells.slice()
    next[index] = digit
    cells = next
    if (autoCleanNotes) {
      notes = Sudoku.clearPeerNotes(notes, index, digit)
    } else {
      var n = notes.slice()
      n[index] = 0
      notes = n
    }
    refreshSolved()
    scheduleSave()
  }

  function clearCell(index) {
    if (!editable(index)) return
    if (cells[index] === 0 && notes[index] === 0) return
    pushUndo()
    var next = cells.slice()
    next[index] = 0
    cells = next
    var n = notes.slice()
    n[index] = 0
    notes = n
    refreshSolved()
    scheduleSave()
  }

  function toggleNoteAt(index, digit) {
    if (!editable(index)) return
    if (cells[index] !== 0) return
    pushUndo()
    var n = notes.slice()
    n[index] = Sudoku.toggleNote(n[index], digit)
    notes = n
    scheduleSave()
  }

  function fillNotes() {
    if (!started || solved || paused) return
    pushUndo()
    notes = Sudoku.fillAllNotes(cells)
    scheduleSave()
  }

  function hint() {
    if (!started || solved || paused) return
    var index = selected
    // Only spend the hint somewhere it helps: the selected cell if it is blank
    // or wrong, otherwise any other cell that still needs fixing.
    if (puzzle[index] !== 0 || cells[index] === solution[index]) {
      var candidates = []
      for (var i = 0; i < 81; i++)
        if (puzzle[i] === 0 && cells[i] !== solution[i]) candidates.push(i)
      if (candidates.length === 0) return
      index = candidates[Math.floor(Math.random() * candidates.length)]
    }
    pushUndo()
    var next = cells.slice()
    next[index] = solution[index]
    cells = next
    notes = autoCleanNotes ? Sudoku.clearPeerNotes(notes, index, solution[index]) : notes
    hintsUsed = hintsUsed + 1
    selected = index
    refreshSolved()
    scheduleSave()
  }

  function newGame(requested) {
    var level = Model.normalizeDifficulty(requested, root.difficultySetting)
    var game = Sudoku.generate(level, Math.random)
    difficulty = level
    puzzle = game.puzzle
    solution = game.solution
    cells = game.puzzle.slice()
    notes = Sudoku.emptyNotes()
    undoStack = []
    redoStack = []
    hintsUsed = 0
    solved = false
    paused = false
    started = true
    resumeOnOpen = false
    accumulatedMs = 0
    runningSince = 0
    selected = firstEmptyCell()
    // clockRunning may already have been true, in which case its change handler
    // does not fire and the freshly zeroed clock would never start.
    if (clockRunning) startClock()
    saveNow()
  }

  function restart() {
    if (!started) return
    pushUndo()
    cells = puzzle.slice()
    notes = Sudoku.emptyNotes()
    solved = false
    selected = firstEmptyCell()
    scheduleSave()
  }

  function togglePause() {
    if (!started || solved) return
    paused = !paused
    scheduleSave()
  }

  function moveCursor(dx, dy) {
    var r = (Math.floor(selected / 9) + dy + 9) % 9
    var c = (selected % 9 + dx + 9) % 9
    selected = r * 9 + c
  }

  function handleTextKey(text) {
    if (text >= "1" && text <= "9") {
      var digit = parseInt(text, 10)
      if (notesMode) toggleNoteAt(selected, digit)
      else setCell(selected, digit)
      return
    }
    // Backspace and Delete arrive here as single-character text rather than as
    // PanelKeyCatcher's deleteRequested, which is bound to "x".
    if (text === "0" || text === "." || text === "\b" || text === "\u007f") {
      clearCell(selected)
      return
    }
    switch (text) {
      case "n": case "N": notesMode = !notesMode; break
      case "u": case "U": undo(); break
      case "r": case "R": redo(); break
      case "g": case "G": newGame(difficulty); break
      case "a": case "A": fillNotes(); break
      case "p": case "P": togglePause(); break
      case "?": hint(); break
    }
  }

  // --------------------------------------------------------- persistence

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omadoku/"
  readonly property string savePath: stateDir + "game.json"

  function saveNow() {
    if (!started) return
    saveFile.setText(Model.serialize({
      difficulty: root.difficulty,
      puzzle: root.puzzle,
      solution: root.solution,
      cells: root.cells,
      notes: root.notes,
      elapsedMs: root.elapsedMs,
      hintsUsed: root.hintsUsed,
      selected: root.selected,
      notesMode: root.notesMode,
      solved: root.solved
    }))
  }

  function scheduleSave() { saveTimer.restart() }

  function loadSave(text) {
    var saved = Model.parse(text)
    if (!saved) return
    difficulty = saved.difficulty
    puzzle = saved.puzzle
    solution = saved.solution
    cells = saved.cells
    notes = saved.notes
    accumulatedMs = saved.elapsedMs
    runningSince = 0
    hintsUsed = saved.hintsUsed
    selected = saved.selected
    notesMode = saved.notesMode
    undoStack = []
    redoStack = []
    started = true
    solved = Sudoku.isComplete(saved.cells)
    // Hold the clock until the board is actually on screen again.
    paused = !solved
    resumeOnOpen = !solved
  }

  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: root.saveNow()
  }

  Process {
    id: ensureDirProc
    command: ["mkdir", "-p", root.stateDir]
    running: false
  }

  FileView {
    id: saveFile
    path: root.savePath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.loadSave(text())
    // First run: no file yet. FileView reports that as a load failure, and
    // without this branch the plugin would sit waiting for a load that never comes.
    onLoadFailed: root.loadSave("")
  }

  Component.onCompleted: {
    ensureDirProc.running = true
    Qt.callLater(function() { saveFile.reload() })
  }

  onOpenedChanged: {
    if (opened) {
      if (!started) {
        newGame(root.difficultySetting)
      } else if (resumeOnOpen || (pauseWhenClosed && paused)) {
        resumeOnOpen = false
        paused = false
      }
    } else {
      if (pauseWhenClosed && started && !solved) paused = true
      saveNow()
    }
  }

  // ------------------------------------------------------------ the popup

  KeyboardPanel {
    id: panel

    anchorItem: root.anchorItem
    owner: root
    bar: root.bar
    open: root.opened && root.anchorItem !== null
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(root.boardSize)
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) { root.moveCursor(dx, dy) }
      onDeleteRequested: root.clearCell(root.selected)
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleTextKey(text) }
      // Space is the one key the catcher claims that a sudoku board wants back:
      // toggling pencil marks is the most frequent mode switch there is.
      onActivateRequested: root.notesMode = !root.notesMode

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // ---------- header: title, status, clock ----------
        Item {
          width: parent.width
          implicitHeight: Math.max(headerLabels.implicitHeight, clockLabel.implicitHeight)

          Column {
            id: headerLabels
            anchors.left: parent.left
            anchors.right: clockLabel.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              text: "Omadoku"
              color: root.fg
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
              elide: Text.ElideRight
              width: parent.width
            }

            Text {
              textFormat: Text.PlainText
              text: root.difficulty.toUpperCase() + " · " + Model.statusText({
                state: root.gameState,
                filled: root.filled,
                notesMode: root.notesMode,
                hintsUsed: root.hintsUsed
              })
              color: Qt.darker(root.fg, 1.4)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
              font.letterSpacing: 1.2
              elide: Text.ElideRight
              width: parent.width
            }
          }

          Text {
            id: clockLabel
            textFormat: Text.PlainText
            text: Model.formatTime(root.elapsedMs)
            color: root.fg
            opacity: root.paused ? 0.45 : 1.0
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            font.bold: true
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter

            Behavior on opacity { NumberAnimation { duration: 160 } }
          }
        }

        // ---------- difficulty ----------
        Row {
          id: difficultyRow
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing * 3) / 4

          Repeater {
            model: ["Easy", "Medium", "Hard", "Expert"]

            Button {
              required property var modelData
              width: difficultyRow.cellWidth
              text: modelData
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              active: root.difficulty === modelData
              tooltipText: "New " + String(modelData).toLowerCase() + " game"
              onClicked: root.newGame(modelData)
            }
          }
        }

        // ---------- the board ----------
        Item {
          id: boardHolder
          width: parent.width
          implicitHeight: root.boardSize

          Item {
            id: board
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.boardSize
            height: root.boardSize

            Repeater {
              model: 81

              delegate: Item {
                id: cellItem
                required property int index

                readonly property int value: root.cells[index]
                readonly property int noteMask: root.notes[index]
                readonly property bool given: root.puzzle[index] !== 0
                readonly property bool isSelected: root.selected === index
                readonly property bool isPeer: root.highlightPeers && !isSelected
                  && (Sudoku.rowOf(index) === Sudoku.rowOf(root.selected)
                      || Sudoku.colOf(index) === Sudoku.colOf(root.selected)
                      || Sudoku.boxOf(index) === Sudoku.boxOf(root.selected))
                readonly property bool isSameDigit: root.highlightSameDigit && !isSelected
                  && value !== 0 && value === root.cells[root.selected]
                readonly property bool isConflict: root.conflictMap.length === 81 && root.conflictMap[index]

                x: (index % 9) * root.cell
                y: Math.floor(index / 9) * root.cell
                width: root.cell
                height: root.cell

                Rectangle {
                  anchors.fill: parent
                  color: cellItem.isSelected ? root.shade(0.22)
                       : cellItem.isSameDigit ? root.shade(0.13)
                       : cellItem.isPeer ? root.shade(0.06)
                       : "transparent"

                  Behavior on color { ColorAnimation { duration: 110 } }
                }

                // The entered or given digit.
                Text {
                  anchors.centerIn: parent
                  visible: cellItem.value !== 0
                  textFormat: Text.PlainText
                  text: cellItem.value === 0 ? "" : String(cellItem.value)
                  color: cellItem.isConflict ? (root.bar ? root.bar.urgent : Color.urgent) : root.fg
                  // Givens carry the weight; the player's own digits sit lighter,
                  // which reads correctly even in themes where accent == foreground.
                  font.bold: cellItem.given
                  opacity: cellItem.given ? 1.0 : 0.82
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(root.cell * 0.56)
                }

                // Pencil marks, laid out where the digit itself would sit.
                Grid {
                  anchors.centerIn: parent
                  visible: cellItem.value === 0 && cellItem.noteMask !== 0
                  columns: 3
                  spacing: 0

                  Repeater {
                    model: 9

                    Text {
                      required property int index
                      width: Math.round(root.cell / 3)
                      height: Math.round(root.cell / 3)
                      horizontalAlignment: Text.AlignHCenter
                      verticalAlignment: Text.AlignVCenter
                      textFormat: Text.PlainText
                      text: Sudoku.hasNote(cellItem.noteMask, index + 1) ? String(index + 1) : ""
                      color: root.fg
                      opacity: 0.5
                      font.family: root.fontFamily
                      font.pixelSize: Math.round(root.cell * 0.24)
                    }
                  }
                }

                MouseArea {
                  anchors.fill: parent
                  acceptedButtons: Qt.LeftButton | Qt.RightButton
                  cursorShape: Qt.PointingHandCursor
                  onClicked: function(mouse) {
                    root.selected = cellItem.index
                    if (mouse.button === Qt.RightButton) root.clearCell(cellItem.index)
                  }
                }
              }
            }

            // Grid lines last, so they sit above the cell shading. Every third
            // line is heavier - that is what makes the 3x3 boxes readable.
            Repeater {
              model: 10

              Rectangle {
                required property int index
                readonly property real thickness: index % 3 === 0 ? Math.max(2, Style.space(2)) : 1
                width: thickness
                height: board.height
                x: Math.min(Math.max(0, index * root.cell - thickness / 2), board.width - thickness)
                color: root.shade(index % 3 === 0 ? 0.55 : 0.16)
              }
            }

            Repeater {
              model: 10

              Rectangle {
                required property int index
                readonly property real thickness: index % 3 === 0 ? Math.max(2, Style.space(2)) : 1
                height: thickness
                width: board.width
                y: Math.min(Math.max(0, index * root.cell - thickness / 2), board.height - thickness)
                color: root.shade(index % 3 === 0 ? 0.55 : 0.16)
              }
            }

            // Pause curtain. Hiding the board is the whole point of pausing, so
            // it covers the grid completely rather than dimming it.
            Rectangle {
              anchors.fill: parent
              visible: opacity > 0
              opacity: root.paused ? 1.0 : 0.0
              color: Color.popups.background

              Behavior on opacity { NumberAnimation { duration: 140 } }

              Column {
                anchors.centerIn: parent
                spacing: Style.space(6)

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  textFormat: Text.PlainText
                  text: "󰏤"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.displayLarge
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "Paused"
                  color: root.fg
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  font.bold: true
                }

                Text {
                  anchors.horizontalCenter: parent.horizontalCenter
                  text: "Click or press P to resume"
                  color: Qt.darker(root.fg, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              MouseArea {
                anchors.fill: parent
                enabled: root.paused
                cursorShape: Qt.PointingHandCursor
                onClicked: root.togglePause()
              }
            }

            // Solved banner. Deliberately not a curtain: the finished grid is
            // the reward, so this sits in front of the middle band only.
            Rectangle {
              anchors.centerIn: parent
              visible: root.solved
              width: solvedText.implicitWidth + Style.space(24)
              height: solvedText.implicitHeight + Style.space(12)
              radius: Style.cornerRadius
              color: Color.popups.background
              border.width: Math.max(1, Style.space(1))
              border.color: root.shade(0.5)

              Text {
                id: solvedText
                anchors.centerIn: parent
                textFormat: Text.PlainText
                text: "󰄬  Solved in " + Model.formatTime(root.elapsedMs)
                color: root.fg
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
                font.bold: true
              }
            }
          }
        }

        // ---------- digit pad ----------
        Row {
          id: padRow
          width: parent.width
          spacing: Style.space(4)

          readonly property real cellWidth: (width - spacing * 9) / 10

          Repeater {
            model: 9

            Button {
              required property int index
              readonly property int digit: index + 1
              width: padRow.cellWidth
              text: String(digit)
              fontSize: Style.font.subtitle
              foreground: root.fg
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              // A digit placed nine times is spent; dim it rather than remove it
              // so the pad never reflows under the cursor.
              opacity: root.digitCounts[index] >= 9 ? 0.35 : 1.0
              active: root.notesMode
              tooltipText: root.notesMode ? "Pencil in " + digit : "Place " + digit
              onClicked: {
                if (root.notesMode) root.toggleNoteAt(root.selected, digit)
                else root.setCell(root.selected, digit)
              }
            }
          }

          Button {
            width: padRow.cellWidth
            text: "󰅖"
            fontSize: Style.font.subtitle
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            tooltipText: "Clear cell (Backspace)"
            onClicked: root.clearCell(root.selected)
          }
        }

        // ---------- actions ----------
        Row {
          id: actionRow
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing * 4) / 5

          Button {
            width: actionRow.cellWidth
            iconText: "󰏫"
            iconSize: Style.font.body
            text: "Notes"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            active: root.notesMode
            tooltipText: "Pencil marks (N or Space)"
            onClicked: root.notesMode = !root.notesMode
          }

          Button {
            width: actionRow.cellWidth
            iconText: "󰌵"
            iconSize: Style.font.body
            text: "Hint"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            opacity: root.started && !root.solved && !root.paused ? 1.0 : 0.4
            tooltipText: "Reveal one cell (?)"
            onClicked: root.hint()
          }

          Button {
            width: actionRow.cellWidth
            iconText: "󰕌"
            iconSize: Style.font.body
            text: "Undo"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            opacity: root.canUndo ? 1.0 : 0.4
            tooltipText: "Undo (U), redo with R"
            onClicked: root.undo()
          }

          Button {
            width: actionRow.cellWidth
            iconText: "󰏤"
            iconSize: Style.font.body
            text: root.paused ? "Resume" : "Pause"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            active: root.paused
            opacity: root.started && !root.solved ? 1.0 : 0.4
            tooltipText: "Pause the clock (P)"
            onClicked: root.togglePause()
          }

          Button {
            width: actionRow.cellWidth
            iconText: "󰑐"
            iconSize: Style.font.body
            text: "New"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            tooltipText: "New " + root.difficulty.toLowerCase() + " game (G)"
            onClicked: root.newGame(root.difficulty)
          }
        }
      }
    }
  }
}
