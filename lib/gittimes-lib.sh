# shellcheck shell=bash
# Shared helpers for git-times. Sourced by the subcommand scripts; not executed
# directly. All config is env-overridable so the offline test suite can pin it.

# git-times needs bash 4.2+ (mapfile, declare -A, ${x^^}, fractional read -t, and the
# printf '%(...)T' time format the live channel polls the clock with — added in 4.2, it
# silently prints the literal format on 4.0/4.1). macOS ships bash 3.2 as /bin/bash, where
# these fail with cryptic runtime errors — so every entry script sources this first and we
# fail loud with the fix instead.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]:-0}" -eq 4 ] && [ "${BASH_VERSINFO[1]:-0}" -lt 2 ]; }; then
    printf 'git-times: requires bash >= 4.2, but this is bash %s.\n' "${BASH_VERSION:-?}" >&2
    printf '  macOS ships 3.2 as /bin/bash — install a newer one: brew install bash\n' >&2
    exit 1
fi

# Resolve git-times' own install dir from THIS file's path (symlink-followed by the
# entry script), independent of the caller's cwd — so config + lib are found whether
# you run git-times from a project, the shell greeting in $HOME, or a launchd timer.
GN_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GN_ROOT="$(cd "$GN_LIB_DIR/.." && pwd)"

# Load git-times' own config from the repo-root .env (gitignored; copy .env.example to
# it). It lives WITH the tool and is resolved relative to this file, so the same config
# applies from any cwd, the shell greeting, or a background refresh — no global ~/.env.
# Never tracked; contents are never printed. Set GIT_TIMES_NO_ENV=1 to skip it — used by
# the test suite (hermetic) and by tooling that overrides a single var per invocation
# (which a fresh source of the file would otherwise clobber). Shared cloud keys you
# already export globally (ANTHROPIC_API_KEY, …) are still picked up via the env
# fallbacks below; put git-times-specific keys/settings in the repo .env.
if [ -z "${GIT_TIMES_NO_ENV:-}" ] && [ -f "$GN_ROOT/.env" ]; then
    set -a; . "$GN_ROOT/.env" 2>/dev/null || true; set +a
fi

# ── config (env-overridable; tracked source keeps placeholders, real values
#    come from the repo-root .env via the privacy pattern) ─────────────────────
GIT_TIMES_HOME="${GIT_TIMES_HOME:-$HOME/.cache/git-times}"
GIT_TIMES_ROOTS="${GIT_TIMES_ROOTS:-$HOME/code $HOME/projects $HOME/src $HOME/dev}" # repo roots to scan; non-existent skipped
GIT_TIMES_AUTHORS="${GIT_TIMES_AUTHORS:-}"             # git log --author regex; empty = all, "@me" = git identity
# Display time zone for every rendered date, weekday grid and clock. Empty (default) or
# "system" follows the machine zone / the ambient TZ; any IANA name (Europe/Berlin,
# America/New_York, UTC) retimes the whole paper. Applied once below as an exported TZ —
# the single lever gn_date and jq `localtime` both read. The reader's settings panel
# (`C` -> time zone) picks from GIT_TIMES_TZ_MENU and persists. An unknown name is ignored.
GIT_TIMES_TZ="${GIT_TIMES_TZ:-}"                       # ""/system = machine zone; else an IANA name
GIT_TIMES_TZ_MENU="${GIT_TIMES_TZ_MENU:-UTC Europe/London Europe/Berlin Europe/Moscow America/New_York America/Chicago America/Los_Angeles America/Sao_Paulo Asia/Dubai Asia/Kolkata Asia/Shanghai Asia/Tokyo Australia/Sydney Pacific/Auckland}"  # the picker's examples
GIT_TIMES_CACHE_TTL="${GIT_TIMES_CACHE_TTL:-1800}"     # seconds before greeting triggers a refresh
case "$GIT_TIMES_CACHE_TTL" in ''|*[!0-9]*) GIT_TIMES_CACHE_TTL=1800 ;; esac  # non-numeric → default, not a raw error on every shell open
# An LLM editorial is expensive (a CLI engine blocks ~8s), so routine recollects
# reuse the cached text and only re-consult the engine when the story moved or the
# text aged out — see gn_editorial_reuse. Manual triggers (`R` in the reader,
# --redraft) bypass the gate.
GIT_TIMES_EDITORIAL_MAX_AGE="${GIT_TIMES_EDITORIAL_MAX_AGE:-86400}"  # seconds an LLM editorial may ride along unchanged
case "$GIT_TIMES_EDITORIAL_MAX_AGE" in ''|*[!0-9]*) GIT_TIMES_EDITORIAL_MAX_AGE=86400 ;; esac
GIT_TIMES_EDITORIAL_DELTA="${GIT_TIMES_EDITORIAL_DELTA:-20}"         # commit-count move that forces a re-draft
case "$GIT_TIMES_EDITORIAL_DELTA" in ''|*[!0-9]*) GIT_TIMES_EDITORIAL_DELTA=20 ;; esac
GIT_TIMES_EDITORIAL="${GIT_TIMES_EDITORIAL:-template}" # off|template|omlx|ollama|openai|anthropic|claude|codex
# Feature precompute: "auto" lets `git-times refresh` (and so the cache-warmer) write
# the engine-drafted feature page right after a refresh — see `git-times feature write`.
GIT_TIMES_FEATURE="${GIT_TIMES_FEATURE:-off}"          # off|auto
GIT_TIMES_MAX_COMMITS="${GIT_TIMES_MAX_COMMITS:-300}"  # cap on the kept event list
case "$GIT_TIMES_MAX_COMMITS" in ''|*[!0-9]*) GIT_TIMES_MAX_COMMITS=300 ;; *) [ "$GIT_TIMES_MAX_COMMITS" -ge 1 ] || GIT_TIMES_MAX_COMMITS=300 ;; esac  # non-numeric or 0 → default (0 slices .commits to empty → no feed; feeds jq slice / arithmetic)
GIT_TIMES_MAX_WIDTH="${GIT_TIMES_MAX_WIDTH:-140}"      # readable cap on the content column
case "$GIT_TIMES_MAX_WIDTH" in ''|*[!0-9]*) GIT_TIMES_MAX_WIDTH=140 ;; esac  # non-numeric → default (feeds gn_width clamp)
GIT_TIMES_HEATMAP_WEEKS="${GIT_TIMES_HEATMAP_WEEKS:-53}" # activity-map span: week-columns to collect
case "$GIT_TIMES_HEATMAP_WEEKS" in ''|*[!0-9]*) GIT_TIMES_HEATMAP_WEEKS=53 ;; esac  # non-numeric → default (feeds hsince arithmetic)
GIT_TIMES_SESSION_GAP_MIN="${GIT_TIMES_SESSION_GAP_MIN:-90}" # marathon: idle minutes that split one coding session from the next
case "$GIT_TIMES_SESSION_GAP_MIN" in ''|*[!0-9]*) GIT_TIMES_SESSION_GAP_MIN=90 ;; *) [ "$GIT_TIMES_SESSION_GAP_MIN" -ge 1 ] || GIT_TIMES_SESSION_GAP_MIN=90 ;; esac  # non-numeric or <1 → default (0 would split every commit → marathon vanishes)
GIT_TIMES_THEME="${GIT_TIMES_THEME:-neon}"            # palette: neon|dracula|gruvbox|matrix|miami|tokyo|ember|uwu|mono
GIT_TIMES_HIGHLIGHT="${GIT_TIMES_HIGHLIGHT:-on}"      # accent repo headings + type dots per theme: on|off
GIT_TIMES_HEADLINES="${GIT_TIMES_HEADLINES:-band}"   # desk heading style: band|kicker|card|stamp|off
GIT_TIMES_MOTION="${GIT_TIMES_MOTION:-on}"           # master motion gate: off = same reader, zero animation
GIT_TIMES_OUTRO="${GIT_TIMES_OUTRO:-roll}"           # closing animation: roll|crumple|fold|fade|off

