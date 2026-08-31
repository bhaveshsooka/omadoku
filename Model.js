.pragma library

// Presentation helpers for the bar widget and panel: glyph choice, label and
// tooltip text, time formatting. Kept out of the QML so the wording and the
// icon table are in one place, and so they can be unit-tested as plain JS.

// Nerd Font glyphs. The bar renders in the theme's mono family, which Omarchy
// patches with Nerd Font symbols.
var GLYPH_BOARD  = "󰎠"; // md-numeric_9_box — the resting icon
var GLYPH_SOLVED = "󰄬"; // md-check
var GLYPH_PAUSED = "󰏤"; // md-pause
var GLYPH_NOTES  = "󰏫"; // md-pencil
var GLYPH_HINT   = "󰌵"; // md-lightbulb
var GLYPH_UNDO   = "󰕌"; // md-undo
var GLYPH_NEW    = "󰑐"; // md-refresh

function glyph(state) {
  if (state === "solved") return GLYPH_SOLVED;
  if (state === "paused") return GLYPH_PAUSED;
  return GLYPH_BOARD;
}

// "M:SS" until an hour, "H:MM:SS" after. Sudoku sessions are minutes long, so
// the compact form is the common case and the hour slot only appears when earned.
function formatTime(ms) {
  var total = Math.max(0, Math.floor((Number(ms) || 0) / 1000));
  var s = total % 60;
  var m = Math.floor(total / 60) % 60;
  var h = Math.floor(total / 3600);
  var ss = s < 10 ? "0" + s : String(s);
  if (h > 0) {
    var mm = m < 10 ? "0" + m : String(m);
    return h + ":" + mm + ":" + ss;
  }
  return m + ":" + ss;
}

// What the bar button shows. Icon-only unless the timer is wanted and there is
// a game to time; a vertical bar has no room for the label either way.
function barLabel(opts) {
  var g = glyph(opts.state);
  if (!opts.showTimer || opts.vertical || !opts.started) return g;
  return g + " " + formatTime(opts.elapsedMs);
}

function tooltip(opts) {
  if (!opts.started) return "Omadoku — click to start";
  if (opts.state === "solved")
    return "Solved " + opts.difficulty.toLowerCase() + " in " + formatTime(opts.elapsedMs)
         + (opts.hintsUsed > 0 ? " · " + opts.hintsUsed + " hint" + (opts.hintsUsed === 1 ? "" : "s") : "");
  if (opts.state === "paused")
    return "Omadoku paused · " + formatTime(opts.elapsedMs);
  return opts.difficulty + " · " + opts.filled + "/81 · " + formatTime(opts.elapsedMs);
}

// Status line under the title in the panel header.
function statusText(opts) {
  if (opts.state === "solved") {
    return opts.hintsUsed > 0
      ? "SOLVED WITH " + opts.hintsUsed + " HINT" + (opts.hintsUsed === 1 ? "" : "S")
      : "SOLVED";
  }
  if (opts.state === "paused") return "PAUSED";
  if (opts.notesMode) return "PENCIL MARKS";
  var left = 81 - opts.filled;
  if (left === 0) return "CHECK YOUR WORK";
  return left + " TO GO";
}

function isDifficulty(name) {
  return name === "Easy" || name === "Medium" || name === "Hard" || name === "Expert";
}

function normalizeDifficulty(name, fallback) {
  return isDifficulty(name) ? name : (isDifficulty(fallback) ? fallback : "Medium");
}

// ---------------------------------------------------------------- save file
//
// One shape, versioned, so a later format change can migrate rather than
// silently resurrect a half-understood board. Anything that fails to parse or
// fails the shape check is treated as "no saved game" — a corrupt save must
// never take the shell down with it.

var SAVE_VERSION = 1;

function _isGrid(value) {
  if (!value || value.length !== 81) return false;
  for (var i = 0; i < 81; i++) {
    var v = value[i];
    if (typeof v !== "number" || v < 0 || v > 9 || (v | 0) !== v) return false;
  }
  return true;
}

function _isNotes(value) {
  if (!value || value.length !== 81) return false;
  for (var i = 0; i < 81; i++) {
    var v = value[i];
    if (typeof v !== "number" || v < 0 || v > 511 || (v | 0) !== v) return false;
  }
  return true;
}

function serialize(state) {
  return JSON.stringify({
    version: SAVE_VERSION,
    difficulty: state.difficulty,
    puzzle: state.puzzle,
    solution: state.solution,
    cells: state.cells,
    notes: state.notes,
    elapsedMs: Math.max(0, Math.round(state.elapsedMs)),
    hintsUsed: Math.max(0, state.hintsUsed | 0),
    selected: Math.min(80, Math.max(0, state.selected | 0)),
    notesMode: state.notesMode === true,
    solved: state.solved === true
  }, null, 2) + "\n";
}

// Returns a validated state object, or null when there is nothing usable.
function parse(text) {
  if (!text) return null;
  var raw;
  try {
    raw = JSON.parse(text);
  } catch (e) {
    return null;
  }
  if (!raw || raw.version !== SAVE_VERSION) return null;
  if (!_isGrid(raw.puzzle) || !_isGrid(raw.solution) || !_isGrid(raw.cells)) return null;
  if (!_isNotes(raw.notes)) return null;

  // A clue that disagrees with its own solution means the two halves came from
  // different games; refuse rather than present an unsolvable board.
  for (var i = 0; i < 81; i++) {
    if (raw.puzzle[i] !== 0 && raw.puzzle[i] !== raw.solution[i]) return null;
    if (raw.puzzle[i] !== 0 && raw.cells[i] !== raw.puzzle[i]) return null;
  }

  return {
    difficulty: normalizeDifficulty(raw.difficulty, "Medium"),
    puzzle: raw.puzzle,
    solution: raw.solution,
    cells: raw.cells,
    notes: raw.notes,
    elapsedMs: Math.max(0, Number(raw.elapsedMs) || 0),
    hintsUsed: Math.max(0, raw.hintsUsed | 0),
    selected: Math.min(80, Math.max(0, raw.selected | 0)),
    notesMode: raw.notesMode === true,
    solved: raw.solved === true
  };
}
