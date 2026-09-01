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

  // The save file is read asynchronously, so for the first moments after the
  // panel is built we do not yet know whether a game is waiting on disk.
  // Anything that could deal or write a board has to wait for this, or it will
  // happily overwrite a game in progress with a fresh one.
  property bool saveLoaded: false
  // An open that arrived before the save had loaded, deferred until it has.
  property bool wantsAutoStart: false

  // --------------------------------------------------------- the win parade
  //
  // On a solve every digit bursts into confetti in a random sequence, the grid
  // empties, and a message lands on the bare board.
  //
  // One NumberAnimation drives the whole thing. Each piece's position is
  // arithmetic on `celebrateProgress` rather than an animation of its own,
  // which is the difference between one running animation and roughly sixteen
  // hundred of them - in the process that also draws the bar and the
  // notifications, that distinction is the entire desktop's frame rate.
  property bool celebrating: false
  // The pops have finished and the grid is bare: time for the message.
  property bool celebrateDone: false
  property real celebrateProgress: 0
  // Seeded once when the parade starts, never during a binding: a piece whose
  // trajectory were re-rolled every frame would jitter instead of fly.
  property var confetti: []
  // Per cell, the progress at which its digit goes. Indexed by cell, not by
  // pop order, so the delegate can read its own entry directly.
  property var popAt: []
  // A solve with the panel shut waits rather than playing to an empty room.
  property bool celebratePending: false
  // True only while a game is being rebuilt from disk. A restored board can
  // arrive already solved, and that is a game finished some time ago being read
  // back, not a win happening now.
  property bool restoring: false

  // How long one piece lives, as a fraction of the run.
  readonly property real pieceLife: 0.28

  function buildCelebration() {
    var order = []
    for (var i = 0; i < 81; i++) order.push(i)
    // Shuffled, so the board pops apart rather than unzipping left to right.
    for (var j = order.length - 1; j > 0; j--) {
      var k = Math.floor(Math.random() * (j + 1))
      var swap = order[j]; order[j] = order[k]; order[k] = swap
    }

    var pieces = []
    var pops = new Array(81)
    // Pops occupy the run up to the last piece's lifetime, so the final cell's
    // confetti still has room to fall before the message arrives.
    var window = 1.0 - pieceLife
    for (var n = 0; n < 81; n++) {
      var index = order[n]
      var delay = window * (n / 80)
      pops[index] = delay

      var cx = (index % 9) * root.cell + root.cell / 2
      var cy = Math.floor(index / 9) * root.cell + root.cell / 2
      for (var p = 0; p < 4; p++) {
        var angle = Math.random() * Math.PI * 2
        var speed = root.cell * (0.6 + Math.random() * 1.1)
        pieces.push({
          delay: delay,
          x0: cx,
          y0: cy,
          vx: Math.cos(angle) * speed,
          // Biased upward, so pieces are thrown rather than merely scattered.
          vy: Math.sin(angle) * speed - root.cell * 0.5,
          spin: (Math.random() * 2 - 1) * 540,
          size: Math.max(2, Math.round(root.cell * (0.10 + Math.random() * 0.09))),
          // Tones of the foreground rather than fixed colours: confetti that
          // ignored the theme would be the one thing on screen that did.
          tone: 0.45 + Math.random() * 0.55
        })
      }
    }
    popAt = pops
    confetti = pieces
  }

  function startCelebration() {
    if (!started || !solved) return
    if (!opened) {
      celebratePending = true
      return
    }
    celebratePending = false
    buildCelebration()
    celebrateDone = false
    celebrateProgress = 0
    celebrating = true
    popAnimation.restart()
  }

  function endCelebration() {
    holdTimer.stop()
    popAnimation.stop()
    celebrating = false
    // Left set, a parade deferred by a closed panel would fire again on every
    // reopen for as long as the board stayed solved.
    celebratePending = false
    celebrateDone = false
    celebrateProgress = 0
    // Drop the pieces: 324 objects kept alive for a parade nobody is watching
    // is 324 objects too many.
    confetti = []
    popAt = []
  }

  NumberAnimation {
    id: popAnimation
    target: root
    property: "celebrateProgress"
    from: 0
    to: 1
    duration: 2600
    onFinished: {
      root.celebrateDone = true
      holdTimer.restart()
    }
  }

  Timer {
    id: holdTimer
    interval: 5000
    onTriggered: root.endCelebration()
  }

  // ------------------------------------------------------------- attract
  //
  // With no game in progress the board is not blank, it is a demo solving
  // itself. Its state is kept entirely separate from the real game so there is
  // no chance of the two being confused for one another.
  property var demoGivens: Sudoku.emptyGrid()
  property var demoSolution: Sudoku.emptyGrid()
  property var demoCells: Sudoku.emptyGrid()
  property var demoOrder: []
  property int demoStep: 0
  property int demoHold: 0

  readonly property bool attract: !started

  // The difficulty armed for the next board. Picking one only arms it; nothing
  // is dealt until Start/New is pressed, so a stray click on "Expert" can never
  // cost you the game you are in the middle of.
  property string selectedDifficulty: ""
  readonly property bool canStart: selectedDifficulty !== ""

  // Which face of the panel is showing: the board, or the lifetime stats.
  property string view: "board"

  // Lifetime counters, kept in their own file beside the save.
  property var stats: Model.emptyStats()
  // A solve is recorded exactly once. Undo can flip `solved` back and forth and
  // a restored save can arrive already solved, so the transition alone is not
  // a safe trigger.
  property bool solveRecorded: false

  // "" | "new" | "abandon" - a destructive action waiting on confirmation.
  property string pendingAction: ""
  property string pendingDifficulty: ""

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

  // What the grid renders: the real game, or the demo when there is no game.
  readonly property var boardCells: attract ? demoCells : cells
  readonly property var boardGivens: attract ? demoGivens : puzzle

  readonly property var conflictMap: root.markConflicts && !attract ? Sudoku.conflicts(root.cells) : []
  readonly property int filled: Sudoku.filledCount(root.cells)
  readonly property var digitCounts: Sudoku.digitCounts(root.cells)
  readonly property string gameState: solved ? "solved" : (paused ? "paused" : (started ? "playing" : "idle"))
  // A finished board is finished. Undo used to be the one way back out of a
  // win, which meant the board could become unsolved and then solved again -
  // and every question that followed (does the parade replay? how many times?)
  // existed only to service that one path. Closing it is worth more than the
  // ability to step backwards out of a completed puzzle.
  readonly property bool canUndo: undoStack.length > 0 && !solved
  readonly property bool canRedo: redoStack.length > 0

  // Nothing that could take a finished board back to unfinished stays available
  // once it is finished. Clearing a solved grid and filling it in again, or
  // abandoning a board that is already won, both raise questions the app is
  // better off never being asked. New is the way on from a win.
  readonly property bool canClear: started && hasProgress && !solved
  readonly property bool canAbandon: started && !solved

  // Has the player actually invested anything in this board? Dealing over an
  // untouched grid costs nothing, so only a board with work on it is worth
  // stopping to confirm.
  readonly property bool hasProgress: {
    for (var i = 0; i < 81; i++) if (cells[i] !== puzzle[i]) return true
    return false
  }
  readonly property bool needsConfirm: started && !solved && hasProgress

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
    if (!canUndo) return
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
    // Dealing deliberately means whatever is on disk no longer matters, so the
    // pending-load gate is satisfied from here on.
    saveLoaded = true
    wantsAutoStart = false
    var level = Model.normalizeDifficulty(requested || root.selectedDifficulty, root.difficultySetting)
    selectedDifficulty = level
    // Walking away from a board mid-solve breaks the streak exactly as
    // abandoning it does; dealing over a finished one does not.
    var previousUnfinished = started && !solved
    var game = Sudoku.generate(level, Math.random)
    stats = Model.recordStart(stats, level, previousUnfinished)
    saveStats()
    solveRecorded = false
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

  // Wipe the player's entries, keep the puzzle. Deliberately undoable rather
  // than confirmed: one press of U puts the board back.
  function restart() {
    if (!canClear) return
    pushUndo()
    cells = puzzle.slice()
    notes = Sudoku.emptyNotes()
    // Already false, since canClear refuses a solved board - but the invariant
    // "no entries means not solved" is the function's to keep, not the caller's.
    solved = false
    // solveRecorded deliberately survives: clearing replays the same deal, and
    // one deal is worth at most one recorded solve.
    selected = firstEmptyCell()
    scheduleSave()
  }

  // Give up the board entirely and return to the idle state. Not undoable,
  // which is why it routes through confirmation.
  function abandon() {
    if (!canAbandon) return
    // Unconditional now: canAbandon has already refused a won board, so every
    // board that reaches here is one being given up on.
    stats = Model.recordAbandon(stats)
    saveStats()
    puzzle = Sudoku.emptyGrid()
    solution = Sudoku.emptyGrid()
    cells = Sudoku.emptyGrid()
    notes = Sudoku.emptyNotes()
    undoStack = []
    redoStack = []
    hintsUsed = 0
    solved = false
    solveRecorded = false
    paused = false
    started = false
    resumeOnOpen = false
    accumulatedMs = 0
    runningSince = 0
    selected = 40
    view = "board"
    selectedDifficulty = ""
    dealDemo()
    // started is false now, so saveNow() would decline to write; clear the file
    // directly instead of leaving a finished game on disk to be restored.
    saveFile.setText("")
  }

  // Record the solve once, whichever route completed the board.
  onSolvedChanged: {
    // Undoing back past the finish stops the parade with it; a board that is
    // no longer solved has nothing to celebrate.
    if (!solved) {
      endCelebration()
      return
    }
    if (!started) return
    // Recording a solve and celebrating one are different questions, and tying
    // the parade to solveRecorded conflated them: undo back past the finish and
    // re-solve, and the board would go quiet because the stats had already been
    // written. A deal still counts at most one solve; the parade plays every
    // time the board becomes solved.
    if (!solveRecorded) {
      solveRecorded = true
      stats = Model.recordSolve(stats, difficulty, elapsedMs, hintsUsed)
      saveStats()
      scheduleSave()
    }
    if (!restoring) startCelebration()
  }

  // ------------------------------------------------------------- attract

  function dealDemo() {
    var game = Sudoku.generate("Easy", Math.random)
    demoGivens = game.puzzle
    demoSolution = game.solution
    demoCells = game.puzzle.slice()
    var order = []
    for (var i = 0; i < 81; i++) if (game.puzzle[i] === 0) order.push(i)
    // Shuffled, so it reads as someone solving rather than a cursor sweeping
    // left to right filling in answers.
    for (var j = order.length - 1; j > 0; j--) {
      var k = Math.floor(Math.random() * (j + 1))
      var t = order[j]; order[j] = order[k]; order[k] = t
    }
    demoOrder = order
    demoStep = 0
    demoHold = 0
  }

  function demoTick() {
    if (demoStep >= demoOrder.length) {
      // Let the finished grid sit for a moment before starting over.
      demoHold = demoHold + 1
      if (demoHold > 10) dealDemo()
      return
    }
    var index = demoOrder[demoStep]
    var next = demoCells.slice()
    next[index] = demoSolution[index]
    demoCells = next
    demoStep = demoStep + 1
  }

  // Only animates while it is actually on screen. This runs inside the process
  // that draws the whole desktop; an unwatched animation is pure waste.
  Timer {
    interval: 150
    repeat: true
    running: root.attract && root.opened
    onTriggered: root.demoTick()
  }

  // ------------------------------------------------------- confirmation

  function requestNewGame(level) {
    // Nothing armed, nothing dealt. The difficulty row is the only way in.
    if (!level && !canStart) return
    if (needsConfirm) {
      pendingDifficulty = Model.normalizeDifficulty(level, root.difficultySetting)
      pendingAction = "new"
      return
    }
    newGame(level)
  }

  function requestAbandon() {
    if (!canAbandon) return
    if (needsConfirm) { pendingAction = "abandon"; return }
    abandon()
  }

  function confirmPending() {
    var action = pendingAction
    var level = pendingDifficulty
    cancelPending()
    if (action === "new") newGame(level)
    else if (action === "abandon") abandon()
    else if (action === "resetStats") resetStats()
  }

  // Wipes the lifetime record and nothing else. The game in progress lives in
  // its own file and is left alone: a stats reset that also swept away the
  // board you were playing would be a second, unrelated destruction hiding
  // behind one button. Abandon is how you clear a board.
  function requestResetStats() {
    if (stats.started === 0) return
    pendingAction = "resetStats"
  }

  function resetStats() {
    stats = Model.emptyStats()
    saveStats()
  }

  function cancelPending() {
    pendingAction = ""
    pendingDifficulty = ""
  }

  function confirmPrompt() {
    if (pendingAction === "abandon") return "Abandon this game?"
    if (pendingAction === "new") return "Start a new " + pendingDifficulty.toLowerCase() + " game?"
    if (pendingAction === "resetStats") return "Reset all statistics?"
    return ""
  }

  // The three prompts differ enough that a ternary in the delegate stopped
  // carrying its weight once there were more than two of them.
  function confirmDetail() {
    if (pendingAction === "abandon") return "This board and its time are lost, and the streak resets."
    if (pendingAction === "new") return "The current board is lost, and the streak resets."
    if (pendingAction === "resetStats") return "Every solve, time and streak on record is erased. This cannot be undone. The game you are playing is not affected."
    return ""
  }

  function confirmVerb() {
    if (pendingAction === "abandon") return "Abandon"
    if (pendingAction === "resetStats") return "Reset"
    return "New game"
  }

  // Pencil marks are for working a board out, so the toggle is dead once there
  // is nothing left to work out. Matches the Hint button's condition: a solved
  // or curtained board takes no input either way.
  readonly property bool canTakeNotes: started && !solved && !paused

  function toggleNotesMode() {
    if (!canTakeNotes) return
    notesMode = !notesMode
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
    // Any key cuts the parade short - and then still does what it was pressed
    // for. Swallowing it meant the first keystroke after a win vanished, which
    // is at its worst for undo: the grid is bare while the message is up, so
    // the press appeared to restore the digits and do nothing else.
    if (celebrating) endCelebration()
    // While a confirmation is up, Y and N answer it and nothing else lands on
    // the board. Enter and Esc are handled by the key catcher's own signals.
    if (pendingAction !== "") {
      if (text === "y" || text === "Y") confirmPending()
      else if (text === "n" || text === "N") cancelPending()
      return
    }
    // Idle: the only decision to make is which board to deal, so 1-4 arm a
    // difficulty rather than writing into a demo that is not yours.
    if (!started) {
      if (text >= "1" && text <= "4") selectedDifficulty = Model.LEVELS[parseInt(text, 10) - 1]
      else if (text === "g" || text === "G") requestNewGame(selectedDifficulty)
      else if (text === "s" || text === "S") view = "stats"
      return
    }
    // The stats view has no cells, so digits would be meaningless there.
    if (view === "stats") {
      if (text === "s" || text === "S" || text === "b" || text === "B") view = "board"
      else if (text === "g" || text === "G") requestNewGame(selectedDifficulty)
      return
    }
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
      case "n": case "N": toggleNotesMode(); break
      case "u": case "U": undo(); break
      case "r": case "R": redo(); break
      case "g": case "G": requestNewGame(selectedDifficulty); break
      case "a": case "A": fillNotes(); break
      case "p": case "P": togglePause(); break
      case "c": case "C": restart(); break
      case "s": case "S": view = "stats"; break
      case "?": hint(); break
    }
  }

  // --------------------------------------------------------- persistence

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omadoku/"
  readonly property string savePath: stateDir + "game.json"
  readonly property string statsPath: stateDir + "stats.json"

  function saveNow() {
    // Never write before reading: a save issued in the gap between construction
    // and the file landing would clobber the very game we are about to restore.
    if (!saveLoaded) return
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
  function saveStats() { statsSaveTimer.restart() }

  function loadSave(text) {
    var saved = Model.parse(text)
    if (!saved) {
      // Nothing usable on disk. The gate opens either way, and an open that
      // arrived while we were reading gets its game now.
      // Nothing to restore: sit in attract mode until a difficulty is picked.
      saveLoaded = true
      wantsAutoStart = false
      dealDemo()
      return
    }
    saveLoaded = true
    wantsAutoStart = false
    restoring = true
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
    selectedDifficulty = saved.difficulty
    undoStack = []
    redoStack = []
    started = true
    solved = Sudoku.isComplete(saved.cells)
    // Whatever solved this board recorded it at the time; do not count it twice.
    solveRecorded = solved
    // Hold the clock until the board is actually on screen again.
    paused = !solved
    resumeOnOpen = !solved
    restoring = false
  }

  Timer {
    id: saveTimer
    interval: 400
    repeat: false
    onTriggered: root.saveNow()
  }

  Timer {
    id: statsSaveTimer
    interval: 400
    repeat: false
    onTriggered: statsFile.setText(Model.serializeStats(root.stats))
  }

  FileView {
    id: statsFile
    path: root.statsPath
    watchChanges: false
    atomicWrites: true
    printErrors: false
    onLoaded: root.stats = Model.parseStats(text())
    // No file yet on first run; parseStats("") is the empty ledger.
    onLoadFailed: root.stats = Model.parseStats("")
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
    Qt.callLater(function() {
      saveFile.reload()
      statsFile.reload()
    })
  }

  onOpenedChanged: {
    if (opened) {
      if (started) {
        // Reopening always lands back on the game in progress, whatever tab was
        // left showing. Opening never deals a board - only a difficulty does.
        view = "board"
        cancelPending()
        if (resumeOnOpen || (pauseWhenClosed && paused)) {
          resumeOnOpen = false
          paused = false
        }
        // A board finished while the popup was shut gets its parade now.
        if (celebratePending) startCelebration()
      } else if (demoOrder.length === 0) {
        dealDemo()
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

      onMoveRequested: function(dx, dy) {
        if (root.celebrating) root.endCelebration()
        root.moveCursor(dx, dy)
      }
      onDeleteRequested: if (root.pendingAction === "" && root.view === "board") root.clearCell(root.selected)
      // Esc backs out of a confirmation first, then out of the stats view, and
      // only closes the panel when there is nothing left to back out of.
      onCloseRequested: {
        if (root.celebrating) root.endCelebration()
        else if (root.pendingAction !== "") root.cancelPending()
        else if (root.view !== "board") root.view = "board"
        else root.close()
      }
      onTabRequested: function(direction) { root.switchPanel(direction) }
      onTextKey: function(text) { root.handleTextKey(text) }
      // Space is the one key the catcher claims that a sudoku board wants back:
      // toggling pencil marks is the most frequent mode switch there is.
      onActivateRequested: {
        if (root.celebrating) root.endCelebration()
        else if (root.pendingAction !== "") root.confirmPending()
        else if (root.attract) root.requestNewGame(root.selectedDifficulty)
        else if (root.view === "board") root.toggleNotesMode()
      }

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
              text: (root.attract ? "" : root.difficulty.toUpperCase() + " · ") + Model.statusText({
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
            visible: !root.attract
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

        // ---------- tabs ----------
        Row {
          id: tabRow
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing) / 2

          Button {
            width: tabRow.cellWidth
            iconText: "󰋁"
            iconSize: Style.font.body
            text: "Board"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            active: root.view === "board"
            tooltipText: "The board (B)"
            onClicked: root.view = "board"
          }

          Button {
            width: tabRow.cellWidth
            iconText: "󰄨"
            iconSize: Style.font.body
            text: "Stats"
            fontSize: Style.font.bodySmall
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            active: root.view === "stats"
            tooltipText: "Your record (S)"
            onClicked: root.view = "stats"
          }
        }

        // ---------- difficulty ----------
        Row {
          id: difficultyRow
          visible: root.view === "board" && root.pendingAction === ""
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
              active: root.selectedDifficulty === modelData
              tooltipText: "Choose " + String(modelData).toLowerCase()
                + (root.attract ? ", then press Start" : ", then press New")
              onClicked: root.selectedDifficulty = modelData
            }
          }
        }

        // ---------- the board ----------
        Item {
          id: boardHolder
          visible: root.view === "board"
          width: parent.width
          implicitHeight: root.boardSize

          Item {
            id: board
            anchors.horizontalCenter: parent.horizontalCenter
            width: root.boardSize
            height: root.boardSize
            // The demo is scenery, not the subject: it sits behind the
            // difficulty buttons rather than competing with them.
            opacity: root.attract ? 0.5 : 1.0

            Behavior on opacity { NumberAnimation { duration: 220 } }

            Repeater {
              model: 81

              delegate: Item {
                id: cellItem
                required property int index

                readonly property int value: root.boardCells[index]
                readonly property int noteMask: root.attract ? 0 : root.notes[index]
                readonly property bool given: root.boardGivens[index] !== 0
                readonly property bool isSelected: !root.attract && root.selected === index
                readonly property bool isPeer: !root.attract && root.highlightPeers && !isSelected
                  && (Sudoku.rowOf(index) === Sudoku.rowOf(root.selected)
                      || Sudoku.colOf(index) === Sudoku.colOf(root.selected)
                      || Sudoku.boxOf(index) === Sudoku.boxOf(root.selected))
                readonly property bool isSameDigit: !root.attract && root.highlightSameDigit && !isSelected
                  && value !== 0 && value === root.cells[root.selected]
                readonly property bool isConflict: root.conflictMap.length === 81 && root.conflictMap[index]
                // This cell's digit has already burst, so it is gone from the
                // grid. Everything else about the cell stays put.
                readonly property bool popped: root.celebrating
                  && root.popAt.length === 81
                  && root.celebrateProgress >= root.popAt[index]

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
                  visible: cellItem.value !== 0 && !cellItem.popped
                  textFormat: Text.PlainText
                  text: cellItem.value === 0 ? "" : String(cellItem.value)
                  color: cellItem.isConflict ? (root.bar ? root.bar.urgent : Color.urgent) : root.fg
                  // Givens carry the weight; the player's own digits sit lighter,
                  // which reads correctly even in themes where accent == foreground.
                  font.bold: cellItem.given
                  opacity: cellItem.given ? 1.0 : 0.82
                  font.family: root.fontFamily
                  font.pixelSize: Math.round(root.cell * 0.56)

                  // Each demo digit arrives rather than blinking into place.
                  Behavior on opacity {
                    enabled: root.attract
                    NumberAnimation { duration: 180 }
                  }
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
                  enabled: !root.attract
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

            // The confetti. Every piece is pure arithmetic on celebrateProgress
            // - see the win parade section above for why it is built this way.
            Item {
              anchors.fill: parent
              visible: root.celebrating

              Repeater {
                model: root.confetti

                Rectangle {
                  required property var modelData

                  // 0 before this piece is thrown, 1 once it has faded out.
                  readonly property real t: Math.max(0, Math.min(1,
                    (root.celebrateProgress - modelData.delay) / root.pieceLife))

                  visible: t > 0 && t < 1
                  width: modelData.size
                  height: modelData.size
                  // Below about five pixels a radius reads as a smudge.
                  radius: modelData.size > 4 ? 1 : 0
                  color: root.shade(modelData.tone)
                  // Squared, so a piece holds its colour on the way out and
                  // then goes, rather than spending its whole life half faded.
                  opacity: 1 - t * t
                  rotation: modelData.spin * t
                  x: modelData.x0 + modelData.vx * t - width / 2
                  y: modelData.y0 + modelData.vy * t + root.cell * 3.2 * t * t - height / 2
                }
              }
            }

            // The message, on the bare grid once the last digit has gone.
            Column {
              anchors.centerIn: parent
              visible: opacity > 0
              opacity: root.celebrateDone ? 1 : 0
              spacing: Style.space(4)

              Behavior on opacity { NumberAnimation { duration: 260 } }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: "Congratulations"
                color: root.fg
                font.family: root.fontFamily
                // Heading rather than display: the board is only nine cells
                // wide, and at the smallest cell size that is under 200px.
                font.pixelSize: Style.font.heading
                font.bold: true
              }

              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                textFormat: Text.PlainText
                text: root.difficulty + " solved in " + Model.formatTime(root.elapsedMs)
                color: Qt.darker(root.fg, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            // Clicking anywhere cuts the parade short, the same as any key.
            // Disabled the rest of the time, so it never shadows the cells.
            MouseArea {
              anchors.fill: parent
              enabled: root.celebrating
              onClicked: root.endCelebration()
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
              // The parade carries its own message; two at once is one too many.
              visible: root.solved && !root.celebrating
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

        // ---------- start (idle only) ----------
        //
        // The one action available with no game on the table. Disabled until a
        // difficulty is armed, so the empty state asks a question and waits for
        // the answer rather than guessing one.
        Button {
          visible: root.attract && root.view === "board" && root.pendingAction === ""
          width: parent.width
          iconText: "󰐊"
          iconSize: Style.font.body
          text: root.canStart ? "Start " + root.selectedDifficulty.toLowerCase() + " game" : "Choose a difficulty"
          fontSize: Style.font.bodySmall
          foreground: root.fg
          fontFamily: root.fontFamily
          horizontalPadding: Style.space(2)
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          active: root.canStart
          opacity: root.canStart ? 1.0 : 0.4
          tooltipText: root.canStart ? "Deal the board (Enter)" : "Pick a difficulty above, or press 1-4"
          onClicked: root.requestNewGame(root.selectedDifficulty)
        }

        // ---------- digit pad ----------
        Row {
          id: padRow
          visible: root.view === "board" && root.pendingAction === "" && !root.attract
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

        // ---------- stats ----------
        //
        // Lifetime record. Everything here is derived from the two counters the
        // game already keeps (a start, and a solve with its time and hints), so
        // there is no separate history file to drift out of sync with the save.
        Column {
          id: statsColumn
          visible: root.view === "stats"
          width: parent.width
          spacing: Style.space(14)

          // ----- headline: solves, win rate, streak -----
          Row {
            width: parent.width
            spacing: Style.space(10)

            readonly property real cellWidth: (width - spacing * 2) / 3

            HeadlineStat {
              width: parent.cellWidth
              value: String(root.stats.solved)
              label: "SOLVED"
            }

            HeadlineStat {
              width: parent.cellWidth
              value: root.stats.started > 0 ? Model.winRate(root.stats) + "%" : "—"
              label: "WIN RATE"
            }

            HeadlineStat {
              width: parent.cellWidth
              value: String(root.stats.streak)
              label: "STREAK"
            }
          }

          PanelSeparator { foreground: root.fg }

          // ----- per-difficulty table -----
          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "BY DIFFICULTY"
              foreground: root.fg
              fontFamily: root.fontFamily
            }

            StatsRow {
              level: ""
              solved: "WON"
              best: "BEST"
              average: "AVG"
              header: true
            }

            Repeater {
              model: Model.statsRows(root.stats)

              StatsRow {
                required property var modelData
                level: modelData.level
                solved: modelData.solved
                best: modelData.best
                average: modelData.average
              }
            }
          }

          PanelSeparator { foreground: root.fg }

          // ----- totals -----
          Column {
            width: parent.width
            spacing: Style.spacing.labelGap

            TotalPair {
              label: "Games played"
              value: String(root.stats.started)
            }
            TotalPair {
              label: "Solved without hints"
              value: String(root.stats.cleanSolved)
            }
            TotalPair {
              label: "Best streak"
              value: String(root.stats.bestStreak)
            }
            TotalPair {
              label: "Hints used"
              value: String(root.stats.hints)
            }
            TotalPair {
              label: "Time on solved games"
              value: Model.formatTotalTime(root.stats.timeMs)
            }
          }

          Text {
            visible: root.stats.started === 0
            width: parent.width
            textFormat: Text.PlainText
            text: "No games finished yet. Solve a board and it lands here."
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          // Hidden rather than dimmed while the question is up, so the button
          // cannot be pressed a second time by muscle memory - the same reason
          // the confirmation replaces the action rows on the board tab.
          Button {
            visible: root.pendingAction === ""
            width: parent.width
            iconText: "󰩹"
            iconSize: Style.font.body
            text: "Reset statistics"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            opacity: root.stats.started > 0 ? 1.0 : 0.4
            tooltipText: "Erase every solve, time and streak on record"
            onClicked: root.requestResetStats()
          }
        }

        // ---------- actions: play ----------
        Row {
          id: actionRow
          visible: root.view === "board" && root.pendingAction === "" && !root.attract
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing * 3) / 4

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
            opacity: root.canTakeNotes ? 1.0 : 0.4
            tooltipText: "Pencil marks (N or Space)"
            onClicked: root.toggleNotesMode()
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
        }

        // ---------- actions: the game itself ----------
        //
        // Split from the row above because these three change *which* game you
        // are playing rather than how you are playing it, and two of them throw
        // work away. Seven buttons on one row would also leave no room to label
        // them, which is exactly the wrong economy for destructive actions.
        Row {
          id: gameRow
          visible: root.view === "board" && root.pendingAction === "" && !root.attract
          width: parent.width
          spacing: Style.space(6)

          readonly property real cellWidth: (width - spacing * 2) / 3

          Button {
            width: gameRow.cellWidth
            iconText: "󰇾"
            iconSize: Style.font.body
            text: "Clear"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            opacity: root.canClear ? 1.0 : 0.4
            tooltipText: "Clear your entries, keep the puzzle (C) - undoable"
            onClicked: root.restart()
          }

          Button {
            width: gameRow.cellWidth
            iconText: "󰑐"
            iconSize: Style.font.body
            text: "New"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            opacity: root.canStart ? 1.0 : 0.4
            tooltipText: root.canStart
              ? "New " + root.selectedDifficulty.toLowerCase() + " game (G)"
              : "Choose a difficulty first"
            onClicked: root.requestNewGame(root.selectedDifficulty)
          }

          Button {
            width: gameRow.cellWidth
            iconText: "󰗼"
            iconSize: Style.font.body
            text: "Abandon"
            fontSize: Style.font.caption
            foreground: root.fg
            fontFamily: root.fontFamily
            horizontalPadding: Style.space(2)
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            opacity: root.canAbandon ? 1.0 : 0.4
            tooltipText: "Give up this board and clear it"
            onClicked: root.requestAbandon()
          }
        }

        // ---------- confirmation ----------
        //
        // Takes the place of the action rows rather than floating over them, so
        // the destructive button cannot be clicked again by muscle memory while
        // the question is on screen.
        Column {
          visible: root.pendingAction !== ""
          width: parent.width
          spacing: Style.space(8)

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.confirmPrompt()
            color: root.fg
            font.family: root.fontFamily
            font.pixelSize: Style.font.subtitle
            font.bold: true
            wrapMode: Text.WordWrap
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: root.confirmDetail()
            color: Qt.darker(root.fg, 1.4)
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          Row {
            id: confirmRow
            width: parent.width
            spacing: Style.space(6)

            readonly property real cellWidth: (width - spacing) / 2

            Button {
              width: confirmRow.cellWidth
              // Nothing is being played when the question is about statistics.
              text: root.pendingAction === "resetStats" ? "Keep them" : "Keep playing"
              fontSize: Style.font.bodySmall
              foreground: root.fg
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              tooltipText: "Esc or N"
              onClicked: root.cancelPending()
            }

            Button {
              width: confirmRow.cellWidth
              text: root.confirmVerb()
              fontSize: Style.font.bodySmall
              foreground: root.bar ? root.bar.urgent : Color.urgent
              fontFamily: root.fontFamily
              horizontalPadding: Style.space(2)
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              tooltipText: "Enter or Y"
              onClicked: root.confirmPending()
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------- stats pieces

  component HeadlineStat: Column {
    property string value: ""
    property string label: ""

    spacing: Style.space(2)

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.display
      font.bold: true
    }

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: Qt.darker(root.fg, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.2
    }
  }

  // One line of the difficulty table. The three number columns are fixed
  // fractions rather than laid out by content, so the digits line up down the
  // table instead of drifting with the width of each value.
  component StatsRow: Item {
    property string level: ""
    property string solved: ""
    property string best: ""
    property string average: ""
    property bool header: false

    width: parent.width
    implicitHeight: levelLabel.implicitHeight

    Text {
      id: levelLabel
      anchors.left: parent.left
      width: parent.width * 0.34
      textFormat: Text.PlainText
      text: parent.level
      color: root.fg
      opacity: parent.header ? 0.6 : 1.0
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      elide: Text.ElideRight
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: parent.width * 0.34
      width: parent.width * 0.20
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.solved
      color: root.fg
      opacity: parent.header ? 0.6 : 1.0
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.left: parent.left
      anchors.leftMargin: parent.width * 0.56
      width: parent.width * 0.22
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.best
      color: root.fg
      opacity: parent.header ? 0.6 : 1.0
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Text {
      anchors.right: parent.right
      width: parent.width * 0.22
      horizontalAlignment: Text.AlignRight
      textFormat: Text.PlainText
      text: parent.average
      color: root.fg
      opacity: parent.header ? 0.6 : 1.0
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }

  component TotalPair: Row {
    property string label: ""
    property string value: ""

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: parent.label
      color: root.fg
      opacity: 0.6
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      textFormat: Text.PlainText
      text: parent.value
      color: root.fg
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
    }
  }
}