# Remote endpoints default to the matching bare env vars so they work
# zero-config, but tracked source never bakes in a real host/owner — the :-
# default stays empty so the remote is simply skipped when nothing is configured.
GIT_TIMES_FORGEJO_HOST="${GIT_TIMES_FORGEJO_HOST:-${FORGEJO_HOST:-}}"
GIT_TIMES_FORGEJO_OWNER="${GIT_TIMES_FORGEJO_OWNER:-${FORGEJO_OWNER:-}}"
GIT_TIMES_FORGEJO_TOKEN="${GIT_TIMES_FORGEJO_TOKEN:-${FORGEJO_TOKEN:-}}"   # same env fallback as the github/gitlab tokens below
# GitHub: auto-detected via the gh CLI (gh auth); login auto-resolved via gh.
# Override the login/token here only when not using gh.
GIT_TIMES_GITHUB_USER="${GIT_TIMES_GITHUB_USER:-${GITHUB_USER:-}}"
GIT_TIMES_GITHUB_TOKEN="${GIT_TIMES_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
# GitLab: auto-detected via the glab CLI; host defaults to gitlab.com (override
# for self-hosted). Token only needed when not using glab.
GIT_TIMES_GITLAB_HOST="${GIT_TIMES_GITLAB_HOST:-${GITLAB_HOST:-gitlab.com}}"
GIT_TIMES_GITLAB_TOKEN="${GIT_TIMES_GITLAB_TOKEN:-${GITLAB_TOKEN:-}}"

