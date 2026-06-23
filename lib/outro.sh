# shellcheck shell=bash
# git-times — outro (the closing animation: how the paper leaves when you quit).
# Sourced by gittimes-lib.sh; never executed directly, no `set` flags (would leak
# to the caller). Needs the GN_* colours (gn_color_init) and gn_strwidth in scope.
#
# Four styles, all paper: roll (the paper rolls up bottom-to-top and is tossed,
# newspaper-delivery style — the default), crumple (the page crushes toward the
# middle and the ball is flicked off), fold (halved and halved again, tucked
# away), fade (the ink dries out of the print). Every frame doubles as a key
# wait: ANY key skips the rest instantly — the outro may never hold a quit
# hostage. The whole thing is ~0.5-0.8 s.
#
# The entry point reads the visible page rows from stdin (one row per line,
# ANSI already stripped — the transforms slice and mutate glyphs, and a CSI
# sequence cut mid-escape would spray garbage). It owns the screen for its few
# frames and leaves a centered farewell line behind; the caller's normal exit
# reset (cursor, surface) still runs after it.

# One animation frame: home the cursor, a blank top margin, every row of the
# given array left-padded into the column and cleared to EOL, then wipe the
# rest of the screen. A single printf, so the terminal applies it as one update.
_gn_outro_paint() {  # _gn_outro_paint <pad-spaces> <row>...
    local pad="$1"; shift
    local out=$'\033[H\033[K\n' row
    for row in "$@"; do out+="$pad$row"$'\033[K\n'; done
    out+=$'\033[J'
    printf '%s' "$out"
}

# The frame delay that is also the skip switch: wait <secs> on the tty (fd 9,
# opened by gn_outro_play); a key arriving ends the wait early and returns 1
# ("skip the rest"). Only a real timeout (rc > 128) means "next frame" — EOF or
# a read error returns 1 too, so a dead tty bails out instead of flashing every
# frame through at zero delay.
_gn_outro_wait() {  # _gn_outro_wait <secs>
    local _k rc
    IFS= read -rsn1 -t "$1" -u 9 _k 2>/dev/null; rc=$?
    [ "$rc" -gt 128 ] && return 0
    return 1
}

# ── pure per-row transforms (deterministic under a seeded RANDOM — tested) ────

# Fade one row: every non-space glyph turns into <glyph> with <pct>% chance —
# the ink drying out of the print, pass by pass.
gn_outro_fade_row() {  # gn_outro_fade_row <text> <pct> <glyph>
    local s="$1" pct="$2" g="$3" out="" i ch
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        if [ "$ch" != ' ' ] && [ $(( RANDOM % 100 )) -lt "$pct" ]; then out+="$g"; else out+="$ch"; fi
    done
    printf '%s' "$out"
}

