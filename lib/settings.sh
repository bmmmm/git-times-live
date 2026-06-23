# shellcheck shell=bash
# git-times — sticky settings (theme / highlight / headline / engine / model /
# anim / motion / outro / intro / ads). Sourced by gittimes-lib.sh; never executed
# directly, no `set` flags (would leak to the caller). Needs GIT_TIMES_HOME and
# the GIT_TIMES_* config baselines in scope — provided by the lib that sources this.

# ── sticky settings (theme / highlight / headline persist side-by-side) ───────
# The reader's live toggles write the chosen value to a small file at the press-
# archive root, beside the edition folders; one-shot views (print, the shell
# greeting) read it back so they inherit whatever you last used — without an env
# var or a flag. Writes are best-effort (|| true): a read-only cache must never
# break a render. One parametrized file/load/save set backs all three settings;
# only the resolve step — which validates the value and supplies each setting's
# own default — differs per setting.
gn_setting_file() { printf '%s/%s' "$GIT_TIMES_HOME" "$1"; }  # gn_setting_file <key>
gn_setting_load() {  # gn_setting_load <key> — echo the persisted value, or nothing
    # NOT a single && chain: read returns 1 on a file without a trailing newline
    # (hand-edited) even though it filled $t — chaining would silently drop the value.
    local f t=""; f="$(gn_setting_file "$1")"
    [ -f "$f" ] && IFS= read -r t < "$f" 2>/dev/null
    [ -n "$t" ] && printf '%s' "$t"
    return 0
}
gn_setting_save() {  # gn_setting_save <key> <value> — best-effort persist
    local f; f="$(gn_setting_file "$1")"
    mkdir -p "$(dirname "$f")" 2>/dev/null && printf '%s\n' "$2" > "$f" 2>/dev/null || true
}

# theme — the last active palette is sticky. Effective palette: an explicit flag
# wins, else the last active (persisted) theme, else the env/config baseline, else neon.
gn_theme_load() { gn_setting_load last-theme; }
gn_theme_save() { gn_setting_save last-theme "$1"; }  # gn_theme_save <theme>
gn_theme_resolve() {  # gn_theme_resolve [flag-theme]
    local flag="${1:-}" p
    [ -n "$flag" ] && { printf '%s' "$flag"; return; }
    p="$(gn_theme_load)"; [ -n "$p" ] && { printf '%s' "$p"; return; }
    printf '%s' "${GIT_TIMES_THEME:-neon}"
}

# highlight — the accent toggle (`h`: theme accent on story headings / type dots)
# is sticky. Only the literal on|off is ever stored. Effective on|off: flag wins,
# else the last toggle, else the env/config baseline, else on.
gn_hilite_load() { gn_setting_load last-highlight; }
gn_hilite_save() { gn_setting_save last-highlight "$1"; }  # gn_hilite_save <on|off>
gn_hilite_resolve() {  # gn_hilite_resolve [flag]
    local flag="${1:-}" p
    case "$flag" in on|off) printf '%s' "$flag"; return ;; esac
    p="$(gn_hilite_load)"; case "$p" in on|off) printf '%s' "$p"; return ;; esac
    case "${GIT_TIMES_HIGHLIGHT:-on}" in off) printf 'off' ;; *) printf 'on' ;; esac
}

# headline — the desk-heading style (`s` cycles band|kicker|card|stamp|off) is
# sticky. The legacy value `on` (the old double-height toggle) migrates to band.
# Effective style: flag > last > env > band.
gn_headline_load() { gn_setting_load last-headlines; }
gn_headline_save() { gn_setting_save last-headlines "$1"; }  # gn_headline_save <band|kicker|card|stamp|off>
gn_headline_resolve() {  # gn_headline_resolve [flag] — flag > last > env > band; on→band
    local flag="${1:-}" p env
    case "$flag" in band|kicker|card|stamp|off) printf '%s' "$flag"; return ;; on) printf 'band'; return ;; esac
    p="$(gn_headline_load)"
    case "$p" in band|kicker|card|stamp|off) printf '%s' "$p"; return ;; on) printf 'band'; return ;; esac
    env="${GIT_TIMES_HEADLINES:-band}"
    case "$env" in band|kicker|card|stamp|off) printf '%s' "$env" ;; *) printf 'band' ;; esac
}

# editorial engine — the reader's `e` toggle is sticky like the theme, so one-shot
# views (print, the shell greeting) inherit whatever engine you last switched to.
# Effective engine: an explicit --editorial flag wins, else the last toggle, else
# the env/config baseline, else template.
gn_engine_load() { gn_setting_load last-engine; }
gn_engine_save() { gn_setting_save last-engine "$1"; }   # gn_engine_save <engine>
gn_engine_resolve() {  # gn_engine_resolve [flag]
    local flag="${1:-}" p
    [ -n "$flag" ] && { printf '%s' "$flag"; return; }
    p="$(gn_engine_load)"; [ -n "$p" ] && { printf '%s' "$p"; return; }
    printf '%s' "${GIT_TIMES_EDITORIAL:-template}"
}

