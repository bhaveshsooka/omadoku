// Unit tests for the two pure-JavaScript modules.
//
// Sudoku.js and Model.js are `.pragma library` files with no QML in them, which
// is the whole reason the game logic lives there rather than inside Panel.qml -
// it can be run and checked without a shell, a bar, or a display. This loads
// both into a bare context, with the pragma stripped, and exercises them.
//
//   node test/run.js
//
// No dependencies, on purpose: the plugin has none, and a test suite that
// needed a package manager would be the only thing in the repository that did.

"use strict";

const fs = require("fs");
const path = require("path");
const vm = require("vm");

const root = path.join(__dirname, "..");
const ctx = vm.createContext({ console });
for (const file of ["Sudoku.js", "Model.js"]) {
  const source = fs.readFileSync(path.join(root, file), "utf8").replace(".pragma library", "");
  vm.runInContext(source, ctx, { filename: file });
}
const S = ctx;
const M = ctx;

let checks = 0;
let failures = 0;
let group = "";

function describe(name, body) { group = name; body(); }

function eq(actual, expected, message) {
  checks++;
  const a = JSON.stringify(actual);
  const b = JSON.stringify(expected);
  if (a !== b) {
    failures++;
    console.log(`FAIL  ${group} — ${message}\n        got  ${a}\n        want ${b}`);
  }
}

function ok(value, message) { eq(!!value, true, message); }

// Every digit appears once per row, column and box.
function isLegalSolution(grid) {
  if (!grid || grid.length !== 81) return false;
  for (let i = 0; i < 81; i++) if (grid[i] < 1 || grid[i] > 9) return false;
  return S.conflicts(grid).filter(Boolean).length === 0;
}

// ------------------------------------------------------------------ indexing

describe("indexing", () => {
  eq(S.rowOf(0), 0, "cell 0 is in row 0");
  eq(S.rowOf(80), 8, "cell 80 is in row 8");
  eq(S.colOf(9), 0, "cell 9 starts row 1");
  eq(S.boxOf(0), 0, "cell 0 is in box 0");
  eq(S.boxOf(80), 8, "cell 80 is in box 8");
  eq(S.boxOf(30), 4, "cell 30 is in the centre box");

  // 8 in the row, 8 in the column, 4 more in the box that neither covers.
  eq(S.peersOf(0).length, 20, "every cell sees exactly 20 peers");
  ok(S.peersOf(0).indexOf(0) === -1, "a cell is not its own peer");
  ok(S.peersOf(0).indexOf(1) !== -1, "row peers are included");
  ok(S.peersOf(0).indexOf(9) !== -1, "column peers are included");
  ok(S.peersOf(0).indexOf(10) !== -1, "box peers are included");
  ok(S.peersOf(0).indexOf(80) === -1, "unrelated cells are excluded");
});

// ---------------------------------------------------------------- generation

describe("generation", () => {
  ok(isLegalSolution(S.generateSolution(Math.random)), "generateSolution is legal");

  for (const level of ["Easy", "Medium", "Hard", "Expert"]) {
    const game = S.generate(level, Math.random);

    ok(isLegalSolution(game.solution), `${level}: solution is legal`);
    eq(game.difficulty, level, `${level}: reports its own difficulty`);
    ok(S.hasUniqueSolution(game.puzzle), `${level}: puzzle has one solution`);
    eq(S.solve(game.puzzle), game.solution, `${level}: solves to the stated solution`);

    // Uniqueness can block removal, so a board often lands above its target.
    // It can also land exactly one below it: clues are carved in symmetric
    // pairs, and the loop tests `givens > target` before removing two, so a
    // board sitting one clue above target can give up a pair and undershoot.
    // One either way; anything further would mean the carve went wrong.
    ok(game.givens >= S.givensFor(level) - 1,
       `${level}: lands no more than one clue below target`);
    eq(S.filledCount(game.puzzle), game.givens, `${level}: givens matches the grid`);

    // A clue that disagreed with its own solution would be unsolvable.
    let agrees = true;
    for (let i = 0; i < 81; i++) {
      if (game.puzzle[i] !== 0 && game.puzzle[i] !== game.solution[i]) agrees = false;
    }
    ok(agrees, `${level}: every clue agrees with the solution`);
  }

  eq(S.givensFor("Easy"), 45, "Easy clue target");
  eq(S.givensFor("Expert"), 26, "Expert clue target");
  eq(S.givensFor("nonsense"), 36, "an unknown level falls back to Medium's target");
});

// -------------------------------------------------------------------- solving

