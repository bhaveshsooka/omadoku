.pragma library

// Pure sudoku logic: no QML, no I/O, no side effects on anything the caller
// did not hand in. Everything here is a plain function over a flat 81-cell
// array of 0..9, where 0 means empty. Keeping it a `.pragma library` means the
// bar widget and the panel share one parsed copy rather than one per instance.

// ---------------------------------------------------------------- geometry

var ROW = [];
var COL = [];
var BOX = [];
var PEERS = [];

(function buildGeometry() {
  var i, b;
  for (i = 0; i < 81; i++) {
    ROW[i] = (i / 9) | 0;
    COL[i] = i % 9;
    BOX[i] = (((i / 9) | 0) / 3 | 0) * 3 + ((i % 9) / 3 | 0);
  }
  for (i = 0; i < 81; i++) {
    var list = [];
    for (b = 0; b < 81; b++) {
      if (b === i) continue;
      if (ROW[b] === ROW[i] || COL[b] === COL[i] || BOX[b] === BOX[i]) list.push(b);
    }
    PEERS[i] = list;
  }
})();

function rowOf(i) { return ROW[i]; }
function colOf(i) { return COL[i]; }
function boxOf(i) { return BOX[i]; }
function peersOf(i) { return PEERS[i]; }

// ------------------------------------------------------------------ solver
//
// Bitmask + minimum-remaining-values backtracking. `_count` stops as soon as
// it has found `cap` solutions, so the uniqueness test the generator leans on
// ("is there exactly one?") costs a cap of 2 rather than a full enumeration.

function _popcount(mask) {
  var n = 0;
  while (mask) { mask &= mask - 1; n++; }
  return n;
}

function _masksFor(grid) {
  var rm = [0, 0, 0, 0, 0, 0, 0, 0, 0];
  var cm = [0, 0, 0, 0, 0, 0, 0, 0, 0];
  var bm = [0, 0, 0, 0, 0, 0, 0, 0, 0];
  for (var i = 0; i < 81; i++) {
    var v = grid[i];
    if (!v) continue;
    var bit = 1 << (v - 1);
    // A grid that already contradicts itself has no solutions at all; report
    // that to the caller rather than silently double-counting a digit.
    if ((rm[ROW[i]] & bit) || (cm[COL[i]] & bit) || (bm[BOX[i]] & bit)) return null;
    rm[ROW[i]] |= bit; cm[COL[i]] |= bit; bm[BOX[i]] |= bit;
  }
  return { rm: rm, cm: cm, bm: bm };
}

// `budget` bounds the search so a pathological grid cannot freeze the shell
// process every widget in the bar shares. Running out returns `cap`, i.e. the
// pessimistic "more than one" answer — the generator then keeps the clue it
// was about to remove, so exhaustion costs an easier puzzle, never a broken one.
function _count(g, rm, cm, bm, cap, budget) {
  if (--budget.n < 0) return cap;

  var best = -1, bestMask = 0, bestCount = 10;
  for (var i = 0; i < 81; i++) {
    if (g[i] !== 0) continue;
    var free = ~(rm[ROW[i]] | cm[COL[i]] | bm[BOX[i]]) & 0x1FF;
    var c = _popcount(free);
    if (c === 0) return 0;
    if (c < bestCount) {
      bestCount = c; best = i; bestMask = free;
      if (c === 1) break;
    }
  }
  if (best === -1) return 1;

  var total = 0;
  for (var d = 0; d < 9; d++) {
    var bit = 1 << d;
    if (!(bestMask & bit)) continue;
    g[best] = d + 1;
    rm[ROW[best]] |= bit; cm[COL[best]] |= bit; bm[BOX[best]] |= bit;
    total += _count(g, rm, cm, bm, cap - total, budget);
    g[best] = 0;
    rm[ROW[best]] &= ~bit; cm[COL[best]] &= ~bit; bm[BOX[best]] &= ~bit;
    if (total >= cap) return total;
  }
  return total;
}

// Number of solutions, counted no further than `cap` (default 2).
function countSolutions(grid, cap, budget) {
  var m = _masksFor(grid);
  if (!m) return 0;
  return _count(grid.slice(), m.rm, m.cm, m.bm, cap === undefined ? 2 : cap,
                { n: budget === undefined ? 400000 : budget });
}

function hasUniqueSolution(grid) {
  return countSolutions(grid, 2) === 1;
}