# ── editorial LLM backends (all optional; every one falls soft to template) ───
# The editorial engine turns the snapshot's fact line into prose. Local models are
# preferred (offline, free); cloud and CLI backends are equal-class opt-ins. Each
# engine reads only its own vars below; nothing here ever puts a key on the CLI.
#
# omlx + ollama are OpenAI-compatible local servers (`omlx serve …`, `ollama serve`)
# reached over their /chat/completions endpoint — no gateii, no wrapper command.
GIT_TIMES_OMLX_URL="${GIT_TIMES_OMLX_URL:-http://localhost:8000/v1}"
GIT_TIMES_OMLX_MODEL="${GIT_TIMES_OMLX_MODEL:-gemma-4-e2b-it-4bit}"
GIT_TIMES_OMLX_KEY="${GIT_TIMES_OMLX_KEY:-}"                  # usually none for a local server
GIT_TIMES_OLLAMA_URL="${GIT_TIMES_OLLAMA_URL:-http://localhost:11434/v1}"
GIT_TIMES_OLLAMA_MODEL="${GIT_TIMES_OLLAMA_MODEL:-llama3.2}"
# openai: any OpenAI-compatible cloud endpoint. Key from the environment only.
GIT_TIMES_OPENAI_URL="${GIT_TIMES_OPENAI_URL:-https://api.openai.com/v1}"
GIT_TIMES_OPENAI_KEY="${GIT_TIMES_OPENAI_KEY:-${OPENAI_API_KEY:-}}"
GIT_TIMES_OPENAI_MODEL="${GIT_TIMES_OPENAI_MODEL:-gpt-4o-mini}"
# anthropic: the Messages API (the old `api` engine — `api` still works as an alias).
# Key from GIT_TIMES_ANTHROPIC_KEY, then the legacy GIT_TIMES_API_KEY, then the
# standard ANTHROPIC_API_KEY. Never passed on the CLI (curl -K config on stdin).
GIT_TIMES_ANTHROPIC_KEY="${GIT_TIMES_ANTHROPIC_KEY:-${GIT_TIMES_API_KEY:-${ANTHROPIC_API_KEY:-}}}"
GIT_TIMES_ANTHROPIC_MODEL="${GIT_TIMES_ANTHROPIC_MODEL:-${GIT_TIMES_API_MODEL:-claude-haiku-4-5-20251001}}"
# claude / codex: drive an installed CLI (Claude Code headless / OpenAI Codex). The
# command is overridable; an empty model means the CLI's own default. Absent → template.
GIT_TIMES_CLAUDE_CMD="${GIT_TIMES_CLAUDE_CMD:-claude}"
GIT_TIMES_CLAUDE_MODEL="${GIT_TIMES_CLAUDE_MODEL:-}"
GIT_TIMES_CODEX_CMD="${GIT_TIMES_CODEX_CMD:-codex}"
GIT_TIMES_CODEX_MODEL="${GIT_TIMES_CODEX_MODEL:-}"
# The CLI engines have no /models endpoint, so the reader's `E` model toggle cycles a
# configured space-separated list of aliases/ids instead (live discovery via the API is
# used for omlx/ollama/openai; anthropic too when GIT_TIMES_ANTHROPIC_MODELS is empty).
# Empty → that engine has no model to cycle.
GIT_TIMES_CLAUDE_MODELS="${GIT_TIMES_CLAUDE_MODELS:-haiku sonnet opus}"
GIT_TIMES_CODEX_MODELS="${GIT_TIMES_CODEX_MODELS:-}"
# Anthropic DOES expose /v1/models, but that catalog is 30+ ids (most irrelevant to a
# one-line editorial). An optional allowlist curates the `E` picker / `models list`;
# empty falls back to the live catalog. Same space-separated form as the CLI lists.
GIT_TIMES_ANTHROPIC_MODELS="${GIT_TIMES_ANTHROPIC_MODELS:-}"

# ── LLM usage desk (the A.I. desk page): your coding-assistant token spend ─────
# A separate axis from the editorial engine above: that one USES an LLM to write
# the paper; this one REPORTS how much LLM work you did. It reads local CLI
# transcripts into the snapshot's `llm` block, surfaced on the A.I. desk page
# (reader key U, `git-times llm`). Provider-agnostic by design: each source is an
# adapter (collect-usage-<src>.sh) that normalizes into one record schema, so
# OpenAI/Anthropic usage-API adapters can dock later without touching the renderer
# or aggregate. All-local + fail-soft now: a missing transcript dir yields an empty
# desk, never an error.
GIT_TIMES_USAGE="${GIT_TIMES_USAGE:-on}"                      # on|off — collect + show the A.I. desk
GIT_TIMES_USAGE_SOURCES="${GIT_TIMES_USAGE_SOURCES:-claude}"  # comma list of adapters (local now: claude)
# Claude Code transcripts. CHANNEL records the billing contract the logs cannot
# reveal — subscription and API key are indistinguishable in a transcript (verified:
# entrypoint=cli, service_tier=standard, no auth field). max-sub means tokens count
# but the cost reads as "covered"; api-key prices them as real spend. Either way the
# price table only ever produces an ESTIMATE (logs carry no native cost).
GIT_TIMES_USAGE_CLAUDE_DIR="${GIT_TIMES_USAGE_CLAUDE_DIR:-$HOME/.claude/projects}"
GIT_TIMES_USAGE_CLAUDE_CHANNEL="${GIT_TIMES_USAGE_CLAUDE_CHANNEL:-max-sub}"  # max-sub|api-key
GIT_TIMES_USAGE_COST="${GIT_TIMES_USAGE_COST:-estimate}"     # estimate|off — compute $ from lib/llm-prices.json

# GN_LIB_DIR / GN_ROOT are resolved at the top of this file (needed for the .env load).

