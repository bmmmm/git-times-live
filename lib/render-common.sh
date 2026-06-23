# shellcheck shell=bash
# git-times — shared render & reader-line helpers: readability formatters
# (gn_human/gn_ago/gn_spark/gn_bar2/gn_meter), render line helpers (hr,
# gn_width, section, gn_nameplate), the footer wrap/paint pair, gn_readkey,
# the story-label map and the highlight colour pickers. Sourced by
# gittimes-lib.sh; never executed directly, no `set` flags (would leak to the
# caller). Needs GN_* (gn_color_init), gn_strwidth/gn_term_cols (layout.sh)
# and GIT_TIMES_MAX_WIDTH in scope; section/gn_nameplate read the caller's
# IND/WIDTH globals — bash dynamic scoping, the house pattern.

# ── readability helpers (feed renderer) ──────────────────────────────────────
# Humanize an integer for compact display: 137→"137", 4201→"4.2k", 10953→"10.9k".
gn_human() {  # gn_human <n>
    local n="${1:-0}"
    [ "$n" -ge 0 ] 2>/dev/null || n=0
    if   [ "$n" -lt 1000 ]   2>/dev/null; then printf '%s' "$n"
    elif [ "$n" -lt 100000 ] 2>/dev/null; then printf '%s.%sk' "$((n/1000))" "$(((n%1000)/100))"
    else printf '%sk' "$((n/1000))"; fi
}

# Relative time from an epoch to a reference "now": "now", "5m", "2h", "3d".
gn_ago() {  # gn_ago <ts> <now>
    local ts="${1:-0}" now="${2:-0}" d
    d=$(( now - ts )); [ "$d" -lt 0 ] && d=0
    if   [ "$d" -lt 60 ]    ; then printf 'now'
    elif [ "$d" -lt 3600 ]  ; then printf '%dm' "$(( d/60 ))"
    elif [ "$d" -lt 86400 ] ; then printf '%dh' "$(( d/3600 ))"
    else printf '%dd' "$(( d/86400 ))"; fi
}

# Unicode sparkline from integer args: gn_spark 0 2 5 9 1 → ▁▂▅█▁
gn_spark() {  # gn_spark <n1> <n2> ...
    local lv=(▁ ▂ ▃ ▄ ▅ ▆ ▇ █) max=0 n out="" idx
    for n in "$@"; do [ "$n" -gt "$max" ] 2>/dev/null && max="$n"; done
    [ "$max" -lt 1 ] && max=1
    for n in "$@"; do
        idx=$(( n*7/max )); [ "$idx" -lt 0 ] && idx=0; [ "$idx" -gt 7 ] && idx=7
        out="${out}${lv[$idx]}"
    done
    printf '%s' "$out"
}

# A filled/empty proportion bar: gn_bar2 <val> <max> <width> → ▰▰▰▱▱
gn_bar2() {  # gn_bar2 <val> <max> <width>
    local v="${1:-0}" m="${2:-1}" w="${3:-5}" f i out=""
    [ "$m" -lt 1 ] 2>/dev/null && m=1
    f=$(( v*w/m )); [ "$f" -lt 0 ] && f=0; [ "$f" -gt "$w" ] && f="$w"
    [ "$v" -gt 0 ] 2>/dev/null && [ "$f" -lt 1 ] && f=1
    for ((i=0;i<w;i++)); do [ "$i" -lt "$f" ] && out="${out}▰" || out="${out}▱"; done
    printf '%s' "$out"
}

# A percent meter: gn_meter <pct> <width> → ███░░░░░░░  (relies on GN_* colors)
gn_meter() {  # gn_meter <pct> <width>
    local p="${1:-0}" w="${2:-10}" f i out=""
    f=$(( p*w/100 )); [ "$f" -lt 0 ] && f=0; [ "$f" -gt "$w" ] && f="$w"
    for ((i=0;i<w;i++)); do [ "$i" -lt "$f" ] && out="${out}█" || out="${out}░"; done
    printf '%s' "$out"
}

