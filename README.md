# Omadoku

Sudoku in the Omarchy bar. Click the icon, get a board; the clock keeps running
while the popup is closed, and the game survives a shell restart.

An [Omarchy](https://omarchy.org/) shell plugin (`bar-widget`), running inside
the long-lived `omarchy-shell` Quickshell process.

```
[ menu | workspaces ]        [ clock ]        [ 󰎠 4:12 | audio | power ]
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

Saving any file in the plugin directory reloads the code automatically; use
`omarchy-shell shell rescanPlugins` if a change ever fails to land.

To remove it: `omarchy plugin disable io.github.bhaveshsooka.omadoku`.

## Playing

**Mouse** — left click the bar icon opens the board, right click deals a new
game, middle click pauses. In the grid, click a cell to select it and right
click to clear it.

**Keyboard**, once the popup has focus:

| Key | Does |
|---|---|
| `1`–`9` | Place the digit, or pencil it in when notes mode is on |
| `0`, `.`, `Backspace`, `Delete`, `x` | Clear the cell |
| Arrows or `hjkl` | Move the cursor (it wraps at the edges) |
| `Space` or `n` | Toggle pencil marks |
| `a` | Fill every empty cell with all its legal candidates |
| `u` / `r` | Undo / redo |
| `?` | Reveal one cell |
| `p` | Pause the clock |
| `g` | New game at the current difficulty |
| `Esc` | Close the board |

Typing the digit that is already in a cell clears it, which is what every other
sudoku does.

Clues are bold; your own entries are lighter, so the two stay distinguishable
in themes where the accent colour equals the foreground. A digit that repeats in
its row, column, or box turns the theme's urgent colour — turn that off in the
settings for a stricter game.

## Settings

Per-widget settings live in the widget's entry in `~/.config/omarchy/shell.json`
and are editable through Setup > Plugins.

| Key | Default | Meaning |
|---|---|---|
| `difficulty` | `Medium` | Difficulty for new games |
| `showTimer` | `true` | Show elapsed time beside the bar icon |
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
omarchy-shell io.github.bhaveshsooka.omadoku status
```

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
| `Model.js` | Glyphs, labels, time formatting, and save serialisation |

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
`~/.local/state/omadoku/game.json` — under `XDG_STATE_HOME` because it is real
user state, not regenerable cache. Writes are debounced and checkpointed every
15 seconds, so a crash costs seconds rather than the session. The save is
versioned and fully validated on load: wrong version, wrong shape, an
out-of-range digit, or clues that disagree with their own solution all read as
"no saved game" rather than restoring a board that cannot be finished.

A restored game comes back paused, and the clock starts again when you next open
the board — the shell restarting should not cost you minutes you never played.

**The clock** is wall-clock based rather than tick-counted. A one-second timer
that increments a counter drifts and stalls whenever the shell is busy, which
for a process hosting the whole desktop is often.

## Licence

MIT