function _firstSolution(g, rm, cm, bm, budget) {
  if (--budget.n < 0) return null;

  var best = -1, bestMask = 0, bestCount = 10;
  for (var i = 0; i < 81; i++) {
    if (g[i] !== 0) continue;
    var free = ~(rm[ROW[i]] | cm[COL[i]] | bm[BOX[i]]) & 0x1FF;
    var c = _popcount(free);
    if (c === 0) return null;
    if (c < bestCount) {
      bestCount = c; best = i; bestMask = free;
      if (c === 1) break;
    }
  }
  if (best === -1) return g.slice();

  for (var d = 0; d < 9; d++) {
    var bit = 1 << d;
    if (!(bestMask & bit)) continue;
    g[best] = d + 1;
    rm[ROW[best]] |= bit; cm[COL[best]] |= bit; bm[BOX[best]] |= bit;
    var found = _firstSolution(g, rm, cm, bm, budget);
    g[best] = 0;
    rm[ROW[best]] &= ~bit; cm[COL[best]] &= ~bit; bm[BOX[best]] &= ~bit;
    if (found) return found;
  }
  return null;
}

// Solved grid, or null when the puzzle contradicts itself / the budget runs out.
function solve(grid) {
  var m = _masksFor(grid);
  if (!m) return null;
  return _firstSolution(grid.slice(), m.rm, m.cm, m.bm, { n: 400000 });
}

// ---------------------------------------------------------------- seeding
//
// A seeded generator, so a board can be reproduced from nothing but a seed.
// That is the whole trick behind the daily puzzle: every machine derives the
// same grid from the same date, with no server to hand one out and no network
// call to make. `Math.random` is fine for a board you deal yourself, but it can
// never be part of a daily.
//
// Consequence worth stating plainly: `generateSolution` and `generate` are now
// a compatibility surface. Change the order in which either of them consumes
// random numbers and every past daily changes with it.