# The shared shade rule for the · ░ ▒ ▓ █ ramp: map <count> against a <peak> to a level
# 0..4, written into <outvar> (printf -v, so no $() fork in the per-cell loops that call
# this). Level 0 is n<=0 (caller picks the blank glyph); any n>0 floors to 1 so a single
# commit never vanishes into the empty dot. Ceiling division, the canonical form — the
# heatmap calendar keeps an inline copy of this same expression for its hot 7xN cell loop;
# the trend-graph strips call here, so both shade identically and cannot drift in rounding
# (the graph strip used round-half-up before, one level off the calendar on some counts).
gn_shade_level() {  # gn_shade_level <outvar> <count> <peak>
    local __lv n="${2:-0}" mx="${3:-1}"
    if [ "$n" -le 0 ] 2>/dev/null; then printf -v "$1" '%s' 0; return; fi
    [ "$mx" -lt 1 ] 2>/dev/null && mx=1
    __lv=$(( (n*4 + mx - 1) / mx )); [ "$__lv" -lt 1 ] && __lv=1; [ "$__lv" -gt 4 ] && __lv=4
    printf -v "$1" '%s' "$__lv"
}

# ── render line helpers (shared by the front page, story and activity map) ────
# A run of <n> copies of <ch> (default the box rule ─): margins, fills, dividers.
# Clamps a negative count to 0.
hr() { local n="$1" ch="${2:-─}" i s=""; [ "$n" -lt 0 ] && n=0; for ((i=0;i<n;i++)); do s="$s$ch"; done; printf '%s' "$s"; }

# Forge identity — display name, two-letter tag and accent colour for a source
# id (magenta Forgejo, blue GitHub, yellow GitLab; cyan for anything else). Shared
# by the paper REMOTE DESK and the live broadcast wire so the two never drift.
gn_forge_name() { case "$1" in forgejo) printf Forgejo;; github) printf GitHub;; gitlab) printf GitLab;; *) printf '%s' "${1^}";; esac; }
gn_forge_tag()  { case "$1" in forgejo) printf FJ;; github) printf GH;; gitlab) printf GL;; *) printf '%s' "$(printf '%s' "${1:0:2}" | tr '[:lower:]' '[:upper:]')";; esac; }
gn_forge_col()  { case "$1" in forgejo) printf '%s' "$GN_MAG";; github) printf '%s' "$GN_BLU";; gitlab) printf '%s' "$GN_YEL";; *) printf '%s' "$GN_CYN";; esac; }

# Resolve the content column: explicit width if positive, else fit the terminal,
# clamped to [62, GIT_TIMES_MAX_WIDTH]. Non-numeric input falls back to auto-fit
# (rather than crashing the arithmetic that follows under set -u).
gn_width() {  # gn_width <requested>
    local w="${1:-0}"
    case "$w" in ''|*[!0-9]*) w=0 ;; esac
    [ "$w" -le 0 ] && w="$(gn_term_cols)"
    [ "$w" -gt "$GIT_TIMES_MAX_WIDTH" ] && w="$GIT_TIMES_MAX_WIDTH"
    [ "$w" -lt 62 ] && w=62
    printf '%s' "$w"
}

# A desk divider — "── LABEL ─────────── right" — reading the caller's IND/WIDTH
# globals. Accent defaults to cyan; the rules stay faint so they frame without
# competing with the headlines.
section() {  # section <label> [right] [accent]
    local lbl="$1" right="${2:-}" accent="${3:-$GN_CYN}" fill
    # gn_strwidth, not ${#…}: the right label often carries · (multibyte) and a
    # byte count would shorten the rule under a C locale.
    if [ -n "$right" ]; then
        fill=$(( WIDTH - IND - 5 - $(gn_strwidth "$lbl") - $(gn_strwidth "$right") )); [ "$fill" -lt 1 ] && fill=1
        printf '%s%s%s %s%s%s %s %s%s%s\n' \
            "$(hr "$IND" ' ')" "$GN_FAINT" "$(hr 2 '─')" "$GN_R$GN_B$accent" "$lbl" \
            "$GN_R$GN_FAINT" "$(hr "$fill" '─')" "$GN_DIM" "$right" "$GN_R"
    else
        fill=$(( WIDTH - IND - 4 - $(gn_strwidth "$lbl") )); [ "$fill" -lt 1 ] && fill=1
        printf '%s%s%s %s%s%s %s%s\n' \
            "$(hr "$IND" ' ')" "$GN_FAINT" "$(hr 2 '─')" "$GN_R$GN_B$accent" "$lbl" \
            "$GN_R$GN_FAINT" "$(hr "$fill" '─')" "$GN_R"
    fi
}

