# How Omadoku works

Design notes for anyone reading the source. For installing and playing, see
[README.md](README.md).

| File            | Role                                                          |
| --------------- | ------------------------------------------------------------- |
| `manifest.json` | Plugin declaration and the settings schema                    |
| `BarWidget.qml` | The bar icon, the IPC target, and the panel loader            |
| `Panel.qml`     | The board, game state, keyboard handling, and the save file   |
| `Sudoku.js`     | Puzzle generation, solving, and validation — pure functions   |
| `Icon.qml`      | The bar wordmark, drawn rather than set in a font             |
| `Model.js`      | Glyphs, labels, time formatting, save and stats serialisation |

**Generation.** A solved grid is produced by permuting the canonical sudoku
pattern — relabelling digits, shuffling rows within bands, bands within the
grid, the same for columns, and optionally transposing. Those are exactly the
transformations that preserve validity, so the result is always legal and
costs no search. Clues are then carved out in 180°-symmetric pairs, keeping
only removals that leave the solution unique.

This all runs on the shell's UI thread, which every widget in your bar shares,
so it is bounded twice over: the solution counter stops at two solutions rather
than enumerating, and the search carries a node budget. Exhausting the budget
returns the pessimistic "not unique" answer, so the generator keeps the clue it
was about to remove — a blown budget costs an easier puzzle, never a broken one.
Measured worst case is about 1ms per puzzle.

**The daily puzzle** is generated, not fetched. `generate()` already took an
injectable `rng`, so the whole feature is a seeded generator — mulberry32 over
an FNV-1a hash of `"YYYY-MM-DD|Difficulty"` — plus a day key threaded through
the save and the stats. Every machine derives the same grid from the same date
with no server, no network call, and nothing reported back, which also keeps the
plugin's security profile exactly where it was.

This makes `generateSolution()` and `generate()` a compatibility surface. They
consume random numbers in a fixed order, and changing that order silently
changes every past daily. The solver's node budget is a fixed count rather than
a deadline, so exhausting it is deterministic too — a daily cannot come out
differently on a slower machine.

Day keys are local dates: the board should turn over at the player's midnight,
not at Greenwich's, and the grid for a given date is identical everywhere
regardless. Streak arithmetic is done in UTC on the date-only key, so a
daylight-saving jump cannot make "yesterday" land on the same day or skip one.

Neither the save nor the stats version was bumped for this. Both readers already
default every absent field, so an old file migrates itself; a bump would have
thrown away every in-progress game and every lifetime record on upgrade to buy
nothing. The daily ledger is kept separate from `streak` because it counts
consecutive *days* rather than consecutive wins, and it is banked once per day —
re-solving the same board after an undo, or on a second machine, cannot move it.
Display asks `dailyStreakNow()` rather than reading the stored value, because a
run that lapsed last week is over even though nothing has written that down yet.

**On difficulty.** The four levels set a target clue count (45 / 36 / 30 / 26),
not a required solving technique. Clue count correlates with difficulty but does
not determine it, so "Expert" is reliably sparse rather than reliably demanding
advanced technique. Uniqueness can also block removal, so a board occasionally
lands above its target.

**Persistence.** The game is written to
`~/.local/state/omadoku/game.json`, the lifetime record to `stats.json` beside it — under `XDG_STATE_HOME` because it is real
user state, not regenerable cache. Writes are debounced and checkpointed every
15 seconds, so a crash costs seconds rather than the session. The save is
versioned and fully validated on load: wrong version, wrong shape, an
out-of-range digit, or clues that disagree with their own solution all read as
"no saved game" rather than restoring a board that cannot be finished.

A restored game comes back paused, and the clock starts again when you next open
the board — the shell restarting should not cost you minutes you never played.

Resetting statistics writes `emptyStats()` over `stats.json` and stops there.
The two files have separate lifetimes on purpose, and a reset that also swept
away the board in `game.json` would be a second, unrelated destruction hiding
behind one button. It routes through the same `pendingAction` confirmation the
board's destructive actions use, so there is one prompt mechanism rather than
two — which is why the confirmation's text moved out of delegate ternaries and
into `confirmPrompt()` / `confirmDetail()` / `confirmVerb()` once there were
three cases instead of two.

**The bar wordmark** is drawn in QML because no icon font carries it, and
because the obvious alternative does not survive a 26px bar: a 3×3 grid of nine
characters gives each glyph about five pixels and reads as noise. Seven cells in
one row gives each letter the icon's full height. Divisions are marked by
brightness rather than thickness — a 2px rule around an 18px box eats the cell
it is meant to divide — and the letters use hinted rendering, since antialiased
stems turn to fog at this size. Vertical bars are 28px wide and cannot fit a
58px wordmark, so they fall back to the compact grid glyph automatically;
`barStyle: "Icon"` forces that everywhere.

A win fills the wordmark's cells and brightens its edge rather than recolouring
it. `WidgetButton` defaults its active colour to `bar.urgent`, which made a
solved board wear the bar's error colour; the accent is the obvious replacement
but is not reliable, since a theme may set `accent` equal to `foreground` —
Kanagawa does — leaving the win invisible. Fill reads in every theme. The accent
is still used for the vertical-bar glyph, which has no wordmark to fill.

**The win parade** bursts all 81 digits into confetti, empties the grid, and
lands a message on it. That is 324 pieces, and the naive shape — each piece
animating its own position, spin and fade — is roughly sixteen hundred running
animations inside the process that also draws the bar, the notifications and
every other widget. So the whole effect runs on a single `NumberAnimation`
driving one `celebrateProgress` property from 0 to 1, and each piece derives its
position and opacity from that value plus a trajectory seeded once when the
parade starts. One animation, no allocation while it runs, and nothing left
alive afterwards — the pieces are dropped when it ends.

Seeding matters: a piece that re-rolled its own randomness inside a binding
would be re-evaluated every frame and jitter in place instead of flying.

A solved board disables undo and clear, and swaps Abandon for **Done** —
`finishBoard()`, which shares `clearToIdle()` with `abandon()` but records no
abandonment and breaks no streak. Without it, disabling Abandon on a win left no
route from a finished board back to the attract screen at all.

A solved board disables undo, clear and abandon. Each was a route from a
finished board back to an unfinished one, and every question that followed —
does the parade replay, how many times, what resets it — existed only to service
that. Closing the routes deleted the bookkeeping. What remains is a `restoring`
flag, because a solved game read back from `game.json` arrives already solved
and must not throw a parade on every shell restart.

**The attract loop** deals a throwaway Easy board and fills it in a shuffled
order, so it reads as someone solving rather than a cursor sweeping the grid. It
animates only while the panel is actually open — an unwatched animation inside
the process that draws your whole desktop is pure waste — and its state is kept
entirely separate from the real game's, so the two can never be confused.

**The clock** is wall-clock based rather than tick-counted. A one-second timer
that increments a counter drifts and stalls whenever the shell is busy, which
for a process hosting the whole desktop is often.
