# Contributing to Omadoku

How work moves through this repository. For playing the game see
[README.md](README.md); for how it is built see
[ARCHITECTURE.md](ARCHITECTURE.md).

## The one rule that matters

**`main` must only ever move forward.**

Omadoku is installed by cloning this repository, and `omarchy plugin update`
is `git fetch origin HEAD` followed by `git merge --ff-only`. If `main` is ever
rewritten — a force push, a rebase, an amended commit — that merge stops being
a fast-forward and **every existing install is stuck on old code** until its
owner reinstalls by hand. There is no telemetry to tell you it happened and no
way to push a fix, because the fix would arrive by the same broken path.

A ruleset blocks force pushes and deletions on `main`, with no bypass actors.
That is deliberate: an agent working in this repository authenticates as the
owner, so a bypass for the owner would be a bypass for everything.

## Branching

```
main ─────────────────────────────────●───────────  release channel, tagged
                                     ╱
release/1.3.0 ──●────────●──────────●─────────────  one branch per version
               ╱        ╱          ╱
feat/daily ───●        ╱          ╱                 one branch per change
feat/mark ────────────●          ╱
docs/contributing ──────────────●
```

- **`main`** is the release channel. Users are on it, whether they know it or
  not. Nothing lands here except a finished release.
- **`release/X.Y.Z`** collects everything going into one version. Cut it from
  `main` when the version's work starts.
- **Work branches** are cut from the release branch and merged back into it,
  never into `main` directly.

Name work branches `<type>/<slug>`, using the same types as commit messages:
`feat/`, `fix/`, `docs/`, `ci/`, `chore/`. Keep one change per branch.

Both `main` and `release/*` require a pull request and refuse force pushes.
Release tags `v*` cannot be deleted, moved, or overwritten.

### Why not branch features off `main`

Because `main` is what users run. Merging each feature there as it lands means
shipping every intermediate state to everyone. The release branch is where a
version becomes coherent before anybody has to live with it.

## Making a change

```bash
git fetch origin
git checkout -b feat/my-change origin/release/1.3.0

# ... work ...

node test/run.js         # 155 checks over the pure-JS game logic
node test/manifest.js    # manifest.json against itself and the files it names
```

Then open a pull request **against the release branch**, not `main`. CI runs
the same two suites plus a QML parse check on every push and pull request.

Do not put the version bump on a work branch — see [Releasing](#releasing).

### Running it for real

The tests cover the logic, not the shell. To see a change in a running bar,
point Omarchy at your checkout:

```bash
rm -rf ~/.config/omarchy/plugins/io.github.bhaveshsooka.omadoku
ln -s "$PWD" ~/.config/omarchy/plugins/io.github.bhaveshsooka.omadoku
omarchy-restart-shell
```

Undo it by removing the symlink and installing normally with `omarchy plugin
add` again.

`omarchy-shell` only forwards IPC calls to a shell that is already running —
it cannot start or stop one. `omarchy-restart-shell` is the command that
restarts it.

QML errors are easier to read if you run the shell yourself rather than
hunting for them afterwards:

```bash
omarchy-restart-shell            # so only one copy is running
pkill -x quickshell
quickshell -n -p /usr/share/omarchy/shell
```

Everything the plugin logs then lands in that terminal, and Ctrl-C plus
`omarchy-restart-shell` puts the desktop back.

### Checking QML locally

```bash
qmllint *.qml
```

`qmllint` rejects `function name(): void`, which the QML engine accepts and
Quickshell's `IpcHandler` documentation uses, so `BarWidget.qml` will report a
parse error that is not real. CI lints a copy with that annotation stripped;
locally, ignore that one message. Unresolved `qs.Commons` and `qs.Ui` imports
are expected too — those come from Omarchy, not from here.

## Commit messages

`type: imperative summary`, using `feat`, `fix`, `docs`, `ci`, `chore`.

The body is where the value is. Say **why**, not what — the diff already says
what. A reader six months from now wants the constraint you were working
under, the option you rejected, and the reason. Existing history is the
reference; match it.

## Code

- **No dependencies.** The repository is the deployable artifact. There is no
  build step, no package manager, and no lockfile, including in CI.
- **No network access, and no new external commands.** The only process this
  plugin spawns is a fixed `mkdir -p`. That minimal surface is what the
  marketplace security baseline reviewed, and every addition is re-reviewed on
  the next listing update.
- **Logic goes in `.js`, not in QML.** `Sudoku.js` and `Model.js` are
  `.pragma library` files with no QML in them, which is why they can be tested
  by `node` with no display. New logic belongs there, with a test.
- **Nothing blocks the UI thread.** This code runs inside the process that
  draws the entire desktop — the bar, notifications, every other widget. Bound
  every search by a fixed node count rather than a deadline, so behaviour does
  not vary with machine speed.
- **Think before bumping `SAVE_VERSION` or `STATS_VERSION`.** Both readers
  default every absent field, so adding an optional field needs no bump. A bump
  discards every in-progress game, or every lifetime record, on upgrade. Bump
  when a field changes meaning, not when one is added.

## Releasing

1. Merge every work branch into `release/X.Y.Z` and confirm CI is green.
2. Bump `version` in `manifest.json` on the release branch, as its last commit.
   Semver against the plugin's surface: a new IPC method or setting is a minor,
   a behaviour change users can see is a minor, a fix is a patch.
3. Open a pull request from `release/X.Y.Z` into `main` and merge it.
4. Tag `main` as `vX.Y.Z` and push the tag.
5. Publish a GitHub release from that tag. Write the notes for someone who has
   already read the README — list what changed, do not restate what the plugin
   is.
6. **Update the marketplace listing.** This does not happen on its own.

### The marketplace step

The listing is pinned to an exact commit and does not follow `main`. Until it
is updated, marketplace installs get the old version while existing installs
fast-forward to the new one.

Open a [Plugin verification][verify] issue, choose **Verify and publish a newer
upstream commit**, and give the plugin ID, the repository URL, and the **full
40-character SHA** of the new `main` HEAD. A maintainer applies
`approved-and-verified` once the scan reports.

If a submission or update issue reports against a stale commit, **edit the
issue body** — that re-runs validation. Posting a comment does nothing; the
automation triggers on `issues: [opened, edited, reopened, labeled, unlabeled]`
and not on comments.

Note that the shell never reads `manifest.json`'s `version`. It is
documentation for humans and for the listing, which is exactly why the tag and
the release notes have to carry their weight.

[verify]: https://github.com/omacom/omarchy-plugin-marketplace/issues/new?template=verify-plugin.yml

## Reporting a bug

Include your Omarchy and Quickshell versions, your bar orientation and theme,
and whether the board was mid-game, paused, or finished. The shell runs inside
the Hyprland session unit rather than one of its own, so anything it logged is
in `journalctl --user -u wayland-wm@hyprland.desktop` — or in the terminal, if
you started it there as above.

Do not paste `~/.local/state/omadoku/game.json` into a public issue without
looking at it first — it contains the board you are playing and nothing else,
but read it rather than trusting that sentence.