# The centered "T H E  G I T  T I M E S" nameplate, ━-ruled to the content WIDTH —
# the page header for the story and activity-map views. (The front page draws its
# own ╾╼-capped variant.) Reads the caller's WIDTH global, like section().
gn_nameplate() {
    local mast="T H E   G I T   T I M E S" padw lpad rpad
    padw=$(( WIDTH - ${#mast} - 2 )); [ "$padw" -lt 2 ] && padw=2
    lpad=$(( padw / 2 )); rpad=$(( padw - lpad ))
    printf '%s%s %s%s%s %s%s\n' \
        "$GN_FAINT" "$(hr "$lpad" '━')" "$GN_R$GN_B$GN_CYN" "$mast" "$GN_R$GN_FAINT" "$(hr "$rpad" '━')" "$GN_R"
}

# The centred dim subline under a nameplate ("ACTIVITY MAP · <date> · Edition #N").
# Width via gn_strwidth — the · separators are multibyte, a ${#…} byte count would
# off-centre it under a C locale. Reads the caller's WIDTH, like gn_nameplate.
gn_subline() {  # gn_subline <text>
    local lp=$(( (WIDTH - $(gn_strwidth "$1")) / 2 )); [ "$lp" -lt 0 ] && lp=0
    printf '%s%s%s%s\n' "$(hr "$lp" ' ')" "$GN_DIM" "$1" "$GN_R"
}

# A formatted date with %e padding normalised: %e left-pads single digits with a
# space, which reads as a double gap mid-string and a stray indent at the start.
# One helper instead of the three idioms that grew per renderer (| tr -s, | sed,
# unquoted echo).
gn_datefmt() {  # gn_datefmt <epoch> <+fmt>
    local s; s="$(gn_date "$1" "$2" | tr -s ' ')"; printf '%s' "${s# }"
}
# The house edition date ("Tue 11 Jun 2024") for sublines and colophons.
gn_datestr() { gn_datefmt "$1" '+%a %e %b %Y'; }

# The end-of-story mark, centred under a faint rule. In the reader these pages are
# scroll buffers with no scrollbar — without an unmistakable bottom, a chart folded
# at the viewport edge reads as "the last lines are missing", not "keep scrolling".
gn_endmark() {
    local endmark="— 30 —"
    local lp=$(( (WIDTH - $(gn_strwidth "$endmark")) / 2 )); [ "$lp" -lt 0 ] && lp=0
    printf '%s%s%s\n' "$GN_FAINT" "$(hr "$WIDTH" '─')" "$GN_R"
    printf '%s%s%s%s\n' "$(hr "$lp" ' ')" "$GN_FAINT" "$endmark" "$GN_R"
}

# Guard a renderer's snapshot argument: must exist and parse. The corruption check
# runs up front so a truncated cache fails with ONE actionable line instead of a
# jq parse error per read — straight into the .zshrc greeting on each shell open.
gn_require_snapshot() {  # gn_require_snapshot <path>
    [ -n "${1:-}" ] && [ -f "$1" ] || { printf 'git-times: no snapshot to render.\n' >&2; exit 1; }
    # Parse AND shape in one pass: a valid-JSON-but-wrong-shape cache (a bare [], a
    # wrong-typed field from a manual edit or external overwrite) would pass a plain
    # `jq -e .` and then spray raw "Cannot index array with string" per section while
    # still printing a partial page — instead of this one actionable line. aggregate.sh
    # always writes an object with a meta block, so a real snapshot passes.
    jq -e 'type=="object" and has("meta")' "$1" >/dev/null 2>&1 || { printf 'git-times: edition cache is unreadable (corrupt) — run: git-times refresh\n' >&2; exit 1; }
}

# Noon of the epoch's local calendar day — the DST-safe day anchor (midnight +
# fixed-86400 stepping drifts an hour across a transition and can cross a day
# boundary; noon ± a couple of DST hours never does). One gn_date fork, not three.
gn_noon_of() {  # gn_noon_of <epoch>
    local e="$1" h m s
    read -r h m s <<EOF
$(gn_date "$e" '+%H %M %S')
EOF
    printf '%s' "$(( e - (10#$h*3600 + 10#$m*60 + 10#$s) + 43200 ))"
}

# Fill the caller's CNT[date]=count map from the snapshot's heatmap pass — the
# honest per-day source (.commits is capped by GIT_TIMES_MAX_COMMITS and would
# show busy early days as falsely quiet). With "fallback", a heatmap-less
# snapshot groups the carried commits by day instead. Caller declares CNT.
gn_load_daycount() {  # gn_load_daycount <snapshot> [fallback]
    local d n
    while IFS=$'\t' read -r d n; do [ -n "$d" ] && CNT["$d"]="$n"; done < <(
        jq -r '.heatmap[]? | "\(.date)\t\(.count)"' "$1" 2>/dev/null)
    if [ "${2:-}" = fallback ] && [ "${#CNT[@]}" -eq 0 ]; then
        while IFS=$'\t' read -r d n; do [ -n "$d" ] && CNT["$d"]="$n"; done < <(
            jq -r '(.commits // []) | group_by(.date)[] | "\(.[0].date)\t\(length)"' "$1" 2>/dev/null)
    fi
    return 0
}

# The trend-graph window: the last <span> days ending at <huntil>, clamped to the
# data actually on hand (<hsince>..<huntil>). Noon-anchors both ends — DST-safe, the
# same anchor gn_noon_of gives (midnight + fixed 86400 steps drifts an hour across a
# transition and can cross a day boundary; noon never does). Echoes
# "<day0>\t<dayN>\t<ndays>": the two noon epochs plus the clamped day count.
# render-graph.sh and the reader repo picker BOTH derive their window here, off the
# same heatmap_since/heatmap_until, so the picker pre-tick set equals what is on
# screen and a span switch keeps them in agreement — a manual recompute on either
# side would drift (the picker once omitted the avail clamp). Caller resolves the two
# bounds with identical fallbacks: heatmap_until // until // generated_at, heatmap_since // since.
gn_graph_window() {  # gn_graph_window <heatmap_since> <heatmap_until> <span>
    local hs="$1" hu="$2" span="$3" dn d0a av nd d0
    [ "$hu" -ge "$hs" ] 2>/dev/null || hu="$hs"
    dn="$(gn_noon_of "$hu")"; d0a="$(gn_noon_of "$hs")"
    av=$(( (dn - d0a + 43200) / 86400 + 1 )); [ "$av" -lt 1 ] && av=1
    nd="$span"; [ "$nd" -gt "$av" ] && nd="$av"; [ "$nd" -lt 1 ] && nd=1
    d0=$(( dn - (nd - 1) * 86400 ))
    printf '%s\t%s\t%s\n' "$d0" "$dn" "$nd"
}

# Word-wrap footer hints across as many lines as the column needs, so every
# shortcut stays visible — no elision. Segments are kept whole and joined by
# " · ". Two passes: a greedy pass finds the minimum row count for <avail>
# columns, then the segments are re-packed so the rows come out near-equal in
# width (newspaper folio look). Plain greedy filled row 1 to the brim and left
# the last row nearly empty — unreadable as a key bar. Width via gn_strwidth,
# so it is locale- and glyph-safe. Echoes one line per output row (the caller
# reserves that many footer rows in the frame).
gn_footer_wrap() {  # gn_footer_wrap <avail> <seg>...
    local avail="$1"; shift
    local -a S=("$@") W=()
    local k=$# i w total=0 c=0 c2 n=1
    for ((i=0; i<k; i++)); do gn_strwidth_v w "${S[i]}"; W[i]=$w; total=$(( total + w )); done   # out-var form: this runs per keypress for ~18 segments — the $() subshell per segment is the footer-paint hot spot
    [ "$k" -gt 1 ] && total=$(( total + 3*(k-1) ))      # " · " between segments
    # pass 1: minimum row count under <avail> (greedy fill)
    for ((i=0; i<k; i++)); do
        if [ "$c" -eq 0 ]; then c=${W[i]}
        else
            c2=$(( c + 3 + W[i] ))
            if [ "$c2" -gt "$avail" ]; then n=$(( n + 1 )); c=${W[i]}; else c=$c2; fi
        fi
    done
    # pass 2: re-pack into the same row count toward a fair share per row (ceil of
    # what remains / rows left, recomputed at every cut). A segment that crosses
    # the share goes to whichever side leaves the row closer to it; <avail> is a
    # hard cap. _cut flushes the row and re-derives the share for the rest.
    local rows_left=$n rem=$total target line="" out=""
    _cut() {
        out+="$line"$'\n'; rem=$(( rem - c - 3 ))
        [ "$rows_left" -gt 1 ] && rows_left=$(( rows_left - 1 ))
        target=$(( (rem + rows_left - 1) / rows_left )); [ "$target" -gt "$avail" ] && target=$avail
        line=""; c=0
    }
    target=$(( (rem + rows_left - 1) / rows_left )); [ "$target" -gt "$avail" ] && target=$avail
    c=0
    for ((i=0; i<k; i++)); do
        if [ -z "$line" ]; then line="${S[i]}"; c=${W[i]}
        else
            c2=$(( c + 3 + W[i] ))
            if [ "$c2" -gt "$avail" ] || { [ "$rows_left" -gt 1 ] && [ "$c2" -gt "$target" ] \
                 && [ $(( c2 - target )) -gt $(( target - c )) ]; }; then
                _cut; line="${S[i]}"; c=${W[i]}      # overshoot beats undershoot → next row
            else
                line="$line · ${S[i]}"; c=$c2
            fi
        fi
        # row reached its share (and segments + rows remain) → cut after this segment
        if [ "$rows_left" -gt 1 ] && [ $(( i + 1 )) -lt "$k" ] && [ "$c" -ge "$target" ]; then _cut; fi
    done
    unset -f _cut
    printf '%s%s\n' "$out" "$line"
}

# Paint a composed footer row: brighten each hint's key — its first whitespace token,
# the actual keystroke ("r", "q", "↑↓", "⏎") — and dim the label, with faint
# separators. Operates on the already-wrapped *plain* line, so the wrap math
# (gn_strwidth) never sees colour codes. Key = first token by the footer convention
# "<key> <label>". With colour off the GN_* vars are empty, so the output is
# byte-identical to the plain input.
gn_footer_paint() {  # gn_footer_paint <wrapped-line>
    local line="$1" seg key rest out="" first=1
    while [ -n "$line" ]; do
        seg="${line%% · *}"
        if [ "$seg" = "$line" ]; then line=""; else line="${line#* · }"; fi
        key="${seg%% *}"; rest="${seg#"$key"}"          # rest keeps its leading space
        [ "$first" = 1 ] && first=0 || out+="${GN_FAINT} · ${GN_R}"
        out+="${GN_B}${GN_CYN}${key}${GN_R}${GN_DIM}${rest}${GN_R}"
    done
    printf '%s' "$out"
}

# Read one logical keypress (for the interactive reader). Decodes arrow keys and
# Enter/Esc into stable tokens so the loop never has to juggle escape bytes:
#   UP DOWN LEFT RIGHT · ENTER · ESC · SPACE · or the literal char ("j", "q", …).
# A lone Esc is told apart from an arrow sequence by a tiny read timeout, so it
# resolves instantly without swallowing the next key. Empty on EOF (→ treat as quit).
# With an optional timeout (seconds) the read returns TICK when no key arrives in
# time — the animation heartbeat: the reader ticks only while something animates,
# and a blocking read (no argument) stays the zero-CPU default. A timed-out read
# exits >128; anything else non-zero is still EOF (→ empty → quit), so a piped
# key script never hangs the loop when its input runs dry.
gn_readkey_v() {  # gn_readkey_v <outvar> [timeout-secs] — assigns the key label; no subshell.
    # The _v form reads in the CALLER scope (read -t in a $() subshell wastes the fork on
    # every heartbeat — the live tick loop calls this ~4-8x/s). gn_readkey is the $()-form.
    local __ov="$1" __k __seq __c __rc
    if [ -n "${2:-}" ]; then
        IFS= read -rsn1 -t "$2" __k; __rc=$?
        if [ "$__rc" -ne 0 ]; then
            if [ "$__rc" -gt 128 ]; then printf -v "$__ov" 'TICK'; else printf -v "$__ov" '%s' ''; fi
            return
        fi
    else
        IFS= read -rsn1 __k || { printf -v "$__ov" '%s' ''; return; }
    fi
    case "$__k" in
        ''|$'\n'|$'\r') printf -v "$__ov" 'ENTER' ;;
        ' ')            printf -v "$__ov" 'SPACE' ;;
        $'\e')
            # A CSI/SS3 escape sequence: ESC, then '[' or 'O', then optional digits/';'
            # and a final letter or '~'. Read it one byte at a time with a tolerant
            # timeout — the old 0.02s window mis-read arrows as a bare ESC (quit) on slow
            # SSH links — and stop at the final byte, so no trailing byte (e.g. the '~' of
            # \e[5~ from Home/End/PageUp) leaks into the next key. A lone ESC stays ESC.
            __seq=""
            IFS= read -rsn1 -t 0.4 __c 2>/dev/null && __seq="$__c"
            case "$__seq" in
                '['|O) while IFS= read -rsn1 -t 0.4 __c 2>/dev/null; do
                           __seq="$__seq$__c"; case "$__c" in [A-Za-z~]) break ;; esac
                       done ;;
            esac
            case "$__seq" in
                '[A'|OA) printf -v "$__ov" 'UP' ;;    '[B'|OB) printf -v "$__ov" 'DOWN' ;;
                '[C'|OC) printf -v "$__ov" 'RIGHT' ;; '[D'|OD) printf -v "$__ov" 'LEFT' ;;
                '['*|O*) printf -v "$__ov" 'IGN' ;;   # other CSI/SS3 key (Home/End/PgUp/F-keys) — fully consumed, ignored
                *)       printf -v "$__ov" 'ESC' ;;    # lone ESC, or ESC+other (Alt-<key>)
            esac ;;
        *)              printf -v "$__ov" '%s' "$__k" ;;
    esac
}
gn_readkey() {  # gn_readkey [timeout-secs] — the $()-friendly form; echoes the key label
    local __rk; gn_readkey_v __rk "${1:-}"; printf '%s' "$__rk"
}