# A value-flag (--foo bar) with nothing after it must not reach `shift 2`: shifting
# past the end is a no-op that returns rc=1 without consuming anything, so an arg-parse
# `while [ $# -gt 0 ]` loop spins forever on a dangling trailing flag. Call this with
# the flag and the remaining arg count ($#) before each `shift 2` to fail loud instead.
gn_need_val() { [ "${2:-0}" -ge 2 ] || { printf 'git-times: %s needs a value\n' "$1" >&2; exit 2; }; }

GN_US=$'\x1f'   # unit separator for the git-log record format
GN_RS=$'\x1e'   # record separator — story brief packs the top-repo table rows with it
GN_GS=$'\x1d'   # group separator — fields within one top-repo row

# The press archive (git-backed edition store) ships as a sibling module; source it
# so every entry point that loads this lib — git-times, the reader, the tests — gets
# gn_archive_*. It only defines functions, so it is inert until a refresh calls it.
[ -f "$GN_LIB_DIR/archive.sh" ] && . "$GN_LIB_DIR/archive.sh"

gn_require() {  # gn_require <cmd> <hint>
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'git-times: %s is required but not installed. %s\n' "$1" "${2:-}" >&2
        return 1
    fi
}

# date(1) is BSD on macOS (-r EPOCH) and GNU on Linux (-d @EPOCH). Detect once.
if date -r 0 +%s >/dev/null 2>&1; then _GN_DATE=bsd; else _GN_DATE=gnu; fi
gn_date() {  # gn_date <epoch> <+fmt>
    if [ "$_GN_DATE" = bsd ]; then date -r "$1" "$2"; else date -d "@$1" "$2"; fi
}

# Window bounds [SINCE, UNTIL) for a timeframe, as "SINCE UNTIL" epochs.
# week  = since most recent Monday 00:00 (local) · month = since the 1st 00:00.
gn_window() {  # gn_window <7d|week|month|30d> <now-epoch>
    local tf="$1" now="$2" since until midnight secs wday mday anchor back
    # Self-defending guard: every call site passes the parse_opts-sanitised NOW today, but
    # a crafted non-numeric now would otherwise reach the $(( now - ... )) sinks below
    # (arithmetic injection) and an empty now would emit a garbage negative window. Clamp
    # anything non-numeric to the real clock.
    case "$now" in ''|*[!0-9]*) now=$(date +%s) ;; esac
    until="$now"
    case "$tf" in
        7d)  since=$(( now - 7*86400 )) ;;
        30d) since=$(( now - 30*86400 )) ;;
        week|month)
            secs=$(( 10#$(gn_date "$now" +%H)*3600 + 10#$(gn_date "$now" +%M)*60 + 10#$(gn_date "$now" +%S) ))
            midnight=$(( now - secs ))
            if [ "$tf" = week ]; then
                wday=$(gn_date "$now" +%u); back=$(( 10#$wday - 1 ))   # 1=Mon..7=Sun → days back to Monday
            else
                mday=$(gn_date "$now" +%d); back=$(( 10#$mday - 1 ))   # days back to the 1st
            fi
            # Walk back from a NOON anchor, then re-derive that day's local 00:00.
            # Stepping midnight by a fixed N*86400 drifts by the DST offset when the span
            # crosses a transition, landing 'since' at 23:00/01:00 of the start day; noon
            # ± the 1h DST shift stays inside the same day, so the re-derived 00:00 is exact.
            anchor=$(( midnight + 12*3600 - back*86400 ))
            secs=$(( 10#$(gn_date "$anchor" +%H)*3600 + 10#$(gn_date "$anchor" +%M)*60 + 10#$(gn_date "$anchor" +%S) ))
            since=$(( anchor - secs )) ;;
        *)   since=$(( now - 7*86400 )) ;;
    esac
    printf '%s %s' "$since" "$until"
}

gn_tf_label() {  # human label for the masthead
    case "$1" in
        7d) printf 'Last 7 days' ;; week) printf 'This week' ;;
        month) printf 'This month' ;; 30d) printf 'Last 30 days' ;;
        *) printf '%s' "$1" ;;
    esac
}

# Edition number: days since 2020-01-01, so the masthead ticks up daily and is
# deterministic for a fixed --now.
gn_edition() { printf '%s' "$(( ($1 - 1577836800) / 86400 ))"; }

# The canonical fail-soft payload a remote collector emits when it cannot fetch:
# zeroed counts tagged with <source>, so the aggregator treats it as enabled:false
# without special-casing. Callers exit after emitting it (their give-up path). The
# jq-missing bootstrap can't use this (no jq) and keeps its own printf literal.
gn_collect_fail() {  # gn_collect_fail <source> <reason>
    jq -nc --arg s "$1" --arg r "$2" \
        '{enabled:false, source:$s, reason:$r, prs_merged:0, issues_closed:0,
          pushes:0, prs_opened:0, issues_opened:0, events:[]}'
}