# editorial model — the live model the reader's `M` toggle last picked, sticky PER
# engine (omlx and ollama serve different model lists). Effective model for an engine:
# the sticky pick if any, else that engine's env/config default. Only the local
# server engines carry a switchable model; others return empty.
gn_model_load() { gn_setting_load "last-model-$1"; }            # gn_model_load <engine>
gn_model_save() { gn_setting_save "last-model-$1" "$2"; }       # gn_model_save <engine> <model>
gn_model_resolve() {  # gn_model_resolve <engine>
    local engine="$1" p; p="$(gn_model_load "$engine")"
    [ -n "$p" ] && { printf '%s' "$p"; return; }
    case "$engine" in
        omlx)          printf '%s' "$GIT_TIMES_OMLX_MODEL" ;;
        ollama)        printf '%s' "$GIT_TIMES_OLLAMA_MODEL" ;;
        openai)        printf '%s' "$GIT_TIMES_OPENAI_MODEL" ;;
        anthropic|api) printf '%s' "$GIT_TIMES_ANTHROPIC_MODEL" ;;
        claude)        printf '%s' "$GIT_TIMES_CLAUDE_MODEL" ;;
        codex)         printf '%s' "$GIT_TIMES_CODEX_MODEL" ;;
        *)             printf '' ;;
    esac
}

# ── reader animations — the wire (news ticker) & the pulse (activity strip) ──
# Sticky like the theme: the panel (`A`) persists "ticker=.. tickerdir=.. pulse=..
# pulsedir=.. tick=..", and that beats the env baseline (GIT_TIMES_ANIM turns both
# elements on; GIT_TIMES_TICKER/_PULSE and *_DIR override per element;
# GIT_TIMES_ANIM_TICK is the seconds-per-step heartbeat).
gn_anim_save() { gn_setting_save last-anim "$1"; }   # gn_anim_save <state-string>
gn_anim_load() { gn_setting_load last-anim; }
gn_anim_resolve() {
    local s; s="$(gn_anim_load)"
    if [ -z "$s" ]; then
        local m t p
        m="${GIT_TIMES_ANIM:-off}"
        t="${GIT_TIMES_TICKER:-$m}"; p="${GIT_TIMES_PULSE:-$m}"
        s="ticker=$t tickerdir=${GIT_TIMES_TICKER_DIR:-rtl} pulse=$p pulsedir=${GIT_TIMES_PULSE_DIR:-ltr} tick=${GIT_TIMES_ANIM_TICK:-0.12}"
    fi
    printf '%s' "$s"
}

# motion — the master gate over EVERYTHING that moves (ticker, pulse, outro, the
# press loader's jibber). "off" keeps every feature reachable but strips the time
# cost: the band hides, the outro is skipped, the loader shows a static banner.
# The per-element on/off picks underneath are preserved, so flipping the master
# back on restores exactly the moving page you had. Sticky like the theme.
gn_motion_load() { gn_setting_load last-motion; }
gn_motion_save() { gn_setting_save last-motion "$1"; }  # gn_motion_save <on|off>
gn_motion_resolve() {  # gn_motion_resolve [flag] — flag > last > env > on
    local flag="${1:-}" p
    case "$flag" in on|off) printf '%s' "$flag"; return ;; esac
    p="$(gn_motion_load)"; case "$p" in on|off) printf '%s' "$p"; return ;; esac
    case "${GIT_TIMES_MOTION:-on}" in off) printf 'off' ;; *) printf 'on' ;; esac
}

# outro — the closing animation the paper leaves with when you quit the reader
# from the front page (lib/outro.sh). One of roll|crumple|fold|fade|off; sticky
# like the theme so the settings panel's pick survives the session.
gn_outro_load() { gn_setting_load last-outro; }
gn_outro_save() { gn_setting_save last-outro "$1"; }  # gn_outro_save <style>
gn_outro_resolve() {  # gn_outro_resolve [flag] — flag > last > env > roll
    local flag="${1:-}" p env
    case "$flag" in roll|crumple|fold|fade|off) printf '%s' "$flag"; return ;; esac
    p="$(gn_outro_load)"
    case "$p" in roll|crumple|fold|fade|off) printf '%s' "$p"; return ;; esac
    env="${GIT_TIMES_OUTRO:-roll}"
    case "$env" in roll|crumple|fold|fade|off) printf '%s' "$env" ;; *) printf 'roll' ;; esac
}