# Quick-jump labels for the interactive reader's stories: a, c, d, … but skipping
# EVERY letter the front page binds to a command, so a label keypress can never be
# shadowed by a command (the front loop matches its command keys before the jump
# fall-through). One reserved set drives both directions — gn_story_label (index →
# letter, what the renderer prints) and gn_label_index (letter → index, what the key
# loop resolves) — so the printed label and the key that opens it can't drift apart.
# Reserved: b=page-back · g=go-to-top · w=window cycle · z=surface, plus the older
# e/f/h/j/k/l/m/q/r/s/t commands. n/o/p stay free as labels (next/prev only bind in
# the story view, never on the front). Resulting label order: a c d i n o p u v x y.
GN_RESERVED_KEYS="b e f g h j k l m q r s t w z"
gn_story_label() {  # gn_story_label <0-based index> → letter (empty if out of range)
    local want="$1" n=0 c
    case "$want" in ''|*[!0-9]*) return ;; esac
    for c in {a..z}; do
        case " $GN_RESERVED_KEYS " in *" $c "*) continue ;; esac
        [ "$n" -eq "$want" ] && { printf '%s' "$c"; return; }
        n=$(( n + 1 ))
    done
}
gn_label_index() {  # gn_label_index <letter> → 0-based index (empty if reserved/unknown)
    local want="$1" n=0 c
    [ -n "$want" ] || return
    for c in {a..z}; do
        case " $GN_RESERVED_KEYS " in *" $c "*) continue ;; esac
        [ "$c" = "$want" ] && { printf '%s' "$n"; return; }
        n=$(( n + 1 ))
    done
}