# Emit the shared jq `toepoch` def for the forge collectors: parse ISO8601 with
# either Z or a trailing ±HH:MM offset into a UTC epoch. jq mktime treats the
# broken-down time as UTC, so for an offset we correct by it. One definition —
# it was duplicated verbatim in collect-forgejo and collect-gitlab, and a def
# like this is exactly where the apostrophe-in-jq-comment trap bites.
gn_toepoch_jq() {
    cat <<'EOF'
    def toepoch:
      . as $s
      | ($s[0:19] | strptime("%Y-%m-%dT%H:%M:%S") | mktime) as $naive
      | if   ($s|test("Z$")) then $naive
        elif ($s|test("[+-][0-9][0-9]:[0-9][0-9]$")) then
             ($s[-6:]) as $o
             | (($o[1:3]|tonumber)*3600 + ($o[4:6]|tonumber)*60) as $os
             | (if ($o[0:1]=="+") then $naive - $os else $naive + $os end)
        else $naive end;
EOF
}

# Emit the shared jq `gn_dark($src)` def for the forge collectors. It builds the
# fail-soft disabled payload for the case where the feed slurp contains NO array at
# all — every page body was a JSON error object. curl exits 0 on HTTP 4xx, so a 401
# /403/5xx response body (an object, not the events array) flows straight through the
# parser; without this it counted as enabled-with-zero-activity and doctor reported
# the dead token as "authenticated & reachable". A genuinely empty feed is [] — an
# ARRAY — so it never reaches gn_dark; it parses to enabled:true with zero counts.
# The reason is derived from the API error message so doctor can name the next step
# (a bad token vs a rate limit). Apostrophe-free: this is concatenated into a jq
# program that lives in a bash single-quoted string (see the jq-comment trap).
gn_dark_jq() {
    cat <<'EOF'
    def gn_dark($src):
      ( map(select(type=="object")) | map((.message // "") | tostring)
        | map(select(. != "")) | .[0] // "" ) as $msg
      | ( if   ($msg | test("rate.?limit|too many request|quota";"i")) then "rate-limited"
          elif ($msg | test("credential|unauthor|forbidden|permission|invalid|expired|denied|token";"i")) then "auth-failed"
          else "api-error" end ) as $why
      | { enabled:false, source:$src, reason:$why,
          prs_merged:0, issues_closed:0, pushes:0, prs_opened:0, issues_opened:0, events:[] };
EOF
}

# Page a forge feed into one concatenated RAW stream on stdout. <fetch_fn> is a
# caller-defined function taking a 1-based page number and printing that page's
# body (a JSON array), or failing. Paging stops at <maxpages>, at a short page
# (fewer than <limit> rows), or when the optional <stop_fn> — given the page body —
# returns true. A mid-paging fetch failure emits the {"gt_truncated":true} marker
# so the downstream jq pass flags the feed as incomplete. Factored out of the
# github/gitlab/forgejo collectors, which carried five byte-identical copies.
gn_page_feed() {  # gn_page_feed <maxpages> <limit> <fetch_fn> [stop_fn]
    local maxpages="$1" limit="$2" fetch="$3" stop="${4:-}" page=1 body n
    while [ "$page" -le "$maxpages" ]; do
        body="$("$fetch" "$page")" \
            || { [ "$page" -gt 1 ] && printf '{"gt_truncated":true}\n'; break; }
        printf '%s\n' "$body"
        n="$(printf '%s' "$body" | jq 'if type=="array" then length else 0 end' 2>/dev/null || echo 0)"
        [ "${n:-0}" -lt "$limit" ] && break
        [ -n "$stop" ] && "$stop" "$body" && break
        page=$(( page + 1 ))
    done
    return 0   # the RAW stream is on stdout; the caller reads that, not our rc
}

# Resolve the --authors filter for one repo. "@me" → that repo's own git identity
# (user.email can differ per repo); an unresolved @me yields empty (no filter,
# rather than an empty desk). Any other value (regex / empty) passes through.
gn_repo_author() {  # gn_repo_author <repo> <authors>
    if [ "$2" = "@me" ]; then
        # @me → this repo's effective git identity (local → global → system). When git
        # has no user.email configured anywhere, return a sentinel that matches no author
        # rather than an empty string: the collectors omit --author when this is empty,
        # which would silently widen "@me" to ALL authors.
        local me; me="$(git -C "$1" config user.email 2>/dev/null || true)"
        [ -n "$me" ] || { printf 'git-times-no-identity'; return; }
        # git --author is a REGEX match, so an unescaped '.' in the email matches any
        # char — a.b@c would also catch axb@c, mis-attributing another committer to you.
        # Escape the metacharacters that are literal-when-escaped in BOTH basic and
        # extended POSIX regex (. [ ] ^ $ * \). The quantifier-flippers (+ ? ( ) { } |)
        # are left as-is: escaping them changes meaning under BRE, which is git's default.
        # Emails are ASCII, so a byte loop is safe (and forks nothing).
        local out="" i c
        for (( i=0; i<${#me}; i++ )); do
            c="${me:i:1}"
            case "$c" in '\'|'.'|'['|']'|'^'|'$'|'*') out+="\\$c" ;; *) out+="$c" ;; esac
        done
        printf '%s' "$out"
    else
        printf '%s' "$2"
    fi
}

# Discover git repos under the configured roots (one repo path per line).
gn_discover_repos() {  # gn_discover_repos [roots...]
    # Roots are whitespace-separated (the GIT_TIMES_ROOTS default) OR newline-separated
    # — a newline-separated list lets an individual root path contain spaces. Iterate
    # one root per line so neither a root nor a discovered repo path is word-split.
    local roots="${*:-$GIT_TIMES_ROOTS}" root list
    case "$roots" in
        *$'\n'*) list="$roots" ;;                  # newline-separated → spaces in paths safe
        *)       list="$(printf '%s\n' $roots)" ;; # whitespace-separated → one root per line
    esac
    while IFS= read -r root; do
        [ -n "$root" ] && [ -d "$root" ] || continue
        # Match `.git` DIRECTORIES only — i.e. standard working clones. Deliberately out
        # of scope: linked worktrees and submodules (where `.git` is a gitdir: pointer
        # FILE) and bare repos (no `.git` at all). Reasons: a worktree shares its parent's
        # object store, so running `git log` in both would double-count every shared commit
        # (collect-local/heatmap lack --all anyway); bare repos are usually serving mirrors,
        # not where you author commits. Point --repos at a specific checkout to override.
        find "$root" -maxdepth 3 -type d -name .git -prune 2>/dev/null \
            | while IFS= read -r g; do dirname "$g"; done
    done < <(printf '%s\n' "$list") | sort -u
}

# Map a file extension to a coarse language class. Used by aggregate via jq, but
# kept here as the single source of truth (also handy for the skill).
gn_lang_map_jq() {
cat <<'JQ'
{
  "sh":"shell","bash":"shell","zsh":"shell","fish":"shell",
  "py":"python","pyi":"python",
  "js":"js","mjs":"js","cjs":"js","ts":"js","tsx":"js","jsx":"js","vue":"js","svelte":"js",
  "rs":"rust","go":"go","c":"c","h":"c","cc":"cpp","cpp":"cpp","hpp":"cpp",
  "java":"java","kt":"kotlin","swift":"swift","rb":"ruby","php":"php","lua":"lua",
  "html":"web","htm":"web","css":"web","scss":"web","sass":"web",
  "md":"docs","mdx":"docs","rst":"docs","txt":"docs","adoc":"docs",
  "json":"config","yaml":"config","yml":"config","toml":"config","ini":"config",
  "cfg":"config","conf":"config","env":"config","xml":"config",
  "sql":"sql","graphql":"graphql","proto":"proto",
  "Dockerfile":"infra","tf":"infra","nix":"infra"
}
JQ
}

# ── tiny rendering helpers (color, only on a tty unless forced off) ───────────
# Three palettes, all keeping the news itself in focus: headlines/commit subjects
# carry GN_B (the terminal's brightest ink), decoration steps down through GN_DIM
# (readable secondary) to GN_FAINT (structural rules — present but quiet). GN_SEL
# is the reader's cursor: reverse video over the whole selected row so the focused
# story is unmistakable while arrowing. Themes only swap the palette, never the
# glyphs/text, so --no-color output and the offline tests are identical across all.
# Eight funky palettes you can cycle live with `t`, plus a plain utility fallback.
# Each keeps the six accents mutually distinguishable (the ● type-dots stay legible)
# while shifting the whole mood. Two slots carry the most ink, so they set the vibe:
# GN_CYN is the house ink (masthead, section rules, repo headings) — the theme's hero
# hue — and GN_GRN is the activity-map shading ramp. GN_RED stays a true red in every
# theme so +/− diffs never collapse. Codes are xterm-256 so they hold up in Terminal
# .app too, not just truecolor emulators.
#   neon     — default; electric synthwave: hot-magenta hero, spring-green map
#   dracula  — the classic purple night: violet hero, mint + pink
#   gruvbox  — retro warm earth: burnt-orange hero, olive + ochre
#   matrix   — green-phosphor hacker terminal (red kept for diffs)
#   miami    — vice sunset: hot-pink hero, teal + turquoise
#   tokyo    — tokyo-night: blue-violet hero, deep indigo + purple
#   ember    — fireside warmth: orange-red hero, amber + raspberry
#   uwu      — pastel kawaii: soft pink everything, mauve rules
#   scalm    — supercalm: muted sage/moss inks on a forced black background
#   daylight — calm light: muted ink on a forced soft off-white background
#   newspaper— real broadsheet: dark ink on a forced white-paper background
#   mono     — the understated basic 30-37 + dim look (utility, not in the cycle)
# scalm/daylight/newspaper additionally request a terminal background+foreground via
# GN_TERM_BG/GN_TERM_FG (OSC 10/11 hex). gn_color_init only records them; the interactive
# reader emits the OSC on entry (the `z` surface key) and resets it on exit, so the
# default surface is never changed permanently (a one-shot print/greeting leaves the
# terminal default untouched). These three are reached via `z`, not the `t` accent cycle.
gn_color_init() {  # gn_color_init <0|1 want-color> [theme] [force]
    # <force>=1 keeps colour on even when stdout is not a TTY — the interactive
    # reader captures the render subprocesses through a pipe (mapfile < <(...)),
    # so without this they would strip every escape and the body would be plain.
    local theme="${2:-${GIT_TIMES_THEME:-neon}}"
    if [ "${1:-1}" = 1 ] && { [ "${3:-0}" = 1 ] || [ -t 1 ]; } && [ -z "${NO_COLOR:-}" ]; then
        GN_R=$'\033[0m'; GN_B=$'\033[1m'; GN_IT=$'\033[3m'
        GN_TERM_BG=""; GN_TERM_FG=""   # most themes ride the terminal's own surface
        case "$theme" in
            mono)
                GN_DIM=$'\033[2m'; GN_FAINT=$'\033[2m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[31m'; GN_GRN=$'\033[32m'; GN_YEL=$'\033[33m'
                GN_BLU=$'\033[34m'; GN_MAG=$'\033[35m'; GN_CYN=$'\033[36m' ;;
            dracula)
                GN_DIM=$'\033[38;5;250m'; GN_FAINT=$'\033[38;5;239m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;210m'; GN_GRN=$'\033[38;5;84m';  GN_YEL=$'\033[38;5;228m'
                GN_BLU=$'\033[38;5;117m'; GN_MAG=$'\033[38;5;212m'; GN_CYN=$'\033[38;5;141m' ;;
            gruvbox)
                GN_DIM=$'\033[38;5;246m'; GN_FAINT=$'\033[38;5;240m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;167m'; GN_GRN=$'\033[38;5;142m'; GN_YEL=$'\033[38;5;214m'
                GN_BLU=$'\033[38;5;109m'; GN_MAG=$'\033[38;5;175m'; GN_CYN=$'\033[38;5;208m' ;;
            matrix)
                GN_DIM=$'\033[38;5;65m';  GN_FAINT=$'\033[38;5;238m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;196m'; GN_GRN=$'\033[38;5;82m';  GN_YEL=$'\033[38;5;154m'
                GN_BLU=$'\033[38;5;48m';  GN_MAG=$'\033[38;5;120m'; GN_CYN=$'\033[38;5;46m' ;;
            miami)
                GN_DIM=$'\033[38;5;250m'; GN_FAINT=$'\033[38;5;240m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;203m'; GN_GRN=$'\033[38;5;43m';  GN_YEL=$'\033[38;5;214m'
                GN_BLU=$'\033[38;5;45m';  GN_MAG=$'\033[38;5;207m'; GN_CYN=$'\033[38;5;198m' ;;
            tokyo)
                GN_DIM=$'\033[38;5;248m'; GN_FAINT=$'\033[38;5;239m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;204m'; GN_GRN=$'\033[38;5;150m'; GN_YEL=$'\033[38;5;180m'
                GN_BLU=$'\033[38;5;105m'; GN_MAG=$'\033[38;5;176m'; GN_CYN=$'\033[38;5;111m' ;;
            ember)
                GN_DIM=$'\033[38;5;246m'; GN_FAINT=$'\033[38;5;238m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;160m'; GN_GRN=$'\033[38;5;178m'; GN_YEL=$'\033[38;5;220m'
                GN_BLU=$'\033[38;5;130m'; GN_MAG=$'\033[38;5;197m'; GN_CYN=$'\033[38;5;202m' ;;
            uwu)
                GN_DIM=$'\033[38;5;182m'; GN_FAINT=$'\033[38;5;146m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;217m'; GN_GRN=$'\033[38;5;158m'; GN_YEL=$'\033[38;5;229m'
                GN_BLU=$'\033[38;5;147m'; GN_MAG=$'\033[38;5;219m'; GN_CYN=$'\033[38;5;212m' ;;
            scalm)  # supercalm: muted moss/sage on a forced black surface, soft light ink
                GN_TERM_BG='#000000'; GN_TERM_FG='#d0d0d0'
                GN_DIM=$'\033[38;5;245m'; GN_FAINT=$'\033[38;5;240m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;173m'; GN_GRN=$'\033[38;5;114m'; GN_YEL=$'\033[38;5;179m'
                GN_BLU=$'\033[38;5;109m'; GN_MAG=$'\033[38;5;139m'; GN_CYN=$'\033[38;5;108m' ;;
            daylight)  # calm light: muted ink on forced soft off-white paper, no loud accents
                GN_TERM_BG='#faf8f2'; GN_TERM_FG='#3a3a3a'
                GN_DIM=$'\033[38;5;243m'; GN_FAINT=$'\033[38;5;249m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;131m'; GN_GRN=$'\033[38;5;65m';  GN_YEL=$'\033[38;5;94m'
                GN_BLU=$'\033[38;5;60m';  GN_MAG=$'\033[38;5;96m';  GN_CYN=$'\033[38;5;24m' ;;
            newspaper)  # real broadsheet: dark ink on forced white paper, one bold-red spot
                GN_TERM_BG='#ffffff'; GN_TERM_FG='#000000'
                GN_DIM=$'\033[38;5;238m'; GN_FAINT=$'\033[38;5;250m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;160m'; GN_GRN=$'\033[38;5;28m';  GN_YEL=$'\033[38;5;136m'
                GN_BLU=$'\033[38;5;20m';  GN_MAG=$'\033[38;5;90m';  GN_CYN=$'\033[38;5;160m' ;;
            *)  # neon (default)
                GN_DIM=$'\033[38;5;251m'; GN_FAINT=$'\033[38;5;240m'; GN_SEL=$'\033[7m'
                GN_RED=$'\033[38;5;203m'; GN_GRN=$'\033[38;5;48m';  GN_YEL=$'\033[38;5;220m'
                GN_BLU=$'\033[38;5;39m';  GN_MAG=$'\033[38;5;141m'; GN_CYN=$'\033[38;5;201m' ;;
        esac
    else
        GN_R=''; GN_B=''; GN_DIM=''; GN_IT=''; GN_FAINT=''; GN_SEL=''
        GN_RED=''; GN_GRN=''; GN_YEL=''; GN_BLU=''; GN_MAG=''; GN_CYN=''
        GN_TERM_BG=''; GN_TERM_FG=''
    fi
}

