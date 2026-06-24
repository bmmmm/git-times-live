# shellcheck shell=bash
# git-times — the live broadcast channel. Sourced by the git-times entrypoint;
# never executed directly, no `set` flags (would leak to the caller). Defines
# live_broadcast() only — a tick-driven, full-screen "TV news" view that polls
# for new commits (and, phase 2, remote PR/issue events) and shows them as a
# breaking-news feed under a live clock, with a lower-third marquee ticker.
#
# Why a new mode and not a reader view: the reader is a PULL model (you leaf
# through a cached edition). This is a PUSH/tick model — a channel left running
# that updates itself. It shares the render primitives (gn_ago/gn_pad/gn_truncate/
# gn_type_color/gn_marquee_win_v) and the terminal discipline (alt screen, stty,
# trap cleanup) but owns its own light data path: a cheap `git log --since` sweep
# per repo, NOT a full collect (which carries --numstat + network + a jq aggregate
# and is seconds-heavy — far too expensive per tick). Lives entirely off git, so
# no jq runs on the hot path and the jq-apostrophe trap never applies here.
#
# Config (all env-overridable):
#   GIT_TIMES_LIVE_INTERVAL   local commit poll cadence, seconds (default 10)
#   GIT_TIMES_LIVE_TICK       display tick / marquee step, seconds (default 0.25)
#   GIT_TIMES_LIVE_LOOKBACK   backfill window at startup, seconds (default 86400)
#   GIT_TIMES_LIVE_FLASH      how long the BREAKING banner flashes, seconds (default 6)
#   GIT_TIMES_LIVE_FEED_MAX   max items kept on the wire (default 60)
#   GIT_TIMES_LIVE_REMOTE_INTERVAL  remote (PR/issue) poll cadence, seconds (default 90)
#   GIT_TIMES_LIVE_TICKER     start with the lower-third marquee running (default off)
#   GIT_TIMES_LIVE_TOKENS     show the A.I. desk panel — per-repo assistant tokens (default off)
#   GIT_TIMES_LIVE_TOKENS_INTERVAL  assistant-usage poll cadence, seconds (default 60)
#
# The A.I. desk panel is an OPTIONAL module (off by default — not every channel
# wants it). When on (env or the `t` key), a per-repo "tokens used" strip rides
# below the feed, sourced from the same Claude Code transcripts as the reader's
# A.I. desk. It is the ONE jq consumer here, and only while enabled: the usage
# collect runs ASYNC on its own cadence (like the forge poll), so the clock never
# stalls, and when the module is off NO jq ever runs — the channel stays pure git.
# "If present" is fail-soft: no jq or no transcripts → the panel reads as quiet.
# Reads the parse_opts globals in scope: TF, SCOPE, AUTHORS, NOW, WIDTH, the GN_*
# palette (gn_color_init, called by the dispatch) and everything gittimes-lib.sh
# provides — bash dynamic scoping, the house pattern, like reader.sh.