# Color escape for a conventional-commit type (uses GN_* set by gn_color_init).
gn_type_color() {  # gn_type_color <type>
    case "$1" in
        feat)          printf '%s' "$GN_GRN" ;;
        fix)           printf '%s' "$GN_RED" ;;
        docs)          printf '%s' "$GN_BLU" ;;
        refactor|perf) printf '%s' "$GN_MAG" ;;
        test|ci|build) printf '%s' "$GN_CYN" ;;
        *)             printf '%s' "$GN_YEL" ;;
    esac
}

# Accent escapes for a story's repo heading / lead repo / commit-type dot, honouring
# the highlight toggle: "on" paints the theme accent ink (so the desk is scannable by
# repo and by type), "off" calms it to plain bold / a quiet dim. One policy shared by
# render-news and render-story (and pinned by the tests). With colour off the GN_* are
# already empty, so every result collapses to the same plain text.
gn_hl_repo() { [ "${1:-on}" = off ] && printf '%s' "$GN_B" || printf '%s' "$GN_B$GN_CYN"; }
gn_hl_lead() { [ "${1:-on}" = off ] && printf '%s' "$GN_B" || printf '%s' "$GN_B$GN_YEL"; }
gn_hl_type() { [ "${1:-on}" = off ] && printf '%s' "$GN_DIM" || gn_type_color "$2"; }