describe("solving", () => {
  const solution = S.generateSolution(Math.random);

  eq(S.countSolutions(S.emptyGrid(), 2), 2, "an empty grid stops counting at the cap");
  eq(S.countSolutions(solution, 2), 1, "a finished grid has exactly one solution");

  // Emptying a single cell leaves exactly one way to fill it back in.
  const oneGap = solution.slice();
  oneGap[40] = 0;
  ok(S.hasUniqueSolution(oneGap), "one empty cell stays unique");

  // The same digit twice in a row cannot be completed at all.
  const broken = S.emptyGrid();
  broken[0] = 5;
  broken[1] = 5;
  eq(S.solve(broken), null, "a contradictory grid has no solution");
  eq(S.countSolutions(broken, 2), 0, "and counts zero of them");
});

// ------------------------------------------------------------------ conflicts

describe("conflicts", () => {
  eq(S.conflicts(S.emptyGrid()).filter(Boolean).length, 0, "an empty grid is conflict free");

  const row = S.emptyGrid();
  row[0] = 7; row[8] = 7;
  const rowMap = S.conflicts(row);
  ok(rowMap[0] && rowMap[8], "a repeated digit in a row is flagged at both cells");
  eq(rowMap.filter(Boolean).length, 2, "and nowhere else");

  const col = S.emptyGrid();
  col[0] = 3; col[72] = 3;
  eq(S.conflicts(col).filter(Boolean).length, 2, "a repeated digit in a column is flagged");

  const box = S.emptyGrid();
  box[0] = 1; box[10] = 1;
  eq(S.conflicts(box).filter(Boolean).length, 2, "a repeated digit in a box is flagged");
});

// --------------------------------------------------------------- grid helpers

describe("grid helpers", () => {
  eq(S.emptyGrid().length, 81, "a grid is 81 cells");
  eq(S.filledCount(S.emptyGrid()), 0, "an empty grid counts zero");
  ok(!S.isComplete(S.emptyGrid()), "an empty grid is not complete");

  const solution = S.generateSolution(Math.random);
  ok(S.isComplete(solution), "a full grid is complete");
  eq(S.filledCount(solution), 81, "and counts 81");
  eq(S.digitCounts(solution), [9, 9, 9, 9, 9, 9, 9, 9, 9], "each digit appears nine times");

  const one = S.emptyGrid();
  one[0] = 4;
  eq(S.digitCounts(one)[3], 1, "digitCounts is indexed from zero");
});

// ---------------------------------------------------------------- pencil marks

describe("pencil marks", () => {
  eq(S.emptyNotes().length, 81, "one mask per cell");
  eq(S.emptyNotes()[0], 0, "and every mask starts empty");

  let mask = 0;
  ok(!S.hasNote(mask, 5), "an empty mask holds nothing");
  mask = S.toggleNote(mask, 5);
  ok(S.hasNote(mask, 5), "toggling sets the mark");
  ok(!S.hasNote(mask, 4), "and leaves its neighbours alone");
  mask = S.toggleNote(mask, 5);
  ok(!S.hasNote(mask, 5), "toggling again clears it");

  // Placing a digit should erase that pencil mark from every cell it can see.
  const notes = S.emptyNotes();
  for (const i of [1, 9, 10, 80]) notes[i] = S.toggleNote(0, 6);
  const cleaned = S.clearPeerNotes(notes, 0, 6);
  ok(!S.hasNote(cleaned[1], 6), "a row peer loses the mark");
  ok(!S.hasNote(cleaned[9], 6), "a column peer loses the mark");
  ok(!S.hasNote(cleaned[10], 6), "a box peer loses the mark");
  ok(S.hasNote(cleaned[80], 6), "a cell it cannot see keeps the mark");

  // Candidates are the digits no peer has taken.
  const grid = S.emptyGrid();
  for (let d = 1; d <= 8; d++) grid[d] = d;
  const candidates = S.candidatesFor(grid, 0);
  ok(S.hasNote(candidates, 9), "the only legal digit is a candidate");
  ok(!S.hasNote(candidates, 1), "a digit already in the row is not");

  const filled = S.fillAllNotes(grid);
  eq(filled[1], 0, "a cell that already holds a digit gets no marks");
  eq(filled[0], candidates, "an empty cell gets exactly its candidates");
});

// ------------------------------------------------------------------ formatting