# Crease one row: random glyphs become crumple marks — the type breaking as the
# sheet buckles. Spaces stay; the row keeps its glyph count, so columns hold
# under a UTF-8 locale (under LC_ALL=C multibyte glyphs split byte-wise — the
# frame still renders, just wider; acceptable for a page being destroyed).
gn_outro_crumple_row() {  # gn_outro_crumple_row <text> <density-pct>
    local s="$1" pct="$2" out="" i ch marks='/\><_' m
    for ((i=0; i<${#s}; i++)); do
        ch="${s:i:1}"
        if [ "$ch" != ' ' ] && [ $(( RANDOM % 100 )) -lt "$pct" ]; then
            m=$(( RANDOM % ${#marks} )); out+="${marks:m:1}"
        else out+="$ch"; fi
    done
    printf '%s' "$out"
}

# The roll cylinder — the already-rolled part of the paper, three rows wide as
# the column. Echoes its rows one per line (top, barrel, bottom).
gn_outro_roll_band() {  # gn_outro_roll_band <width>
    local w="$1" i fill=""
    [ "$w" -lt 4 ] && w=4
    for ((i=0; i<w-2; i++)); do if [ $(( i % 2 )) -eq 0 ]; then fill+='▒'; else fill+='░'; fi; done
    printf '╭%s╮\n' "$(hr $(( w - 2 )) '─')"
    printf '│%s│\n' "$fill"
    printf '╰%s╯\n' "$(hr $(( w - 2 )) '─')"
}

# ── the styles (each: <lines> <cols> <pad-spaces> <cw>; page rows in PG[]) ────

_gn_outro_roll() {  # bottom-to-top roll, then the delivery toss
    local lines="$1" cols="$2" pad="$3" cw="$4"
    local body=${#PG[@]} edge step
    local -a band=() frame=()
    mapfile -t band < <(gn_outro_roll_band "$cw")
    step=$(( (body + 9) / 10 )); [ "$step" -lt 1 ] && step=1
    for (( edge=body-step; edge>0; edge-=step )); do
        frame=( "${PG[@]:0:edge}" "${band[@]}" )
        _gn_outro_paint "$pad" "${frame[@]}"
        _gn_outro_wait 0.05 || return
    done
    # The rolled paper: a short tube that flies off to the right, speed lines behind.
    local tube='(▒▒▒▒▒▒▒▒▒▒▒▒)' x trail mid=$(( lines / 2 ))
    local tw; tw="$(gn_strwidth "$tube")"
    for (( x = (cols - tw) / 2; x < cols; x += (cols / 5) + 1 )); do
        [ "$x" -lt 1 ] && x=1
        trail='≡ ≡'; [ "$x" -le 4 ] && trail=''
        printf '\033[H\033[2J\033[%d;%dH%s%s  %s%s' "$mid" "$x" "$GN_DIM" "$trail" "$tube" "$GN_R"
        _gn_outro_wait 0.05 || return
    done
}

_gn_outro_crumple() {  # the page crushes toward the middle, the ball is flicked off
    local lines="$1" cols="$2" pad="$3" cw="$4"
    local body=${#PG[@]} p f bh top w ind jit i src row
    local -a frame=()
    for (( p=1; p<=5; p++ )); do
        f=$(( 6 - p ))
        bh=$(( body * f / 6 )); [ "$bh" -lt 1 ] && bh=1
        top=$(( (body - bh) / 2 ))
        w=$(( cw * f / 6 ));   [ "$w" -lt 4 ] && w=4
        frame=()
        for (( i=0; i<top; i++ )); do frame+=( '' ); done
        for (( i=0; i<bh; i++ )); do
            src=$(( i * body / bh )); [ "$src" -ge "$body" ] && src=$(( body - 1 ))
            jit=$(( RANDOM % (p + p + 1) - p ))
            ind=$(( (cw - w) / 2 + jit )); [ "$ind" -lt 0 ] && ind=0
            row="${PG[$src]:$(( (cw - w) / 2 )):$w}"
            frame+=( "$(printf '%*s' "$ind" '')$(gn_outro_crumple_row "$row" $(( p * 14 )))" )
        done
        _gn_outro_paint "$pad" "${frame[@]}"
        _gn_outro_wait 0.09 || return
    done
    # The paper ball drops to the floor and is flicked off to the right.
    local mid=$(( lines / 2 )) floor=$(( lines - 2 )) x r
    for r in "$mid" $(( (mid + floor) / 2 )) "$floor"; do
        printf '\033[H\033[2J\033[%d;%dH%s(✶)%s' "$r" $(( cols / 2 )) "$GN_DIM" "$GN_R"
        _gn_outro_wait 0.06 || return
    done
    for (( x = cols / 2; x < cols; x += (cols / 5) + 1 )); do
        printf '\033[H\033[2J\033[%d;%dH%s≡  (✶)%s' "$floor" "$x" "$GN_DIM" "$GN_R"
        _gn_outro_wait 0.05 || return
    done
}

_gn_outro_fold() {  # halved and halved again, then tucked away off the bottom
    local lines="$1" cols="$2" pad="$3" cw="$4"
    local body=${#PG[@]} h r
    local -a frame=()
    h="$body"
    while [ "$h" -gt 2 ]; do
        h=$(( (h + 1) / 2 ))
        frame=( "${PG[@]:0:h}" "$(hr "$cw" '═')" )
        _gn_outro_paint "$pad" "${frame[@]}"
        _gn_outro_wait 0.11 || return
    done
    # The folded packet slides down off the page — tucked under the arm.
    local pw=$(( cw / 4 )); [ "$pw" -lt 6 ] && pw=6
    local px=$(( (cols - pw) / 2 )); [ "$px" -lt 1 ] && px=1
    local bar; bar="$(hr $(( pw - 2 )) '─')"
    for (( r=2; r<lines; r+=2 )); do
        printf '\033[H\033[2J\033[%d;%dH%s┌%s┐\033[%d;%dH│%s│\033[%d;%dH└%s┘%s' \
            "$r" "$px" "$GN_DIM" "$bar" $(( r + 1 )) "$px" \
            "$(printf '%*s' $(( pw - 2 )) '' | tr ' ' '▒')" \
            $(( r + 2 )) "$px" "$bar" "$GN_R"
        _gn_outro_wait 0.06 || return
    done
}

_gn_outro_fade() {  # the ink dries out of the print, pass by pass
    local lines="$1" cols="$2" pad="$3" cw="$4"
    local body=${#PG[@]} i
    local -a stagepct=(35 60 100) stageg=('░' '·' ' ') frame=()
    local s
    for s in 0 1 2; do
        for (( i=0; i<body; i++ )); do
            PG[i]="$(gn_outro_fade_row "${PG[$i]}" "${stagepct[$s]}" "${stageg[$s]}")"
        done
        frame=( "${PG[@]}" )
        _gn_outro_paint "$pad" "${frame[@]/#/$GN_DIM}"
        _gn_outro_wait 0.12 || return
    done
}

# The farewell colophon a finished (not skipped) outro leaves behind: one faint
# centered line mid-screen; the shell prompt then lands at the bottom.
_gn_outro_farewell() {  # _gn_outro_farewell <style> <lines> <cols>
    local msg
    case "$1" in
        roll)    msg='rolled & delivered — see you at the next edition' ;;
        crumple) msg="yesterday's news — straight to the bin" ;;
        fold)    msg='folded & tucked under the arm — till next time' ;;
        *)       msg='the ink dries · the presses rest' ;;
    esac
    local w lp; w="$(gn_strwidth "$msg")"
    lp=$(( ($3 - w) / 2 )); [ "$lp" -lt 1 ] && lp=1
    printf '\033[H\033[2J\033[%d;%dH%s— %s —%s\033[%d;1H' \
        $(( $2 / 2 )) "$lp" "$GN_FAINT" "$msg" "$GN_R" $(( $2 - 1 ))
}

# Entry point. Page rows on stdin (ANSI-stripped, unpadded); draws on stdout —
# only the interactive reader calls this, where stdout IS the terminal. Quietly
# a no-op for off/unknown styles, without a tty (piped tests, cron), or when
# there is nothing to animate. Any key skips: the screen is wiped and we return
# at once, so a quit is never slower than the user wants it to be.
gn_outro_play() {  # gn_outro_play <style> <lines> <cols> <pad> <cw>   rows ← stdin
    local style="$1" lines="$2" cols="$3" padn="$4" cw="$5" pad=""
    case "$style" in roll|crumple|fold|fade) ;; *) return 0 ;; esac
    [ -t 1 ] || return 0
    { exec 9</dev/tty; } 2>/dev/null || return 0
    local -a PG=()
    mapfile -t PG
    [ "${#PG[@]}" -ge 1 ] || { exec 9<&-; return 0; }
    [ "$padn" -gt 0 ] 2>/dev/null && pad="$(printf '%*s' "$padn" '')"
    if "_gn_outro_$style" "$lines" "$cols" "$pad" "$cw"; then
        _gn_outro_farewell "$style" "$lines" "$cols"
    else
        printf '\033[H\033[2J'   # skipped — wipe the half-told animation, leave at once
    fi
    exec 9<&-
    return 0
}