live_broadcast() {
    # ── config ───────────────────────────────────────────────────────────────
    local LV_INTERVAL LV_TICK LV_LOOKBACK LV_FLASH LV_FEEDMAX
    LV_INTERVAL="${GIT_TIMES_LIVE_INTERVAL:-10}";  case "$LV_INTERVAL" in ''|*[!0-9]*) LV_INTERVAL=10 ;; esac
    LV_LOOKBACK="${GIT_TIMES_LIVE_LOOKBACK:-86400}"; case "$LV_LOOKBACK" in ''|*[!0-9]*) LV_LOOKBACK=86400 ;; esac
    LV_FLASH="${GIT_TIMES_LIVE_FLASH:-6}";         case "$LV_FLASH" in ''|*[!0-9]*) LV_FLASH=6 ;; esac
    LV_FEEDMAX="${GIT_TIMES_LIVE_FEED_MAX:-60}";   case "$LV_FEEDMAX" in ''|*[!0-9]*) LV_FEEDMAX=60 ;; esac
    # The tick feeds `read -t` straight — refuse anything but a plain decimal.
    LV_TICK="${GIT_TIMES_LIVE_TICK:-0.25}";        case "$LV_TICK" in ''|.|*[!0-9.]*|*.*.*) LV_TICK=0.25 ;; esac
    local LV_REMOTE_INTERVAL
    LV_REMOTE_INTERVAL="${GIT_TIMES_LIVE_REMOTE_INTERVAL:-90}"; case "$LV_REMOTE_INTERVAL" in ''|*[!0-9]*) LV_REMOTE_INTERVAL=90 ;; esac
    # The lower-third marquee (the only ever-present motion) is off by default for a
    # calmer channel — the rec-dot blink and the BREAKING pulse already signal life and
    # new activity. m toggles it live; GIT_TIMES_LIVE_TICKER=on starts it running. This
    # is deliberately independent of the global GIT_TIMES_MOTION master: that gate is the
    # reader's, and the live channel wants its own one-key control over just the ticker.
    local LV_MARQUEE=0
    case "${GIT_TIMES_LIVE_TICKER:-}" in 1|on|true|yes) LV_MARQUEE=1 ;; esac
    # The A.I. desk panel (per-repo assistant tokens) is an opt-in module, off by
    # default — it is the only jq consumer and not every channel wants it. t toggles
    # it live; GIT_TIMES_LIVE_TOKENS=on starts it on. Its async usage collect runs on
    # its own (slower) cadence — the transcript parse is heavier than a git-log sweep.
    local LV_TOKENS=0
    case "${GIT_TIMES_LIVE_TOKENS:-}" in 1|on|true|yes) LV_TOKENS=1 ;; esac
    local LV_TOKENS_INTERVAL
    LV_TOKENS_INTERVAL="${GIT_TIMES_LIVE_TOKENS_INTERVAL:-60}"; case "$LV_TOKENS_INTERVAL" in ''|*[!0-9]*) LV_TOKENS_INTERVAL=60 ;; esac

    # ── palette state (gn_color_init ran in the dispatch) ─────────────────────
    local COLOR=0; [ -n "$GN_R" ] && COLOR=1
    local REV=""; [ "$COLOR" = 1 ] && REV=$'\033[7m'
    local HLSTATE; HLSTATE="$(gn_hilite_resolve "${HIGHLIGHT:-}")"

    # ── runtime state ─────────────────────────────────────────────────────────
    local -a LV_REPOS=() LV_FEED=() LV_BUF=()
    local -A LV_SEEN=()
    local LV_NEW=0 LV_TICKLOOP="" LV_TICKOFF=0 LV_RESIZE=1
    local LINES=24 COLS=80 CW=76 PAD=0 BODY=18 PADS="" HRULE=""
    local _stty_saved="" last_local=0 last_remote=0 flash_until=0 now=0 key="" paused=0
    local LV_REMOTE_PID="" LV_REMOTE_PF="" remote_backfill=0
    # A.I. desk async-poll state: a finished collect lands "repo<US>tokens" rows in
    # LV_TOK_ROWS, which _live_tokens_build renders into the cached LV_TOK_LINE strip.
    local LV_TOK_PID="" LV_TOK_PF="" last_tokens=0 LV_TOK_READY=0 LV_TOK_LINE=""
    local -a LV_TOK_ROWS=()
    # Cached chrome: the banner inner + status bar measure non-ASCII glyphs (·/◉), so
    # they are built once per state change (poll/pause/resize/flash flip) instead of every
    # heartbeat — LV_CHROME_DIRTY marks them stale. This keeps the per-tick frame fork-free.
    local LV_FLASHON=0 LV_CHROME_DIRTY=1 LV_BANNER_INNER="" LV_BANNER_SP="" LV_BANNER_COL="" LV_BANNER_TAG="" LV_STATUS="" LV_MAST_L="" LV_MAST_GAP=""

    # ── geometry: fill the terminal, cap the column, cache the pad + rule ──────
    # Recomputed only on resize (SIGWINCH sets LV_RESIZE), never per tick — so the
    # heartbeat pays no stty/tput fork. BODY is the feed height: chrome is masthead(1)
    # + rule(1) + banner(1) + rule(1) + status(1) = 5 rows, plus 1 for the marquee row
    # only while the ticker runs. When the ticker is off, that row goes to the feed.
    _live_geometry() {
        local s; s="$(gn_term_size)"; LINES="${s%% *}"; COLS="${s##* }"
        case "$LINES" in ''|*[!0-9]*) LINES=24 ;; esac
        case "$COLS"  in ''|*[!0-9]*) COLS=80  ;; esac
        [ "$COLS"  -lt 24 ] && COLS=24
        [ "$LINES" -lt 8  ] && LINES=8
        if [ "${WIDTH:-0}" -gt 0 ] 2>/dev/null; then CW="$(gn_fit_width "$COLS" "$WIDTH")"
        else CW="$(gn_fit_width "$COLS" "$GIT_TIMES_MAX_WIDTH")"; fi
        # gn_fit_width floors at 62 for a readable column; on a sub-62-col terminal that
        # floor is WIDER than the tty, so every framed row would wrap and corrupt the
        # fixed-height frame. Clamp to the real width — a cramped channel beats a broken one.
        [ "$CW" -gt "$COLS" ] && CW="$COLS"
        PAD="$(gn_center_pad "$COLS" "$CW")"
        # chrome rows: masthead+rule+banner+rule+status = 5, +1 per optional strip
        # (the marquee and the A.I. desk panel each cost the feed one row when on).
        local chrome=5
        [ "$LV_MARQUEE" = 1 ] && chrome=$(( chrome + 1 ))
        [ "$LV_TOKENS"  = 1 ] && chrome=$(( chrome + 1 ))
        BODY=$(( LINES - chrome )); [ "$BODY" -lt 1 ] && BODY=1
        printf -v PADS '%*s' "$PAD" ''
        printf -v HRULE '%*s' "$CW" ''; HRULE="${HRULE// /─}"
        # masthead layout: the wordmark (left) is static; the clock (right) is a fixed 10
        # cols ("◉ HH:MM:SS"). Size the gap once here, not per heartbeat. On a narrow channel
        # (CW < 31) truncate the wordmark so wordmark+gap+clock never exceeds CW — else the
        # masthead row wraps and corrupts the fixed-height frame (the same hazard the CW
        # clamp above guards for the rules/banner; the status bar has its own fit at build).
        LV_MAST_L="${GN_B}${GN_CYN}THE GIT TIMES${GN_R}${GN_DIM} · LIVE${GN_R}"
        local mlw; gn_strwidth_v mlw "$LV_MAST_L"
        if [ "$(( mlw + 11 ))" -gt "$CW" ]; then   # 10 clock + 1 min gap
            gn_truncate_v LV_MAST_L "$LV_MAST_L" "$(( CW - 11 ))"; gn_strwidth_v mlw "$LV_MAST_L"
        fi
        local mgap=$(( CW - mlw - 10 )); [ "$mgap" -lt 1 ] && mgap=1
        printf -v LV_MAST_GAP '%*s' "$mgap" ''
    }

    # ── repo discovery (once at start; +cwd, deduped — same set collect scans) ──
    _live_discover() {
        local pin_top
        pin_top="$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || true)"
        mapfile -t LV_REPOS < <( { gn_discover_repos; [ -n "$pin_top" ] && printf '%s\n' "$pin_top"; } \
                                 | awk 'NF && !seen[$0]++')
    }

    # ── conventional-commit type off a subject ("feat(x): y" → "feat") into <outvar> ─
    # Strips the breaking-change ! and lowercases like aggregate.sh, so feat!: and Fix:
    # get the same accent on the wire as on the front page. An out-var (printf -v), so the
    # backfill loop pays no subshell per commit.
    _live_type_v() {  # _live_type_v <outvar> <subject>
        local __ov="$1" s="$2" head=""
        case "$s" in
            *:\ *) head="${s%%:*}"; head="${head%%(*}"; head="${head## }"; head="${head%% }"
                   head="${head%!}"; head="${head,,}"
                   case "$head" in
                       feat|fix|docs|refactor|perf|test|ci|build|style|chore|revert) ;;
                       *) head="" ;;
                   esac ;;
        esac
        printf -v "$__ov" '%s' "$head"
    }

    # ── feed list: sort newest-first, cap, then reconcile LV_SEEN + LV_NEW ─────
    # Args: the dedup-keys appended this sweep (each record carries its key as the last
    # US-field). The caller appends every fresh record WITHOUT counting it; the count is
    # settled HERE, after the cap, so a capped-out add never arms the BREAKING flash over
    # a frame in which nothing new actually shows, and a dropped key does not linger in
    # LV_SEEN (its growth tracks the wire, not the whole session) nor stay permanently
    # invisible — a later poll can resurface it once the wire has room.
    _live_feed_sort() {  # _live_feed_sort [key...]  → sets LV_NEW = appended keys still visible
        local -a added=( "$@" )
        LV_NEW=0
        [ "${#added[@]}" -gt 0 ] || return 0          # nothing appended → feed unchanged
        # -s (stable): commits sharing a second keep poll order (git-log newest-first)
        local -a kept
        mapfile -t kept < <(printf '%s\n' "${LV_FEED[@]}" | sort -s -t"$GN_US" -k1,1nr | head -n "$LV_FEEDMAX")
        local -A vis=(); local rec key k
        for rec in "${kept[@]}"; do key="${rec##*"$GN_US"}"; vis[$key]=1; done
        for rec in "${LV_FEED[@]}"; do key="${rec##*"$GN_US"}"; [ -n "${vis[$key]:-}" ] || unset 'LV_SEEN[$key]'; done
        LV_FEED=( "${kept[@]}" )
        for k in "${added[@]}"; do [ -n "${vis[$k]:-}" ] && LV_NEW=$(( LV_NEW + 1 )); done
    }

    # ── the cheap poll: new commits since <since-epoch> across all repos ───────
    # One `git log --since` per repo with NO --numstat — returns instantly when a
    # repo has nothing new. sha-deduped (the --since boundary can re-list a commit
    # on the second), so re-polling is idempotent. Appends fresh records; _live_feed_sort
    # then settles LV_NEW = how many are visible after the cap.
    _live_poll_local() {  # _live_poll_local <since-epoch>
        local since="$1" repo name author sha ct subj key ctype
        local -a added=()
        for repo in "${LV_REPOS[@]}"; do
            [ -d "$repo" ] || continue
            git -C "$repo" rev-parse --git-dir >/dev/null 2>&1 || continue
            name="$(basename "$repo")"
            author="$(gn_repo_author "$repo" "${AUTHORS:-}")"
            while IFS="$GN_US" read -r sha ct subj; do
                [ -n "$sha" ] || continue
                key="c:$sha"
                [ -n "${LV_SEEN[$key]:-}" ] && continue
                LV_SEEN[$key]=1
                _live_type_v ctype "$subj"
                LV_FEED+=("${ct}${GN_US}commit${GN_US}${name}${GN_US}${ctype}${GN_US}${subj}${GN_US}${key}")
                added+=("$key")
            done < <(git -C "$repo" log --no-merges --since="@$since" \
                        ${author:+--author="$author"} \
                        --pretty="tformat:%H${GN_US}%ct${GN_US}%s" 2>/dev/null)
        done
        _live_feed_sort ${added[@]+"${added[@]}"}
        return 0
    }

    # ── remote (PR/issue) events: polled ASYNC so a hung forge call never freezes
    # the clock. collect-remote.sh runs as a background job into a sentinel file;
    # the loop reaps it on a later tick, merges its events, and (re)starts on the
    # remote cadence. Fail-soft: a dark/erroring forge yields an empty events list,
    # so this simply adds nothing — the local feed keeps running. ──────────────────
    _live_remote_start() {  # _live_remote_start <since-epoch> <until-epoch>
        [ -n "$LV_REMOTE_PID" ] && return 1    # one poll in flight at a time — nothing launched
        LV_REMOTE_PF="$(mktemp "${TMPDIR:-/tmp}/gt-live-remote.XXXXXX" 2>/dev/null)" || { LV_REMOTE_PF=""; return 1; }
        ( bash "$GN_LIB_DIR/collect-remote.sh" --since "$1" --until "$2" > "$LV_REMOTE_PF" 2>/dev/null ) &
        LV_REMOTE_PID=$!
        return 0   # a poll launched — the caller may advance last_remote
    }
    # Reap a finished async remote poll: merge its events, drop the sentinel. rc 0
    # only when something genuinely new merged (so the caller flashes + rerenders);
    # rc 1 while the job is still in flight or nothing was new.
    _live_remote_reap() {
        [ -n "$LV_REMOTE_PID" ] || return 1
        kill -0 "$LV_REMOTE_PID" 2>/dev/null && return 1    # still running — try again next tick
        wait "$LV_REMOTE_PID" 2>/dev/null; LV_REMOTE_PID=""
        _live_remote_merge "$LV_REMOTE_PF"
        rm -f "$LV_REMOTE_PF" 2>/dev/null; LV_REMOTE_PF=""
        [ "$LV_NEW" -gt 0 ]
    }
    # Merge PR/issue events (pushes excluded — their commits already ride the local
    # feed) from a collect-remote.sh payload, keyed-deduped; _live_feed_sort settles LV_NEW. The jq here
    # carries no apostrophe in any comment (there are none) — the bash single-quote trap.
    _live_remote_merge() {  # _live_remote_merge <payload.json>
        local f="$1" src kind repo ts title key
        local -a added=()
        [ -s "$f" ] || { LV_NEW=0; return 0; }
        while IFS="$GN_US" read -r src kind repo ts title; do
            case "$ts" in ''|*[!0-9]*) continue ;; esac   # skip a ts-less / epoch-0 (1970) row
            [ "$ts" -gt 0 ] || continue
            key="r:${src}:${kind}:${repo}:${ts}:${title}"
            [ -n "${LV_SEEN[$key]:-}" ] && continue
            LV_SEEN[$key]=1
            LV_FEED+=("${ts}${GN_US}${kind}${GN_US}${repo}${GN_US}${src}${GN_US}${title}${GN_US}${key}")
            added+=("$key")
        done < <(jq -r --arg us "$GN_US" '
            .events[]?
            | (.kind // (
                (.type | tostring) as $t
                | if   ($t | test("pull|Pull|Merge|merge|accept")) then "pr"
                  elif ($t | test("issue|Issue"))                  then "issue"
                  else "push" end)) as $kind
            | select($kind == "pr" or $kind == "issue")
            | [ (.source // "remote"), $kind,
                ((.repo // "?") | tostring | split("/") | last),
                (.ts // 0 | tostring),
                ((.title // "") | gsub($us; " ") | gsub("\\s+"; " ")) ]
            | join($us)' "$f" 2>/dev/null)
        _live_feed_sort ${added[@]+"${added[@]}"}
        return 0
    }
    # New activity arrived (local or remote): rebuild the cached feed + ticker, arm
    # the BREAKING flash, ring the bell. Shared by the poll, reap and refresh paths.
    _live_on_new() {
        _live_render_feed; _live_ticker_build; flash_until=$(( now + LV_FLASH )); printf '\a'
    }

    # ── A.I. desk: per-repo assistant tokens, polled ASYNC (the one jq path here) ──
    # Same async discipline as the remote poll: collect-usage-claude.sh (Claude Code
    # transcripts → token buckets) runs in a background job that aggregates per repo
    # and writes "repo<US>tokens" rows (busiest first) to a sentinel; the loop reaps
    # it on a later tick. Heavier than a git-log sweep (a transcript-tree parse), so
    # it gets its own slower cadence. Launched only while the module is enabled, so a
    # disabled channel forks no jq at all. Fail-soft: no jq / no transcripts / a read-
    # only index cache → an empty desk, never an error.
    _live_tokens_start() {  # _live_tokens_start <since-epoch> <until-epoch>
        [ "$LV_TOKENS" = 1 ] || return 1
        [ -n "$LV_TOK_PID" ] && return 1               # one collect in flight at a time
        command -v jq >/dev/null 2>&1 || return 1      # no jq → the desk simply stays quiet
        LV_TOK_PF="$(mktemp "${TMPDIR:-/tmp}/gt-live-tok.XXXXXX" 2>/dev/null)" || { LV_TOK_PF=""; return 1; }
        # The jq carries no apostrophe in any comment (there are none) — the bash
        # single-quote trap. Sum input+output per repo (matching the reader desk
        # "tokens" metric), drop zero-weight repos, order busiest first.
        ( bash "$GN_LIB_DIR/collect-usage-claude.sh" --since "$1" --until "$2" 2>/dev/null \
            | jq -r --arg us "$GN_US" '
                (.buckets // [])
                | group_by(.repo)
                | map({repo:.[0].repo, t:(map((.input // 0) + (.output // 0)) | add)})
                | map(select(.t > 0))
                | sort_by(-.t)
                | .[] | [(.repo // "?"), (.t | tostring)] | join($us)' \
            > "$LV_TOK_PF" 2>/dev/null ) &
        LV_TOK_PID=$!
        return 0
    }
    # Reap a finished async usage poll: load its rows, rebuild the cached strip, drop
    # the sentinel. rc 0 only when a job was actually reaped (so the caller knows the
    # panel changed); rc 1 while the job is still in flight.
    _live_tokens_reap() {
        [ -n "$LV_TOK_PID" ] || return 1
        kill -0 "$LV_TOK_PID" 2>/dev/null && return 1   # still running — try again next tick
        wait "$LV_TOK_PID" 2>/dev/null; LV_TOK_PID=""
        LV_TOK_ROWS=()
        [ -n "$LV_TOK_PF" ] && [ -s "$LV_TOK_PF" ] && mapfile -t LV_TOK_ROWS < "$LV_TOK_PF"
        [ -n "$LV_TOK_PF" ] && rm -f "$LV_TOK_PF" 2>/dev/null
        LV_TOK_PF=""; LV_TOK_READY=1
        _live_tokens_build
        return 0
    }
    # Humanize a token count to k/M/B into <outvar> (counts reach millions; an
    # out-var so the build loop pays no subshell per repo). Mirrors render-llm fmt_tok.
    _live_fmt_tok() {  # _live_fmt_tok <outvar> <n>
        local __ov="$1" n="${2:-0}"; case "$n" in ''|*[!0-9]*) n=0 ;; esac
        if   [ "$n" -lt 1000 ];       then printf -v "$__ov" '%s' "$n"
        elif [ "$n" -lt 1000000 ];    then printf -v "$__ov" '%d.%dk' "$((n/1000))" "$(((n%1000)/100))"
        elif [ "$n" -lt 1000000000 ]; then printf -v "$__ov" '%d.%dM' "$((n/1000000))" "$(((n%1000000)/100000))"
        else printf -v "$__ov" '%d.%dB' "$((n/1000000000))" "$(((n%1000000000)/100000000))"; fi
    }
    # Build the cached A.I. desk strip (LV_TOK_LINE) from LV_TOK_ROWS, fit to CW. Run
    # on reap/resize/toggle only — NEVER on the heartbeat (the frame reuses the cache).
    # Caps at 12 repos so a huge set never builds a giant string before the CW truncate.
    _live_tokens_build() {
        local body="" rep tok ftok rec i n="${#LV_TOK_ROWS[@]}" shown=0
        for (( i=0; i<n && shown<12; i++ )); do
            rec="${LV_TOK_ROWS[$i]}"
            rep="${rec%%"$GN_US"*}"; tok="${rec##*"$GN_US"}"
            case "$tok" in ''|*[!0-9]*) tok=0 ;; esac
            _live_fmt_tok ftok "$tok"
            if [ "$shown" -eq 0 ]; then body="${rep} ${ftok}"; else body="${body} · ${rep} ${ftok}"; fi
            shown=$(( shown + 1 ))
        done
        if [ "$n" -eq 0 ]; then
            # An honest empty-desk line. A missing jq is the one case "collecting…" would
            # lie about (the poll is a no-op without it), so name it — and make it actionable.
            if ! command -v jq >/dev/null 2>&1; then body="needs jq to read assistant usage — not found on PATH"
            elif [ "$LV_TOK_READY" = 1 ]; then body="no assistant activity in the window"
            else body="collecting assistant usage…"; fi
        fi
        local inner; inner=" A.I. · ${body} "
        inner="$(gn_truncate "$inner" "$CW")"
        local w sp g; gn_strwidth_v w "$inner"; g=$(( CW - w )); [ "$g" -lt 0 ] && g=0
        printf -v sp '%*s' "$g" ''
        LV_TOK_LINE="${GN_DIM}${inner}${sp}${GN_R}"
    }

    # A thin dim divider marking a calendar-day rollover in the feed. The 24h backfill
    # routinely spans midnight and the feed shows HH:MM only, so without it today 09:10
    # sits directly above yesterday 19:26 and reads as a backwards jump (the sort is
    # correct, by full epoch; only the day is invisible). Labels the day that BEGINS
    # below it. Centered, CW-wide, no pad (the frame loop pads) — same width discipline
    # as HRULE so the fixed-height frame never wraps.
    _live_dayrule() {  # _live_dayrule <epoch> -> a CW-wide centered day divider
        local lbl inner w rt left right
        lbl="$(gn_date "$1" '+%a · %b %d')"
        inner="  ${lbl}  "; inner="$(gn_truncate "$inner" "$CW")"
        gn_strwidth_v w "$inner"; rt=$(( CW - w )); [ "$rt" -lt 0 ] && rt=0
        left=$(( rt / 2 )); right=$(( rt - left ))
        printf '%s%s%s%s%s%s%s' \
            "$GN_FAINT" "$(hr "$left")" \
            "${GN_R}${GN_DIM}" "$inner" \
            "${GN_R}${GN_FAINT}" "$(hr "$right")" "$GN_R"
    }

    # ── render the feed list into LV_BUF (cached; rebuilt on poll/resize only) ──
    # Absolute commit time (HH:MM), so a cached line never goes stale between
    # polls — the per-tick repaint reuses LV_BUF untouched (no fork on the
    # heartbeat). The wall clock lives in the masthead instead.
    _live_render_feed() {
        LV_BUF=()
        local rec ts kind repo type text tm tcol glyph rp body bmax n=0 dt dkey prevday=""
        for rec in "${LV_FEED[@]}"; do
            [ "$n" -ge "$BODY" ] && break
            IFS="$GN_US" read -r ts kind repo type text key <<EOF
$rec
EOF
            # one date fork yields both the day key (rollover test) and the HH:MM label
            dt="$(gn_date "$ts" '+%Y-%m-%d %H:%M')"; dkey="${dt%% *}"; tm="${dt##* }"
            # day-rollover divider: the 24h backfill spans midnight, so mark where the
            # calendar day changes — newest-first, so this is the older day starting below.
            # Costs one feed row; skip when only one row is left so a divider never trails
            # alone with nothing under it.
            if [ -n "$prevday" ] && [ "$dkey" != "$prevday" ] && [ "$(( n + 1 ))" -lt "$BODY" ]; then
                LV_BUF+=("$(_live_dayrule "$ts")"); n=$(( n + 1 ))
            fi
            prevday="$dkey"
            case "$kind" in
                commit) tcol="$(gn_hl_type "$HLSTATE" "$type")"; glyph='▌' ;;
                pr)     tcol="$(gn_forge_col "$type")"; glyph='⬡' ;;   # type field carries the forge for remote items
                issue)  tcol="$(gn_forge_col "$type")"; glyph='◆' ;;
                *)      tcol="$GN_DIM"; glyph='▌' ;;
            esac
            rp="$(gn_pad "$repo" 14)"
            bmax=$(( CW - 23 )); [ "$bmax" -lt 1 ] && bmax=1   # 5 time +1 +1 glyph +1 +14 repo +1; floor 1 so a narrow CW shrinks the body, never wraps the row
            body="$(gn_truncate "$text" "$bmax")"
            LV_BUF+=("$(printf '%s%-5s%s %s%s%s %s%s%s %s%s%s' \
                "$GN_DIM" "$tm" "$GN_R" "$tcol" "$glyph" "$GN_R" \
                "$GN_B" "$rp" "$GN_R" "$GN_DIM" "$body" "$GN_R")")
            n=$(( n + 1 ))
        done
        LV_CHROME_DIRTY=1   # feed changed: the banner body + status wire-count need a rebuild
    }

    # Split the newest feed record into caller-named repo + title vars (the marquee and
    # the banner both headline the latest item) — the heredoc split lives in one place.
    _live_feed0_v() {  # _live_feed0_v <repovar> <titlevar>
        IFS="$GN_US" read -r _ _ "$1" _ "$2" _ <<EOF
${LV_FEED[0]}
EOF
    }

    # ── the marquee loop text: built from live data, cell-normalized once ──────
    _live_ticker_build() {
        local latest="" lr lt
        if [ "${#LV_FEED[@]}" -gt 0 ]; then
            _live_feed0_v lr lt
            latest="latest · ${lr} — ${lt}  +++  "
        fi
        LV_TICKLOOP="$(gn_anim_cells "+++  THE GIT TIMES · LIVE  +++  ${#LV_FEED[@]} on the wire  +++  ${latest}monitoring ${#LV_REPOS[@]} repos  ")"
    }

    # ── chrome cache: build the banner inner + status bar ONCE per state change ──
    # Both measure non-ASCII glyphs (·/◉), so doing it per tick forks od on every
    # heartbeat. _live_frame calls this only when LV_CHROME_DIRTY is set (a poll, pause,
    # resize or flash flip); the per-tick banner/status assembly just reuses the result.
    _live_chrome_build() {
        local lr lt body inner bw g
        # banner: tag + colour from the flash state, body from the latest feed item
        if [ "$LV_FLASHON" = 1 ]; then LV_BANNER_TAG="BREAKING"; LV_BANNER_COL="$GN_RED"
        else LV_BANNER_TAG="ON AIR"; LV_BANNER_COL="$GN_CYN"; fi
        if [ "${#LV_FEED[@]}" -gt 0 ]; then
            _live_feed0_v lr lt
            body="${lr} — ${lt}"
        else
            body="monitoring ${#LV_REPOS[@]} repos — waiting for commits"
        fi
        inner=" ${LV_BANNER_TAG} · ${body} "
        gn_truncate_v inner "$inner" "$CW"
        gn_strwidth_v bw "$inner"; g=$(( CW - bw )); [ "$g" -lt 0 ] && g=0
        LV_BANNER_INNER="$inner"; printf -v LV_BANNER_SP '%*s' "$g" ''
        # status bar — left state, right keys, gap-filled. Must fit CW: a line wider than
        # the column wraps and corrupts the fixed-height frame. The keys (right) are
        # functional, so they stay longest; the left detail degrades first (drop poll
        # cadence, then repo count), and only on a very narrow channel does the key-bar
        # compact and the left finally truncate.
        local state="LIVE"; [ "$paused" = 1 ] && state="PAUSED"
        local nrepo="${#LV_REPOS[@]}" wire="${#LV_FEED[@]}"
        local rstat="q quit · r refresh · p pause · m ticker · t a.i. " lstat lw rw sgap cand sg
        local -a lcand=(
            " ◉ ${state} · ${nrepo} repos · poll ${LV_INTERVAL}s · ${wire} on the wire"
            " ◉ ${state} · ${nrepo} repos · ${wire} on the wire"
            " ◉ ${state} · ${wire} on the wire"
            " ◉ ${state} · ${wire} wire"
        )
        gn_strwidth_v rw "$rstat"; lstat="${lcand[0]}"; lw=0
        for cand in "${lcand[@]}"; do
            lstat="$cand"; gn_strwidth_v lw "$cand"
            [ "$(( lw + rw + 1 ))" -le "$CW" ] && break
        done
        if [ "$(( lw + rw + 1 ))" -gt "$CW" ]; then   # narrowest tier still too wide
            rstat="q·r·p·m·t "; gn_strwidth_v rw "$rstat"
            if [ "$(( lw + rw + 1 ))" -gt "$CW" ]; then
                gn_truncate_v lstat "$lstat" "$(( CW - rw - 1 ))"; gn_strwidth_v lw "$lstat"
            fi
        fi
        sgap=$(( CW - lw - rw )); [ "$sgap" -lt 1 ] && sgap=1
        printf -v sg '%*s' "$sgap" ''
        LV_STATUS="${GN_DIM}${lstat}${sg}${rstat}${GN_R}"
    }

    # ── the banner: a full-width reverse strip. BREAKING (red) while flashing on new
    #    activity, otherwise a calm ON AIR line. Per-tick assembly from the cached inner +
    #    pad (built by _live_chrome_build) plus the blink — no measure, no fork. ──────────
    _live_banner_v() {  # _live_banner_v <outvar> — assigns the banner line (no pad, no newline)
        local __ov="$1" fill
        if [ "$LV_FLASHON" = 1 ]; then
            # pulse: blink the reverse strip on/off every ~0.5s (2 ticks) for urgency
            if [ $(( LV_TICKOFF / 2 % 2 )) -eq 0 ]; then fill="$REV$GN_B"; else fill="$GN_B"; fi
        else fill="$REV$GN_B"; fi
        if [ "$COLOR" = 1 ]; then
            printf -v "$__ov" '%s%s%s%s%s' "$fill" "$LV_BANNER_COL" "$LV_BANNER_INNER" "$LV_BANNER_SP" "$GN_R"
        else
            printf -v "$__ov" '%s%s' "$LV_BANNER_INNER" "$LV_BANNER_SP"
        fi
    }

    # ── one full frame, assembled into a single buffer, painted in one write ───
    # Alt screen, fixed height: home (\033[H) + a per-line \033[K overwrites the
    # previous frame with no flicker and no full clear (the clear only runs once on
    # resize). Exactly LINES rows; the last line carries no trailing newline so the
    # frame never scrolls. Per-tick dynamics are the clock, the rec-dot blink, the
    # banner flash colour and the marquee window — everything else is cached.
    # Fork-free invariant: this path (and gn_readkey_v after it) spawns NO subshell on
    # the heartbeat — clock/pads via printf -v, the banner via _live_banner_v, the
    # marquee via gn_marquee_win_v. Keep it that way; a $(hr …)/$(gn_truncate …) here
    # forks a process every tick. Use the _v helper (printf -v) instead.
    _live_frame() {
        local out clock s2 recdot rname i bann fon
        # chrome (banner inner + status bar) is cached; rebuild only when the flash state
        # flips (cheap arithmetic, no fork) or a poll/pause/resize marked it dirty.
        fon=0; [ "$now" -lt "$flash_until" ] && fon=1
        [ "$fon" != "$LV_FLASHON" ] && { LV_FLASHON="$fon"; LV_CHROME_DIRTY=1; }
        [ "$LV_CHROME_DIRTY" = 1 ] && { _live_chrome_build; LV_CHROME_DIRTY=0; }
        out=$'\033[H'
        # masthead — name left, blinking rec dot + wall clock right
        printf -v clock '%(%H:%M:%S)T' -1
        printf -v s2 '%(%S)T' -1
        if [ "$paused" = 1 ]; then recdot="${GN_FAINT}◉${GN_R}"   # frozen: steady grey dot
        elif [ "$COLOR" = 1 ] && [ $(( 10#$s2 % 2 )) -eq 0 ]; then recdot="${GN_RED}${GN_B}◉${GN_R}"
        else recdot="${GN_FAINT}◉${GN_R}"; fi
        rname="${recdot} ${GN_B}${clock}${GN_R}"   # right: blink dot + wall clock (fixed 10 cols)
        # wordmark + gap are cached fit-to-CW in _live_geometry; only the clock ticks here
        out+="${PADS}${LV_MAST_L}${LV_MAST_GAP}${rname}"$'\033[K\n'
        # rule
        out+="${PADS}${GN_FAINT}${HRULE}${GN_R}"$'\033[K\n'
        # banner
        _live_banner_v bann
        out+="${PADS}${bann}"$'\033[K\n'
        # feed body — cached LV_BUF, padded; blank-fill the rest of BODY
        for ((i=0;i<BODY;i++)); do
            if [ "$i" -lt "${#LV_BUF[@]}" ]; then out+="${PADS}${LV_BUF[$i]}"$'\033[K\n'
            else out+=$'\033[K\n'; fi
        done
        # rule
        out+="${PADS}${GN_FAINT}${HRULE}${GN_R}"$'\033[K\n'
        # A.I. desk strip — the cached per-repo token line (rebuilt only on reap/resize/
        # toggle), painted only while the module is on. Reuses the cache; no heartbeat fork.
        if [ "$LV_TOKENS" = 1 ]; then
            out+="${PADS}${LV_TOK_LINE}"$'\033[K\n'
        fi
        # marquee (lower third) — fork-free window of the looping ticker, painted only
        # while the ticker runs (m toggles it; off by default for a calmer channel).
        if [ "$LV_MARQUEE" = 1 ]; then
            local mseg; gn_marquee_win_v mseg "$LV_TICKLOOP" "$LV_TICKOFF" "$CW"
            out+="${PADS}${GN_DIM}${mseg}${GN_R}"$'\033[K\n'
        fi
        # status bar — cached by _live_chrome_build on state change; no trailing newline
        out+="${PADS}${LV_STATUS}"$'\033[K'
        printf '%s' "$out"
    }

    # ── terminal setup: alt screen + hide cursor + silence echo ────────────────
    # Cleanup mirrors reader.sh: reap any background job, restore termios + the
    # paper surface, show the cursor, LEAVE the alt screen (restoring the user's
    # prior terminal content) — at every exit path (trap + the normal end below).
    # The body is idempotent (every var ${..:-}-guarded) so running it twice is safe.
    trap '[ -n "${LV_REMOTE_PID:-}" ] && kill "$LV_REMOTE_PID" 2>/dev/null; [ -n "${LV_REMOTE_PF:-}" ] && rm -f "$LV_REMOTE_PF" 2>/dev/null; [ -n "${LV_TOK_PID:-}" ] && kill "$LV_TOK_PID" 2>/dev/null; [ -n "${LV_TOK_PF:-}" ] && rm -f "$LV_TOK_PF" 2>/dev/null; [ -n "${_stty_saved:-}" ] && stty "$_stty_saved" </dev/tty 2>/dev/null; gn_term_surface_reset; printf "\033[0m\033[?25h\033[?1049l"; exit 0' INT TERM HUP QUIT
    trap 'LV_RESIZE=1' WINCH
    printf '\033[?1049h\033[?25l'   # enter alternate screen, hide cursor
    [ -n "${GN_TERM_BG:-}" ] && gn_term_surface_apply   # paper/black surface themes (reset on exit)
    [ -t 0 ] && { _stty_saved="$(stty -g </dev/tty 2>/dev/null)"; stty -echo </dev/tty 2>/dev/null; }

    # ── init: discover, paint the channel, THEN backfill ───────────────────────
    printf -v now '%(%s)T' -1
    _live_discover
    # Paint an empty frame FIRST (the banner reads "monitoring N repos — waiting").
    # The lookback backfill below is a synchronous git-log sweep over every repo and can
    # take a moment on a large set; a blank alt screen while it runs reads as a hang, so
    # show the channel is up. The backfilled feed lands on the next loop pass.
    _live_geometry; _live_render_feed; _live_ticker_build
    [ "$LV_TOKENS" = 1 ] && _live_tokens_build   # seed the strip ("collecting…") before the first paint
    _live_frame
    [ "$SCOPE" != remote ] && _live_poll_local "$(( now - LV_LOOKBACK ))"
    last_local="$now"
    # First async remote poll sweeps the FULL lookback once (backfill); later restarts
    # only cover [last_remote, now], so the forge is never re-scanned wholesale.
    if [ "$SCOPE" != local ] && _live_remote_start "$(( now - LV_LOOKBACK ))" "$now"; then
        remote_backfill=1; last_remote="$now"   # advance only when the backfill poll actually launched
    fi
    # First A.I. desk poll covers the full lookback; later polls re-sweep the same
    # window (the collect-usage index makes the re-scan cheap), so the desk always
    # reflects the lookback, not just the gap since the last poll.
    if [ "$LV_TOKENS" = 1 ]; then
        # Advance last_tokens even if the start no-ops (no jq) so the cadence gate below
        # does not retry the jq probe every tick — it settles to one probe per interval.
        _live_tokens_start "$(( now - LV_LOOKBACK ))" "$now"; last_tokens="$now"
    fi

    # ── the broadcast loop ─────────────────────────────────────────────────────
    while :; do
        if [ "$LV_RESIZE" = 1 ]; then
            _live_geometry; _live_render_feed; _live_ticker_build
            [ "$LV_TOKENS" = 1 ] && _live_tokens_build   # CW changed: re-fit the A.I. strip
            LV_RESIZE=0
            printf '\033[2J'   # one full clear on (re)size; steady frames overwrite in place
        fi
        _live_frame
        gn_readkey_v key "$LV_TICK"
        case "$key" in
            ''|q|Q|ESC) break ;;
            r|R) # manual refresh: poll local now + kick a fresh remote poll
                 printf -v now '%(%s)T' -1
                 [ "$SCOPE" != remote ] && { _live_poll_local "$last_local"; last_local="$now"; [ "$LV_NEW" -gt 0 ] && _live_on_new; }
                 if [ "$SCOPE" != local ] && [ -z "$LV_REMOTE_PID" ]; then _live_remote_start "$last_remote" "$now" && last_remote="$now"; fi ;;   # incremental gap, not the full lookback
            TICK)
                printf -v now '%(%s)T' -1
                LV_TICKOFF=$(( LV_TICKOFF + 1 ))
                # remote: reap a finished async poll regardless of pause, so a job that
                # completes while frozen never zombies and its sentinel never leaks (the
                # merge lands in the feed list; rendering waits until live). The startup
                # backfill renders silently, like the local backfill — no flash or bell for
                # events up to a lookback old.
                if [ "$SCOPE" != local ]; then
                    local had_pid="$LV_REMOTE_PID"
                    if _live_remote_reap && [ "$paused" = 0 ]; then
                        if [ "$remote_backfill" = 1 ]; then _live_render_feed; _live_ticker_build
                        else _live_on_new; fi
                    fi
                    [ -n "$had_pid" ] && [ -z "$LV_REMOTE_PID" ] && remote_backfill=0
                fi
                # A.I. desk: reap a finished usage poll regardless of pause, so a job that
                # completes while frozen never zombies and its sentinel never leaks. The
                # rebuilt strip simply rides the next frame — no flash, no bell (token
                # activity is not "breaking"). The panel is independent of the feed freeze.
                [ "$LV_TOKENS" = 1 ] && _live_tokens_reap
                if [ "$paused" = 0 ]; then
                    # local commit poll on its cadence
                    if [ "$SCOPE" != remote ] && [ "$(( now - last_local ))" -ge "$LV_INTERVAL" ]; then
                        _live_poll_local "$last_local"; last_local="$now"
                        [ "$LV_NEW" -gt 0 ] && _live_on_new
                    fi
                    # remote: (re)start on its cadence (the reap above already ran)
                    if [ "$SCOPE" != local ] && [ -z "$LV_REMOTE_PID" ] && [ "$(( now - last_remote ))" -ge "$LV_REMOTE_INTERVAL" ]; then
                        # incremental: only the gap since the last poll start, not the full lookback
                        _live_remote_start "$last_remote" "$now" && last_remote="$now"
                    fi
                    # A.I. desk: re-poll the full lookback on its own (slower) cadence.
                    # last_tokens advances unconditionally — a no-op start (no jq) must not
                    # re-probe every tick, only once per interval.
                    if [ "$LV_TOKENS" = 1 ] && [ -z "$LV_TOK_PID" ] && [ "$(( now - last_tokens ))" -ge "$LV_TOKENS_INTERVAL" ]; then
                        _live_tokens_start "$(( now - LV_LOOKBACK ))" "$now"; last_tokens="$now"
                    fi
                fi ;;
            p|P) if [ "$paused" = 1 ]; then
                     # unpause: catch up the paused span now — poll local over [last_local, now]
                     # and kick a remote poll for the gap — so nothing committed while frozen is
                     # lost (the old re-anchor advanced the cadence WITHOUT polling, a permanent
                     # miss). dedup keeps the catch-up sweep idempotent.
                     paused=0; printf -v now '%(%s)T' -1
                     [ "$SCOPE" != remote ] && { _live_poll_local "$last_local"; last_local="$now"; [ "$LV_NEW" -gt 0 ] && _live_on_new; }
                     if [ "$SCOPE" != local ] && [ -z "$LV_REMOTE_PID" ]; then _live_remote_start "$last_remote" "$now" && last_remote="$now"; fi
                     _live_render_feed; _live_ticker_build   # reflect the catch-up + anything a paused reap merged
                 else
                     # freeze the feed (the clock keeps moving); clear the flash so the BREAKING
                     # pulse does not keep strobing over a frozen frame, and rebuild the chrome
                     # so the status bar flips to PAUSED.
                     paused=1; flash_until=0; LV_CHROME_DIRTY=1
                 fi ;;
            m|M) # toggle the lower-third ticker; the row count changes, so re-lay-out
                 if [ "$LV_MARQUEE" = 1 ]; then LV_MARQUEE=0; else LV_MARQUEE=1; fi
                 LV_RESIZE=1 ;;   # resize path recomputes geometry + full clear next pass
            t|T) # toggle the A.I. desk panel; the row count changes, so re-lay-out
                 if [ "$LV_TOKENS" = 1 ]; then LV_TOKENS=0
                 else
                     LV_TOKENS=1; _live_tokens_build   # seed the strip (shows cached rows, or "collecting…")
                     # kick a first poll now so the desk fills without waiting a full cadence
                     printf -v now '%(%s)T' -1
                     [ -z "$LV_TOK_PID" ] && { _live_tokens_start "$(( now - LV_LOOKBACK ))" "$now"; last_tokens="$now"; }
                 fi
                 LV_RESIZE=1 ;;   # resize path recomputes geometry + full clear next pass
            *) : ;;
        esac
    done

    # ── normal-exit cleanup (mirrors the trap) ─────────────────────────────────
    [ -n "${LV_REMOTE_PID:-}" ] && kill "$LV_REMOTE_PID" 2>/dev/null
    [ -n "${LV_REMOTE_PF:-}" ] && rm -f "$LV_REMOTE_PF" 2>/dev/null
    [ -n "${LV_TOK_PID:-}" ] && kill "$LV_TOK_PID" 2>/dev/null
    [ -n "${LV_TOK_PF:-}" ] && rm -f "$LV_TOK_PF" 2>/dev/null
    [ -n "${_stty_saved:-}" ] && stty "$_stty_saved" </dev/tty 2>/dev/null
    gn_term_surface_reset
    printf '\033[0m\033[?25h\033[?1049l'
}