describe("formatting", () => {
  eq(M.formatTime(0), "0:00", "zero");
  eq(M.formatTime(9000), "0:09", "seconds are padded");
  eq(M.formatTime(61000), "1:01", "minutes");
  eq(M.formatTime(3600000), "1:00:00", "an hour earns the hour slot");
  eq(M.formatTime(-5), "0:00", "negative time reads as zero");
  eq(M.formatTime("nonsense"), "0:00", "and so does nonsense");

  eq(M.formatTotalTime(0), "0s", "no history");
  eq(M.formatTotalTime(90000), "1m", "minutes");
  eq(M.formatTotalTime(3660000), "1h 1m", "hours and minutes");

  eq(M.formatOrDash(0), "—", "an unset best time is a dash, not 0:00");
  eq(M.formatOrDash(61000), "1:01", "a real one is formatted");
});

// ---------------------------------------------------------------------- labels

describe("labels", () => {
  ok(M.isDifficulty("Easy") && !M.isDifficulty("easy"), "difficulty names are exact");
  eq(M.normalizeDifficulty("Hard", "Easy"), "Hard", "a known name passes through");
  eq(M.normalizeDifficulty("bogus", "Easy"), "Easy", "an unknown one takes the fallback");
  eq(M.normalizeDifficulty("bogus", "also bogus"), "Medium", "and a bogus fallback lands on Medium");

  eq(M.statusText({ state: "idle" }), "CHOOSE A DIFFICULTY", "idle");
  eq(M.statusText({ state: "paused" }), "PAUSED", "paused");
  eq(M.statusText({ state: "solved", hintsUsed: 0 }), "SOLVED", "a clean solve says so");
  eq(M.statusText({ state: "solved", hintsUsed: 1 }), "SOLVED WITH 1 HINT", "one hint is singular");
  eq(M.statusText({ state: "solved", hintsUsed: 3 }), "SOLVED WITH 3 HINTS", "more are plural");
  eq(M.statusText({ state: "playing", filled: 80 }), "1 TO GO", "the count remaining");
  eq(M.statusText({ state: "playing", filled: 81 }), "CHECK YOUR WORK",
     "a full but unsolved board asks you to look again");
  eq(M.statusText({ state: "playing", filled: 40, notesMode: true }), "PENCIL MARKS",
     "notes mode takes over the line");

  eq(M.tooltip({ started: false }), "Omadoku — click to start", "idle tooltip");
  eq(M.tooltip({ started: true, state: "playing", difficulty: "Hard", elapsedMs: 61000, filled: 30 }),
     "Hard · 30/81 · 1:01", "playing tooltip");
  eq(M.tooltip({ started: true, state: "solved", difficulty: "Easy", elapsedMs: 1000, hintsUsed: 0 }),
     "Solved easy in 0:01", "a clean solve mentions no hints");
  eq(M.tooltip({ started: true, state: "solved", difficulty: "Easy", elapsedMs: 1000, hintsUsed: 1 }),
     "Solved easy in 0:01 · 1 hint", "one hint is singular here too");

  eq(M.glyph("solved"), M.glyph("solved"), "glyphs are stable");
  ok(M.glyph("paused") !== M.glyph("solved"), "and distinguish their states");
});

// ------------------------------------------------------------------- save file

describe("save file", () => {
  const game = S.generate("Medium", Math.random);
  const state = {
    difficulty: "Medium",
    puzzle: game.puzzle,
    solution: game.solution,
    cells: game.puzzle.slice(),
    notes: S.emptyNotes(),
    elapsedMs: 1234,
    hintsUsed: 2,
    selected: 40,
    notesMode: true,
    solved: false
  };

  const restored = M.parse(M.serialize(state));
  ok(restored, "a saved game comes back");
  eq(restored.difficulty, "Medium", "difficulty survives");
  eq(restored.puzzle, game.puzzle, "the clues survive");
  eq(restored.solution, game.solution, "the solution survives");
  eq(restored.elapsedMs, 1234, "the clock survives");
  eq(restored.hintsUsed, 2, "the hint count survives");
  eq(restored.selected, 40, "the cursor survives");
  eq(restored.notesMode, true, "notes mode survives");

  eq(M.parse(""), null, "nothing on disk is not a game");
  eq(M.parse("{"), null, "malformed JSON is refused rather than thrown");
  eq(M.parse("null"), null, "so is a valid but empty document");

  const wrongVersion = JSON.parse(M.serialize(state));
  wrongVersion.version = 99;
  eq(M.parse(JSON.stringify(wrongVersion)), null, "a future version is refused, not guessed at");

  const shortGrid = JSON.parse(M.serialize(state));
  shortGrid.cells = shortGrid.cells.slice(0, 80);
  eq(M.parse(JSON.stringify(shortGrid)), null, "a grid of the wrong length is refused");

  const badDigit = JSON.parse(M.serialize(state));
  badDigit.cells[0] = 42;
  eq(M.parse(JSON.stringify(badDigit)), null, "an out-of-range digit is refused");

  // The check that matters most: two halves of different games.
  const mismatched = JSON.parse(M.serialize(state));
  for (let i = 0; i < 81; i++) {
    if (mismatched.puzzle[i] !== 0) {
      mismatched.solution[i] = (mismatched.puzzle[i] % 9) + 1;
      break;
    }
  }
  eq(M.parse(JSON.stringify(mismatched)), null,
     "a clue that disagrees with its own solution is refused");

  const badNotes = JSON.parse(M.serialize(state));
  badNotes.notes[0] = 4096;
  eq(M.parse(JSON.stringify(badNotes)), null, "a pencil mask outside nine bits is refused");
});

