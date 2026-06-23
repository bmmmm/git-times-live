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

The `--scope`, `--theme`, `--highlight`, `--width`, `--no-color`, `--authors`,
and `--mine` flags override the matching env at launch.

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