# Emit / reset the OSC 10/11 terminal foreground+background a theme requested via
# GN_TERM_FG/GN_TERM_BG. Only the interactive reader (which owns the screen and resets
# on exit) calls these — never a one-shot render — so the terminal's default surface is
# never changed permanently. gn_term_surface_apply re-reads the globals each call, so a
# live `t` switch into or out of a paper theme just re-emits or clears.
gn_term_surface_apply() {
    [ -n "${GN_TERM_BG:-}" ] && printf '\033]11;%s\033\\' "$GN_TERM_BG"
    [ -n "${GN_TERM_FG:-}" ] && printf '\033]10;%s\033\\' "$GN_TERM_FG"
}
gn_term_surface_reset() { printf '\033]111\033\\\033]110\033\\'; }  # back to the profile defaults

# -- sticky settings: moved to lib/settings.sh, sourced here --
# A sourced-only fragment (no set flags): defines gn_setting_file/load/save and
# the per-setting load/save/resolve sets (theme, highlight, headline, engine,
# model, anim, motion, outro, intro, ads). Needs GIT_TIMES_HOME in scope.
. "$GN_LIB_DIR/settings.sh"

# Remember the zone the process started in (for the "system" pick that reverts to it),
# then apply the resolved display zone. gn_date (date -r/-d) and jq `localtime` both read
# TZ, so this one export retimes every date, grid and DST gate; an empty resolve leaves
# the ambient zone untouched, so a hermetic run that pins TZ=UTC is never overridden.
GN_TZ_AMBIENT_SET=0; [ -n "${TZ+x}" ] && GN_TZ_AMBIENT_SET=1
GN_TZ_AMBIENT="${TZ:-}"
gn_tz_apply "$(gn_tz_resolve)"