# intro — the opening animation: the full-screen press loader that runs while a
# collect blocks (lib/loader.sh). One of press|teletype|linotype|darkroom|off;
# sticky like the outro so the settings panel's pick survives the session. The
# motion master still gates it — motion off shows the static banner regardless.
gn_intro_load() { gn_setting_load last-intro; }
gn_intro_save() { gn_setting_save last-intro "$1"; }  # gn_intro_save <style>
gn_intro_resolve() {  # gn_intro_resolve — last > env > press
    local p env
    p="$(gn_intro_load)"
    case "$p" in press|teletype|linotype|darkroom|off) printf '%s' "$p"; return ;; esac
    env="${GIT_TIMES_INTRO:-press}"
    case "$env" in press|teletype|linotype|darkroom|off) printf '%s' "$env" ;; *) printf 'press' ;; esac
}

# compose — the writing-desk animation that runs while `F` drafts the edition
# feature (lib/loader.sh, gn_compose). One of galley|sweep|quill|write|off; sticky
# like the intro, picked in the settings panel `w` (the editorial section, shown
# only for LLM engines). The motion master still gates it — motion off shows the
# static desk regardless. It only ever runs on a draft, so it is resolved lazily on
# `F`, never on the front page; default is galley (the most visual, lightest face).
gn_compose_load() { gn_setting_load last-compose; }
gn_compose_save() { gn_setting_save last-compose "$1"; }  # gn_compose_save <style>
gn_compose_resolve() {  # gn_compose_resolve — last > env > galley
    local p env
    p="$(gn_compose_load)"
    case "$p" in galley|sweep|quill|write|off) printf '%s' "$p"; return ;; esac
    env="${GIT_TIMES_COMPOSE:-galley}"
    case "$env" in galley|sweep|quill|write|off) printf '%s' "$env" ;; *) printf 'galley' ;; esac
}

# ads — the house-ad mute (settings panel) is sticky. Precedence is deliberately
# env > last > on, INVERTED vs the theme: there is no --ads flag, so the env var
# is the explicit per-invocation override (offline tests and byte-diff renders pin
# GIT_TIMES_ADS=off and must win over whatever the reader last toggled). `random`
# stays env-only — the panel toggles on|off.
gn_ads_load() { gn_setting_load last-ads; }
gn_ads_save() { gn_setting_save last-ads "$1"; }  # gn_ads_save <on|off>
gn_ads_resolve() {  # gn_ads_resolve — env > last > on
    case "${GIT_TIMES_ADS:-}" in on|off|random) printf '%s' "$GIT_TIMES_ADS"; return ;; esac
    local p; p="$(gn_ads_load)"
    case "$p" in on|off) printf '%s' "$p"; return ;; esac
    printf 'on'
}

# time zone — the display zone every rendered date, the weekday grid and the clock use.
# The reader settings panel (`C` -> time zone) picks from GIT_TIMES_TZ_MENU and persists
# here, like the theme. Precedence: flag > last (this file) > env/config GIT_TIMES_TZ >
# the machine zone. "system" is an explicit pick of the machine zone that stops the
# search, so it overrides a GIT_TIMES_TZ set in .env. An unknown/unloadable zone is
# skipped — a typo falls through to the next level instead of breaking every date.
gn_tz_load() { gn_setting_load last-tz; }
gn_tz_save() { gn_setting_save last-tz "$1"; }   # gn_tz_save <zone|system>
gn_tz_valid() {  # gn_tz_valid <zone> — 0 if a loadable IANA zone file exists
    [ -n "${1:-}" ] && [ -f "${TZDIR:-/usr/share/zoneinfo}/$1" ]
}
gn_tz_resolve() {  # gn_tz_resolve [flag] — the effective zone, or empty for the machine zone
    local flag="${1:-}" p
    case "$flag" in system) printf ''; return ;; esac
    gn_tz_valid "$flag" && { printf '%s' "$flag"; return; }
    p="$(gn_tz_load)"
    case "$p" in system) printf ''; return ;; esac
    gn_tz_valid "$p" && { printf '%s' "$p"; return; }
    case "${GIT_TIMES_TZ:-}" in system) printf ''; return ;; esac
    gn_tz_valid "${GIT_TIMES_TZ:-}" && { printf '%s' "$GIT_TIMES_TZ"; return; }
    printf ''
}
# Apply a resolved zone to the live environment. A non-empty zone exports TZ; an empty one
# (the "system" pick / nothing configured) restores the zone the process started in —
# re-exported if it was set, unset otherwise — so System truly reverts to the machine
# clock. Reads GN_TZ_AMBIENT / GN_TZ_AMBIENT_SET, captured once by gittimes-lib.sh.
gn_tz_apply() {  # gn_tz_apply <zone|"">
    if [ -n "${1:-}" ]; then export TZ="$1"
    elif [ "${GN_TZ_AMBIENT_SET:-0}" = 1 ]; then export TZ="${GN_TZ_AMBIENT:-}"
    else unset TZ; fi
}
