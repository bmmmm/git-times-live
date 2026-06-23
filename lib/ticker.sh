# shellcheck shell=bash
# git-times — the wire & the pulse (reader marquee content). Sourced by
# gittimes-lib.sh; never executed directly, no `set` flags (would leak to the
# caller). gn_anim_cells/gn_marquee_win are pure bash; gn_wire_text and
# gn_pulse_strip build the ticker/strip content from the snapshot via jq.

# Normalize marquee content to single-cell glyphs so a character is a terminal
# cell and plain ${str:off:len} slicing stays column-accurate at any offset.
# Printable ASCII passes; the handful of width-1 glyphs our own renderers use
# pass by allowlist; anything else (emoji, CJK — possibly double-width) becomes
# one space. Pure bash, no forks — runs once per content rebuild, not per tick.
gn_anim_cells() {  # gn_anim_cells <text>
    local s="$1" out="" i ch o
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        printf -v o '%d' "'$ch" 2>/dev/null || o=0
        [ "$o" -lt 0 ] && o=$(( o + 256 ))   # high-bit byte under a C locale
        if [ "$o" -ge 32 ] && [ "$o" -le 126 ]; then out+="$ch"
        else
            case "$ch" in
                ·|—|–|…|▸|│|✓|✗|↑|↓|▁|▂|▃|▄|▅|▆|▇|█) out+="$ch" ;;
                *) out+=' ' ;;
            esac
        fi
    done
    printf '%s' "$out"
}

# One window of an endlessly looping marquee: <loop> is cell-normalized content
# (gn_anim_cells), <offset> wraps in both directions, the window is <width> cells.
# The _v form assigns into <outvar> instead of printing — the per-tick repaint
# calls it 8×/s, and a `$(…)` there would fork a subshell on every heartbeat.
gn_marquee_win_v() {  # gn_marquee_win_v <outvar> <loop-text> <offset> <width>
    local __mv="$1" __s="$2" __off="$3" __w="$4" __n=${#2} __out
    if [ "$__n" -eq 0 ]; then printf -v "$__mv" '%*s' "$__w" ''; return; fi
    __off=$(( ((__off % __n) + __n) % __n ))
    __out="${__s:__off}"
    while [ "${#__out}" -lt "$__w" ]; do __out+="$__s"; done
    printf -v "$__mv" '%s' "${__out:0:__w}"
}
gn_marquee_win() {  # gn_marquee_win <loop-text> <offset> <width>
    local __mw; gn_marquee_win_v __mw "$@"; printf '%s' "$__mw"
}

# The wire — the news-ticker line, built from the snapshot once per (re)load:
# the lead, every desk repo with its commit count, the edition totals and the
# streak, joined wire-service style with +++ separators.
gn_wire_text() {  # gn_wire_text <snapshot.json>
    [ -f "${1:-}" ] || { printf 'THE GIT TIMES'; return; }
    jq -r '
        ([ (if .lead != null and .lead.repo != null
            then "LEAD · \(.lead.repo) — \(.lead.subject // "")" else empty end) ]
         + [ .repos[0:8][]? | "\(.repo) · \(.commits) commit\(if .commits == 1 then "" else "s" end)" ]
         + [ "\(.totals.commits // 0) commits in \(.totals.repos_touched // 0) repo\(if (.totals.repos_touched // 0) == 1 then "" else "s" end) · +\(.totals.insertions // 0) -\(.totals.deletions // 0)" ]
         + (if (.totals.streak_days // 0) >= 2
            then ["streak · \(.totals.streak_days) days running"] else [] end))
        | map(gsub("\\s+"; " ")) | join("  +++  ")' "$1" 2>/dev/null \
        || printf 'THE GIT TIMES'
}

# The pulse — the activity diagram as a strip: one cell per recorded day
# (▁▂▃▄▅▆▇█ scaled to the busiest day, · for a quiet one), month names embedded
# where the month turns. Renders the days the snapshot recorded (the dedicated
# heatmap pass carries the full year; the fallback carries active days only).
gn_pulse_strip() {  # gn_pulse_strip <snapshot.json>
    [ -f "${1:-}" ] || { printf ''; return; }
    jq -r '
        (.heatmap // []) as $d
        | if ($d | length) == 0 then "" else
            ([ $d[].count ] | max) as $mx0
            | (if $mx0 < 1 then 1 else $mx0 end) as $mx
            | ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"] as $mn
            | reduce $d[] as $e ({m:"", s:""};
                ($e.date[5:7]) as $mo
                | (if $mo != .m
                   then {m:$mo, s:(.s + " " + ($mn[(($mo | tonumber) - 1)] // "?") + " ")}
                   else . end)
                | .s += (($e.count // 0) as $c
                    | if $c <= 0 then "·"
                      else (((($c * 8 / $mx) | ceil) - 1) as $i0
                            | ($i0 | if . > 7 then 7 elif . < 0 then 0 else . end) as $i
                            | "▁▂▃▄▅▆▇█"[$i : $i + 1])
                      end))
            | .s
          end' "$1" 2>/dev/null || printf ''
}