// ----------------------------------------------------------------------- stats

describe("stats", () => {
  const empty = M.emptyStats();
  eq(empty.started, 0, "a fresh ledger has no games");
  eq(empty.streak, 0, "and no streak");
  eq(Object.keys(empty.byDifficulty).sort(), ["Easy", "Expert", "Hard", "Medium"],
     "with a bucket per difficulty");

  eq(M.parseStats(""), M.emptyStats(), "no file is an empty ledger");
  eq(M.parseStats("{"), M.emptyStats(), "malformed stats reset rather than fail the plugin");
  eq(M.parseStats('{"version":99}'), M.emptyStats(), "so does a version we cannot read");
  eq(M.parseStats(M.serializeStats(empty)), empty, "an empty ledger round trips");

  // A NaN reaching the panel would poison every binding that touches it.
  const poisoned = M.parseStats('{"version":1,"started":"lots","solved":null,"streak":-4}');
  eq(poisoned.started, 0, "a non-numeric count reads as zero");
  eq(poisoned.streak, 0, "and so does a negative one");

  let s = M.emptyStats();
  s = M.recordStart(s, "Hard", false);
  eq(s.started, 1, "starting counts a game");
  eq(s.byDifficulty.Hard.started, 1, "against its difficulty");

  s = M.recordSolve(s, "Hard", 60000, 0);
  eq(s.solved, 1, "solving counts a win");
  eq(s.cleanSolved, 1, "with no hints it is a clean solve");
  eq(s.streak, 1, "and starts a streak");
  eq(s.bestStreak, 1, "which is also the best so far");
  eq(s.byDifficulty.Hard.bestMs, 60000, "the time becomes the best");
  eq(M.winRate(s), 100, "one from one is 100%");

  s = M.recordStart(s, "Hard", false);
  s = M.recordSolve(s, "Hard", 30000, 2);
  eq(s.streak, 2, "a second win extends the streak");
  eq(s.cleanSolved, 1, "a hinted solve is not clean");
  eq(s.hints, 2, "hints accumulate");
  eq(s.byDifficulty.Hard.bestMs, 30000, "a faster time replaces the best");

  s = M.recordStart(s, "Hard", false);
  s = M.recordSolve(s, "Hard", 90000, 0);
  eq(s.byDifficulty.Hard.bestMs, 30000, "a slower one does not");
  eq(M.averageMs(s.byDifficulty.Hard), 60000, "the average is over solves");

  const abandoned = M.recordAbandon(s);
  eq(abandoned.streak, 0, "abandoning breaks the streak");
  eq(abandoned.bestStreak, 3, "but not the record of it");
  eq(abandoned.solved, s.solved, "and costs no solves");

  const walkedAway = M.recordStart(s, "Easy", true);
  eq(walkedAway.streak, 0, "dealing over an unfinished board breaks it too");

  // A board restored from before stats existed was never counted as started.
  const orphan = M.recordSolve(M.emptyStats(), "Easy", 1000, 0);
  eq(orphan.started, 1, "an uncounted solve back-fills its start");
  ok(M.winRate(orphan) <= 100, "so the win rate can never exceed 100%");

  eq(M.winRate(M.emptyStats()), 0, "no games is a zero win rate, not a division by zero");
  eq(M.averageMs(M.emptyStats().byDifficulty.Easy), 0, "and no average");

  const rows = M.statsRows(s);
  eq(rows.length, 4, "one row per difficulty");
  eq(rows[0].level, "Easy", "in a fixed order");
  eq(rows.find(r => r.level === "Easy").best, "—", "an unplayed level shows a dash");
  eq(rows.find(r => r.level === "Hard").best, "0:30", "a played one shows its best");
});

console.log(
  failures
    ? `\n${failures} of ${checks} checks FAILED`
    : `\nall ${checks} checks passed`
);
process.exit(failures ? 1 : 0);
