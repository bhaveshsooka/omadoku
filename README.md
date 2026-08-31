# Omadoku

Sudoku in the Omarchy bar. Click the icon, get a board; the clock keeps running
while the popup is closed, and the game survives a shell restart.

An [Omarchy](https://omarchy.org/) shell plugin (`bar-widget`), running inside
the long-lived `omarchy-shell` Quickshell process.

```
[ menu | workspaces ]   [ clock ]   [ │O│M│A│D│O│K│U│ 4:12 | audio | power ]
                                       └─ click for the board
```

## Install

Omadoku is a plain plugin directory. Clone or symlink it into the user plugin
path, rescan, and enable:

```bash
ln -s /1-projects/prsn-project-omarchy-plugins/omadoku \
      ~/.config/omarchy/plugins/io.github.bhaveshsooka.omadoku

omarchy-shell shell rescanPlugins
omarchy plugin enable io.github.bhaveshsooka.omadoku
omarchy bar move io.github.bhaveshsooka.omadoku --section right
```

To remove it: `omarchy plugin remove io.github.bhaveshsooka.omadoku --yes`, then
`rm -rf ~/.local/state/omadoku` for the save and stats.

### Working on it

Omarchy hot-reloads plugin code when a file under
`~/.config/omarchy/plugins/` changes — but **that watcher does not follow the
symlink**. Editing the repo copy changes nothing the shell can see, and
`omarchy-shell shell rescanPlugins` does not pick the edits up either: it
rebuilds the plugin from the *old* source, which discards whatever game was in
progress without loading your changes. After editing, run:

```bash
omarchy restart shell
```

If you would rather have working hot-reload, copy the plugin in instead of
symlinking it and edit it in place under `~/.config/omarchy/plugins/`.

## Playing

## Starting a game

With no game in progress the panel is not blank — a demo board solves itself
behind the difficulty buttons, and the widget waits. Picking a difficulty only
*arms* it; **Start** deals the board, and stays disabled until something is
armed. Nothing is ever dealt on your behalf.

The same rule holds mid-game: clicking a difficulty changes what **New** will
deal, it does not deal it. So a stray click on Expert can never cost you the
board you are on.

Opening the panel always returns you to the game in progress — whatever tab you
left showing, and whatever was on screen — and never deals a new one.

## Playing

**Mouse** — left click the bar icon opens the board, right click pauses, middle
click does nothing. Dealing a board is only ever done from the panel, where the
confirmation prompt is visible. In the grid, click a cell to select it and right
click to clear it.

**Keyboard**, once the popup has focus:

| Key | Does |
|---|---|
| `1`–`4` | *With no game:* arm Easy / Medium / Hard / Expert |
| `Enter` | *With no game:* start the armed board |
| `1`–`9` | Place the digit, or pencil it in when notes mode is on |
| `0`, `.`, `Backspace`, `Delete`, `x` | Clear the cell |
| Arrows or `hjkl` | Move the cursor (it wraps at the edges) |
| `Space` or `n` | Toggle pencil marks |
| `a` | Fill every empty cell with all its legal candidates |
| `u` / `r` | Undo / redo |
| `?` | Reveal one cell |
| `p` | Pause the clock |
| `c` | Clear your entries, keep the puzzle |
| `g` | New game at the armed difficulty |
| `s` / `b` | Switch to the Stats / Board tab |
| `Esc` | Back out of a prompt, then the Stats tab, then close |

On a confirmation prompt, `y` or `Enter` confirms and `n` or `Esc` cancels.

Typing the digit that is already in a cell clears it, which is what every other
sudoku does.

Clues are bold; your own entries are lighter, so the two stay distinguishable
in themes where the accent colour equals the foreground. A digit that repeats in
its row, column, or box turns the theme's urgent colour — turn that off in the
settings for a stricter game.

## Stopping, clearing, abandoning

**Pause** stops the clock and drops a curtain over the grid — it hides the board
rather than dimming it, so you cannot keep solving by eye. Pause from the `p`
key, the Pause button, a right click on the bar icon, or IPC. Set
`pauseWhenClosed` to pause automatically whenever the board is off screen.

Three ways to stop a game, in increasing order of loss:

| Action | Keeps | Loses | Undoable |
|---|---|---|---|
| **Clear** (`c`) | the puzzle and the clock | your entries and pencil marks | yes — press `u` |
| **New** (`g`) | nothing of this board | the board; breaks the streak | no |
| **Abandon** | nothing | the board and its time; breaks the streak | no |

Clear is undoable, so it just does it. New and Abandon ask first — but only when
there is something to lose: dealing over an untouched board skips the prompt.
Right-clicking the bar icon with a game in progress opens the panel onto the
question rather than destroying it somewhere you cannot see.

Abandon returns to the idle state — no board, no clock, the bar icon back to
"click to start", and the difficulty selection cleared, so the widget is asking
the question again rather than holding a stale answer.

## Stats

The **Stats** tab (`s`) keeps a lifetime record in
`~/.local/state/omadoku/stats.json`:

- solves, win rate, and current streak across the top
- solves, best time, and average time per difficulty
- games played, solves without hints, best streak, hints used, and total time on
  solved games

A streak is consecutive solves; abandoning a board, or dealing a new one over a
board you had made progress on, resets it to zero. A solve counts once no matter
how you got there — undoing past the finish and re-solving does not count twice.

Stats are derived entirely from two events the game already knows about — a
board dealt, and a board solved with its time and hint count — so there is no
history file to drift out of sync with the save.

## Settings

Per-widget settings live in the widget's entry in `~/.config/omarchy/shell.json`
and are editable through Setup > Plugins.

| Key | Default | Meaning |
|---|---|---|
| `difficulty` | `Medium` | Difficulty for new games |
| `showTimer` | `true` | Show elapsed time beside the bar icon |
| `barStyle` | `Wordmark` | `Wordmark` draws OMADOKU as a row of sudoku cells; `Icon` uses the compact grid glyph |
| `cellSize` | `34` | Board cell size in pixels (22–56) |
| `highlightPeers` | `true` | Shade the selected cell's row, column and box |
| `highlightSameDigit` | `true` | Shade cells holding the same digit |
| `markConflicts` | `true` | Colour repeated digits |
| `autoCleanNotes` | `true` | Placing a digit erases that pencil mark from cells it sees |
| `pauseWhenClosed` | `false` | Stop the clock whenever the board is off screen |

## IPC

The plugin registers its id as an IPC target, so anything — a Hyprland
keybinding, a script — can drive it:

```bash
omarchy-shell io.github.bhaveshsooka.omadoku toggle
omarchy-shell io.github.bhaveshsooka.omadoku newGame Hard
omarchy-shell io.github.bhaveshsooka.omadoku pause
omarchy-shell io.github.bhaveshsooka.omadoku hint
omarchy-shell io.github.bhaveshsooka.omadoku clear
omarchy-shell io.github.bhaveshsooka.omadoku abandon
omarchy-shell io.github.bhaveshsooka.omadoku status
omarchy-shell io.github.bhaveshsooka.omadoku stats
```

`newGame` and `abandon` respect the confirmation: with a game in progress they
return `confirm` and open the panel onto the prompt rather than acting. `clear`
is undoable and acts immediately. Calling `newGame` with no argument and nothing
armed opens the panel to ask, rather than failing silently at a bar icon that
has no way to explain itself.

`newGame` takes `Easy`, `Medium`, `Hard`, or `Expert`; an unrecognised name
falls back to the configured difficulty rather than failing, so a keybinding
with a typo still deals a playable game. (It is not called `new` because that is
a reserved word.)

## How it works

| File | Role |
|---|---|
| `manifest.json` | Plugin declaration and the settings schema |
| `BarWidget.qml` | The bar icon, the IPC target, and the panel loader |
| `Panel.qml` | The board, game state, keyboard handling, and the save file |
| `Sudoku.js` | Puzzle generation, solving, and validation — pure functions |
| `Icon.qml` | The bar wordmark, drawn rather than set in a font |
| `Model.js` | Glyphs, labels, time formatting, save and stats serialisation |

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

**The bar wordmark** is drawn in QML because no icon font carries it, and
because the obvious alternative does not survive a 26px bar: a 3×3 grid of nine
characters gives each glyph about five pixels and reads as noise. Seven cells in
one row gives each letter the icon's full height. Divisions are marked by
brightness rather than thickness — a 2px rule around an 18px box eats the cell
it is meant to divide — and the letters use hinted rendering, since antialiased
stems turn to fog at this size. Vertical bars are 28px wide and cannot fit a
58px wordmark, so they fall back to the compact grid glyph automatically;
`barStyle: "Icon"` forces that everywhere.

**The attract loop** deals a throwaway Easy board and fills it in a shuffled
order, so it reads as someone solving rather than a cursor sweeping the grid. It
animates only while the panel is actually open — an unwatched animation inside
the process that draws your whole desktop is pure waste — and its state is kept
entirely separate from the real game's, so the two can never be confused.

**The clock** is wall-clock based rather than tick-counted. A one-second timer
that increments a counter drifts and stalls whenever the shell is busy, which
for a process hosting the whole desktop is often.

## Licence

MIT
