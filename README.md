# git-times-live

A standalone **live broadcast TV channel** for your git activity. Leave it
running and it updates itself: a tick-driven, full-screen "TV news" view that
polls your repos for new commits (and, with a forge configured, PR/issue
events) and shows them as a breaking-news feed under a live clock, with a
lower-third marquee ticker.

It polls git directly — **no collect, no cache write** — and stays open until
you quit.

## Install

No build step, no runtime dependencies beyond **bash 4+** and **git** (plus
**jq** if you enable forge events). Just run it from the project directory:

```bash
./git-times-live
```

Optionally put it on your `PATH` with a symlink (the entry is symlink-safe and
still finds its `lib/`):

```bash
ln -s "$PWD/git-times-live" ~/.local/bin/git-times-live
```

## Usage

```bash
./git-times-live                       # both local commits and forge events
./git-times-live --scope local         # local commits only (no network)
./git-times-live --mine                # only your own commits
./git-times-live --theme matrix        # pick an accent palette
./git-times-live --help                # full option + tunable reference
```

### Keys

| Key | Action                         |
|-----|--------------------------------|
| `q` | quit                           |
| `r` | refresh now                    |
| `p` | pause / resume                 |
| `m` | toggle the lower-third ticker  |
| `t` | toggle the A.I. desk (inline tokens) |
| `c` | toggle the churn column (per-commit Δ) |

## Configuration

Repo discovery and behaviour are env-driven:

| Variable                          | Meaning                                            | Default  |
|-----------------------------------|----------------------------------------------------|----------|
| `GIT_TIMES_ROOTS`                 | space-separated roots to scan (plus the cwd repo)  | common code dirs |
| `GIT_TIMES_THEME`                 | accent palette                                     | `neon`   |
| `GIT_TIMES_HIGHLIGHT`             | accent repo headings + type dots (`on`/`off`)      | `on`     |
| `GIT_TIMES_LIVE_INTERVAL`         | local commit poll cadence (s)                      | `10`     |
| `GIT_TIMES_LIVE_TICK`             | display tick / marquee step (s)                    | `0.25`   |
| `GIT_TIMES_LIVE_LOOKBACK`         | startup backfill window (s)                        | `86400`  |
| `GIT_TIMES_LIVE_FLASH`            | BREAKING banner flash duration (s)                 | `6`      |
| `GIT_TIMES_LIVE_FEED_MAX`         | max items kept on the wire                         | `60`     |
| `GIT_TIMES_LIVE_REMOTE_INTERVAL`  | remote (PR/issue) poll cadence (s)                 | `90`     |
| `GIT_TIMES_LIVE_TICKER`           | start with the ticker running (`on`/`off`)         | `off`    |
| `GIT_TIMES_LIVE_TOKENS`           | A.I. desk: inline per-repo assistant tokens (`on`/`off`) | `off` |
| `GIT_TIMES_LIVE_TOKENS_INTERVAL`  | A.I. desk poll cadence (s)                         | `60`     |
| `GIT_TIMES_LIVE_CHURN`            | churn column: inline per-commit Δ lines touched (`on`/`off`) | `off` |

The `--scope`, `--theme`, `--highlight`, `--width`, `--no-color`, `--authors`,
and `--mine` flags override the matching env at launch.

### A.I. desk (inline assistant tokens)

An **optional, off-by-default** module: every feed line gains a token column
right of the repo name — that repo's total assistant tokens over the window,
read from your **Claude Code transcripts** (default `~/.claude/projects`,
override with `GIT_TIMES_USAGE_CLAUDE_DIR`). The figure is the per-repo window
total, so every line of a repo carries the same count. It is the only part of
the channel that uses **jq** — and only while the module is on; off, the channel
stays pure git.

Right of the total, a green **`+growth`** tag shows how much that repo has gained
since you enabled the desk — the live delta against a baseline frozen at the first
collect after `t` (or launch). So you watch each project consume tokens in real
time. It is blank when the repo has not grown since you started watching.

Toggle it live with `t`, or start it on with `GIT_TIMES_LIVE_TOKENS=on`. The
usage collect runs asynchronously on its own cadence so the clock never stalls.
Fail-soft: no jq or no transcripts → the columns just stay blank.

### Churn column

A second **optional, off-by-default** module, independent of the A.I. desk and
toggled on its own with **`c`** (or `GIT_TIMES_LIVE_CHURN=on`): a cyan **`Δchurn`**
showing that commit's own churn — the lines it touched (additions + deletions),
compact (`Δ262`, `Δ48k`, `Δ1M`). Unlike the per-repo token and growth columns
(identical on every line of a repo), churn is **per commit** and exact, measured
straight from git (`git show --numstat`, **no jq**), captured once when the commit
first reaches the wire. Blank on PR/issue rows and on empty or binary-only commits.

The desk and churn columns are fully independent — run churn alone (pure git, no
jq), the token desk alone, both, or neither. Each toggle only widens or narrows the
headline column; the feed never shifts rows. Whenever either column is showing, a
color-matched header row labels the active columns (yellow `TOKENS`, green
`+GROWTH`, cyan `CHURN`) so the figures decode at a glance; with both off there is no
header row.

### Forge events (PR / issue)

To ride PR/issue events into the feed (Forgejo / GitHub / GitLab), copy
`.env.example` to `.env` and fill in your host, owner, and a token. The example
ships **placeholders only** — never commit a real token or host. `.env` is
gitignored.

```bash
cp .env.example .env
$EDITOR .env
```

Run with `--scope local` to skip the forge poll entirely (no network).

## Provenance

This project is **GENERATED** from the `git-times` source tree by
`scripts/build-live-dist.sh`. The lib files
and the entry are copied verbatim from the tested git-times source — git-times
remains the single source of truth. Do not hand-edit; regenerate to update. The
exact source commit is recorded in `MANIFEST.generated`.

## License

GPL-3.0 — see `LICENSE`.