# -- the wire & the pulse: moved to lib/ticker.sh, sourced here --
# A sourced-only fragment (no set flags): defines gn_anim_cells, gn_marquee_win,
# gn_wire_text and gn_pulse_strip (marquee normalizing, windowing, and the
# jq content builders reading the snapshot).
. "$GN_LIB_DIR/ticker.sh"

# -- editorial model server: moved to lib/engine.sh, sourced here --
# A sourced-only fragment (no set flags): defines gn_engine_server,
# gn_chat_models_only, gn_emit_word_list, gn_served_models, gn_feature_marker,
# gn_editorial_reachable, gn_model_warm, gn_looks_like_reasoning and
# gn_warmer_state. Needs the GIT_TIMES_* engine config in scope.
. "$GN_LIB_DIR/engine.sh"

# -- viewport geometry helpers: moved to lib/layout.sh, sourced here --
# A sourced-only fragment (no set flags): defines gn_term_size, gn_term_cols,
# gn_fit_width, gn_center_pad and gn_strwidth into this shell.
. "$GN_LIB_DIR/layout.sh"

# -- press loader: moved to lib/loader.sh, sourced here --
# A sourced-only fragment (no set flags): defines gn_press and its _gn_press_*
# helpers. Needs GN_* (gn_color_init), TF and the geometry helpers in scope.
. "$GN_LIB_DIR/loader.sh"

# -- outro: the closing animation (lib/outro.sh), sourced here --
# A sourced-only fragment (no set flags): defines gn_outro_play, the per-row
# transforms and the style frames. Needs GN_* and gn_strwidth in scope.
. "$GN_LIB_DIR/outro.sh"

# -- shared render & reader-line helpers: moved to lib/render-common.sh --
# A sourced-only fragment (no set flags): defines the readability formatters
# (gn_human, gn_ago, gn_spark, gn_bar2, gn_meter), the render line helpers
# (hr, gn_width, section, gn_nameplate), gn_footer_wrap/gn_footer_paint,
# gn_readkey, gn_story_label/gn_label_index, gn_type_color and the gn_hl_*
# pickers. Needs GN_*, the layout.sh geometry and GIT_TIMES_MAX_WIDTH in scope.
. "$GN_LIB_DIR/render-common.sh"