// mulberry32 - small, fast, and good enough for shuffling a sudoku.
function rngFrom(seed) {
  var a = (seed >>> 0) || 1;
  return function () {
    a = (a + 0x6D2B79F5) >>> 0;
    var t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

// FNV-1a, turning "2026-09-03|Hard" into a seed for the above.
function seedFrom(text) {
  var s = String(text);
  var h = 0x811C9DC5;
  for (var i = 0; i < s.length; i++) {
    h = Math.imul(h ^ s.charCodeAt(i), 0x01000193) >>> 0;
  }
  return h >>> 0;
}

// Each difficulty gets its own daily board, so everyone playing at a given
// level shares a grid rather than only the people who all chose Medium.
function dailySeed(dayKey, difficulty) {
  return seedFrom(String(dayKey) + "|" + String(difficulty));
}

// -------------------------------------------------------------- generation

function _shuffle(list, rng) {
  for (var i = list.length - 1; i > 0; i--) {
    var j = (rng() * (i + 1)) | 0;
    var t = list[i]; list[i] = list[j]; list[j] = t;
  }
  return list;
}

// A solved grid, built by relabelling and permuting the canonical pattern
// rather than by searching. Those transformations are exactly the ones that
// preserve sudoku validity, so the result is always legal and always instant —
// which matters because this runs inside the shell's UI thread.
function generateSolution(rng) {
  var base = new Array(81);
  var r, c;
  for (r = 0; r < 9; r++)
    for (c = 0; c < 9; c++)
      base[r * 9 + c] = (3 * (r % 3) + ((r / 3) | 0) + c) % 9 + 1;

  var digits = _shuffle([1, 2, 3, 4, 5, 6, 7, 8, 9], rng);

  var rows = [], cols = [], band, i;
  var bands = _shuffle([0, 1, 2], rng);
  for (i = 0; i < 3; i++) {
    band = _shuffle([0, 1, 2], rng);
    for (var j = 0; j < 3; j++) rows.push(bands[i] * 3 + band[j]);
  }
  var stacks = _shuffle([0, 1, 2], rng);
  for (i = 0; i < 3; i++) {
    band = _shuffle([0, 1, 2], rng);
    for (var k = 0; k < 3; k++) cols.push(stacks[i] * 3 + band[k]);
  }

  var transpose = rng() < 0.5;
  var out = new Array(81);
  for (r = 0; r < 9; r++) {
    for (c = 0; c < 9; c++) {
      var v = digits[base[rows[r] * 9 + cols[c]] - 1];
      if (transpose) out[c * 9 + r] = v; else out[r * 9 + c] = v;
    }
  }
  return out;
}

// Clue counts per difficulty. This is an approximation: clue count correlates
// with difficulty but does not determine it, so an "Expert" grid is reliably
// sparse rather than reliably requiring advanced technique.
var DIFFICULTIES = ["Easy", "Medium", "Hard", "Expert"];

function givensFor(difficulty) {
  switch (difficulty) {
    case "Easy":   return 45;
    case "Hard":   return 30;
    case "Expert": return 26;
    default:       return 36;
  }
}

// Carve clues out of a solved grid in 180-degree-symmetric pairs, keeping only
// removals that leave the solution unique. Returns the actual clue count,
// which can land above the target when uniqueness blocks further removal.
function generate(difficulty, rng) {
  var random = rng || Math.random;
  // Everything below this line consumes `random` in a fixed order. See the
  // seeding note above before reordering any of it.
  var solution = generateSolution(random);
  var target = givensFor(difficulty);
  var puzzle = solution.slice();
  var givens = 81;

  var order = [];
  for (var i = 0; i <= 40; i++) order.push(i);
  _shuffle(order, random);

  for (var n = 0; n < order.length && givens > target; n++) {
    var a = order[n];
    var b = 80 - a;
    if (puzzle[a] === 0) continue;

    var keptA = puzzle[a];
    var keptB = puzzle[b];
    puzzle[a] = 0;
    var removed = 1;
    if (b !== a && puzzle[b] !== 0) { puzzle[b] = 0; removed = 2; }

    if (hasUniqueSolution(puzzle)) {
      givens -= removed;
    } else {
      puzzle[a] = keptA;
      if (removed === 2) puzzle[b] = keptB;
    }
  }

  return { puzzle: puzzle, solution: solution, givens: givens, difficulty: difficulty };
}

// ------------------------------------------------------------------- state

function emptyGrid() {
  var g = new Array(81);
  for (var i = 0; i < 81; i++) g[i] = 0;
  return g;
}

// Indices holding a digit that repeats somewhere in their row, column, or box.
function conflicts(grid) {
  var bad = new Array(81);
  var i;
  for (i = 0; i < 81; i++) bad[i] = false;
  for (i = 0; i < 81; i++) {
    var v = grid[i];
    if (!v) continue;
    var p = PEERS[i];
    for (var n = 0; n < p.length; n++) {
      if (grid[p[n]] === v) { bad[i] = true; break; }
    }
  }
  return bad;
}

function isComplete(grid) {
  for (var i = 0; i < 81; i++) if (!grid[i]) return false;
  var bad = conflicts(grid);
  for (i = 0; i < 81; i++) if (bad[i]) return false;
  return true;
}

function filledCount(grid) {
  var n = 0;
  for (var i = 0; i < 81; i++) if (grid[i]) n++;
  return n;
}

// Digits that already appear nine times, so the pad can grey them out.
function digitCounts(grid) {
  var counts = [0, 0, 0, 0, 0, 0, 0, 0, 0];
  for (var i = 0; i < 81; i++) if (grid[i]) counts[grid[i] - 1]++;
  return counts;
}

// ------------------------------------------------------------- pencil marks

function hasNote(mask, digit) { return (mask & (1 << (digit - 1))) !== 0; }
function toggleNote(mask, digit) { return mask ^ (1 << (digit - 1)); }

function emptyNotes() {
  var n = new Array(81);
  for (var i = 0; i < 81; i++) n[i] = 0;
  return n;
}

// Placing a digit invalidates that pencil mark everywhere it can still see.
// Returns a fresh array; callers reassign so QML bindings notice the change.
function clearPeerNotes(notes, index, digit) {
  var next = notes.slice();
  var bit = 1 << (digit - 1);
  var p = PEERS[index];
  for (var n = 0; n < p.length; n++) next[p[n]] &= ~bit;
  next[index] = 0;
  return next;
}

// A cell's remaining legal digits, for the auto-fill-notes convenience.
function candidatesFor(grid, index) {
  if (grid[index]) return 0;
  var used = 0;
  var p = PEERS[index];
  for (var n = 0; n < p.length; n++) if (grid[p[n]]) used |= 1 << (grid[p[n]] - 1);
  return ~used & 0x1FF;
}

function fillAllNotes(grid) {
  var notes = new Array(81);
  for (var i = 0; i < 81; i++) notes[i] = candidatesFor(grid, i);
  return notes;
}
