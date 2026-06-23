# shellcheck shell=bash
# git-times — press loader (the full-screen opening animation). Sourced by
# gittimes-lib.sh; never executed directly, no `set` flags (would leak to the caller).
# Needs the GN_* colours (gn_color_init), TF, and the geometry helpers (gn_term_size,
# gn_strwidth) in scope — all provided by the lib that sources this file.

# ── press loader (the opening animation while a collect blocks) ───────────────
# While a background collect runs, fill the whole terminal with one of four
# animations — the pick is sticky (settings panel `C` → i) with GIT_TIMES_INTRO
# as the env baseline (resolved by gn_intro_resolve):
#   press     newsprint "jibber" pulled through the press, pass after pass
#   teletype  the wire room — dispatches typed out line by line, cursor and all
#   linotype  slugs of type sliding into the galley, row by row
#   darkroom  the page developing out of faint dot-grain, patch by patch
#   off       a static banner — the blocking wait still has a face, nothing moves
# Every style keeps the centered masthead banner that names the edition and
# carries the spinner. Drawn on /dev/tty only, so stdout stays clean for the
# snapshot path (interactive) or the piped render (print). The motion master
# (GIT_TIMES_MOTION / settings `C`) holds every style down to the static banner.
# <bg> is the collect PID; the loop ends when it exits. The braille frames are
# array elements (not a UTF-8 substring), so they survive an LC_ALL=C locale.
# The style functions read the geometry (rows/cols/body, banner box, frames, bg)
# from this scope — bash dynamic scoping, the house pattern.
gn_press() {  # gn_press <bg-pid>
    local bg="$1" style sz rows cols body i=0
    local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    # Open the controlling terminal once on fd 3 (cheaper than reopening /dev/tty per
    # row, and the helpers inherit the fd). The group-redirect swallows the shell's
    # failed-open error the same way gn_term_size does. With no tty (pipe/cron) there
    # is nothing to draw on, so just wait the collect out quietly.
    { exec 3>/dev/tty; } 2>/dev/null
    if ! { true >&3; } 2>/dev/null; then
        while kill -0 "$bg" 2>/dev/null; do sleep 0.1; done; return
    fi
    sz="$(gn_term_size)"; rows="${sz%% *}"; cols="${sz##* }"
    [ "$rows" -ge 6  ] 2>/dev/null || rows=24
    [ "$cols" -ge 20 ] 2>/dev/null || cols=80
    body=$(( rows - 1 ))
    # Banner box: centered, capped ~46 cols, five rows (border, title, edition,
    # spinner, border), vertically centered in the body. The border bar is built
    # once here — the old per-redraw $(printf … $(seq …)) forked twice every pass.
    local label bw bx bh=5 by bnr_bar
    label="$(gn_tf_label "$TF")"
    bw=$(( cols - 6 )); [ "$bw" -gt 46 ] && bw=46; [ "$bw" -lt 22 ] && bw=22
    bx=$(( (cols - bw) / 2 + 1 )); [ "$bx" -lt 1 ] && bx=1
    by=$(( (body - bh) / 2 + 1 )); [ "$by" -lt 1 ] && by=1
    printf -v bnr_bar '%*s' $(( bw - 2 )) ''; bnr_bar="${bnr_bar// /─}"
    style="$(gn_intro_resolve)"
    [ "$(gn_motion_resolve)" = off ] && style=off
    printf '\033[?25l\033[H\033[2J' >&3
    case "$style" in
        off)      _gn_press_off ;;
        teletype) _gn_press_teletype ;;
        linotype) _gn_press_linotype ;;
        darkroom) _gn_press_darkroom ;;
        *)        _gn_press_jibber ;;
    esac
    printf '\033[0m' >&3
    exec 3>&-
}

# ── the styles ────────────────────────────────────────────────────────────────

# Is row <1> inside the banner block (by..by+bh)? The animations paint around the
# banner, never over it — every per-row loop shares this guard.
_gn_press_in_banner() { [ "$1" -ge "$by" ] && [ "$1" -lt $(( by + bh )) ]; }

# off — the static banner. Same face the motion master shows: a blocking wait
# still needs to say what it is doing, but nothing repaints. (gn_press style)
_gn_press_off() {
    _gn_press_banner ''
    while kill -0 "$bg" 2>/dev/null; do sleep 0.1; done
}

# press — the classic: faint newsprint jibber fills the page top-down, pass after
# pass, as if paper were being pulled through the press. The pool is generated
# once (the random slice offset alone makes the type shimmer — the old per-pass
# regeneration forked head+tr for nothing) and the banner is painted once, only
# its spinner row ticking per pass. (gn_press style)
_gn_press_jibber() {
    local pool plen r off
    _gn_press_pool
    _gn_press_banner "${frames[0]}"
    while kill -0 "$bg" 2>/dev/null; do
        for (( r=1; r<=body; r++ )); do
            kill -0 "$bg" 2>/dev/null || break
            _gn_press_in_banner "$r" && continue
            off=$(( RANDOM % (plen - cols) ))
            printf '\033[%d;1H%s%s%s' "$r" "$GN_FAINT" "${pool:off:cols}" "$GN_R" >&3
            sleep 0.01
        done
        i=$(( (i + 1) % ${#frames[@]} ))
        _gn_press_text $(( by + 3 )) "$GN_DIM" "${frames[i]} on the press…"
    done
}

# teletype — the wire room: short dispatches type themselves out line by line
# under the banner, a block cursor riding the keys; when the column reaches the
# floor it is torn off and the typing rolls back to the top. Three characters a
# step, so a slow collect reads as typing, not as a crawl. (gn_press style)
_gn_press_teletype() {
    local -a wire=(
        'urgent — counting the commits'
        'wire — walking the repositories'
        'desk — sorting the day into hours'
        'copy — measuring the longest streak'
        'flash — weighing additions against deletions'
        'advisory — the late shift is on record'
        'bulletin — the front page is being set'
        'stand by — the edition is closing'
    )
    local top=$(( by + bh + 1 )) r n=0 line j w
    [ "$top" -gt "$body" ] && top="$body"   # tiny terminal: type over the floor row
    r="$top"
    w=$(( cols - bx )); [ "$w" -lt 8 ] && w=8
    _gn_press_banner "${frames[0]}"
    while kill -0 "$bg" 2>/dev/null; do
        line="${wire[n % ${#wire[@]}]}"
        [ "${#line}" -gt "$w" ] && line="${line:0:w}"
        for (( j=0; j<=${#line}; j+=3 )); do
            kill -0 "$bg" 2>/dev/null || break 2
            printf '\033[%d;%dH\033[K%s%s%s▌' "$r" "$bx" "$GN_DIM" "${line:0:j}" "$GN_R" >&3
            sleep 0.04
        done
        printf '\033[%d;%dH\033[K%s%s%s' "$r" "$bx" "$GN_DIM" "$line" "$GN_R" >&3
        n=$(( n + 1 )); r=$(( r + 1 ))
        if [ "$r" -gt "$body" ]; then   # column full — tear the page off, roll up
            for (( j=top; j<=body; j++ )); do printf '\033[%d;1H\033[K' "$j" >&3; done
            r="$top"
        fi
        i=$(( (i + 1) % ${#frames[@]} ))
        _gn_press_text $(( by + 3 )) "$GN_DIM" "${frames[i]} on the press…"
        sleep 0.15
    done
}

# linotype — the composing room: each row's slug of jibber shoots in from the
# right edge and snaps onto its line, top to bottom; when the galley is full it
# is melted down and set again with fresh slices. The masthead is already locked
# in the chase, so the banner rows are skipped. (gn_press style)
_gn_press_linotype() {
    local pool plen r off step lead vis
    _gn_press_pool
    _gn_press_banner "${frames[0]}"
    while kill -0 "$bg" 2>/dev/null; do
        for (( r=1; r<=body; r++ )); do
            kill -0 "$bg" 2>/dev/null || break
            _gn_press_in_banner "$r" && continue
            off=$(( RANDOM % (plen - cols) ))
            for (( step=6; step>=0; step-- )); do
                lead=$(( step * (cols / 8) ))
                [ "$lead" -ge "$cols" ] && continue
                vis=$(( cols - lead ))
                printf '\033[%d;1H\033[K\033[%d;%dH%s%s%s' \
                    "$r" "$r" $(( lead + 1 )) "$GN_FAINT" "${pool:off:vis}" "$GN_R" >&3
                sleep 0.008
            done
        done
        i=$(( (i + 1) % ${#frames[@]} ))
        _gn_press_text $(( by + 3 )) "$GN_DIM" "${frames[i]} on the press…"
    done
}

# darkroom — the print develops: the page starts as a bath of faint dot-grain,
# then patches of type emerge wherever the developer reaches, a little more every
# tick; on a long collect some rows are washed back to grain now and then, so the
# bath never goes still. (gn_press style)
_gn_press_darkroom() {
    local pool plen grain glen r c len off t=0
    _gn_press_pool
    grain="${pool:0:$(( cols * 2 ))}"
    grain="${grain//[! ]/·}"   # keep the word-gaps, dot the type
    glen=${#grain}
    for (( r=1; r<=body; r++ )); do
        _gn_press_in_banner "$r" && continue
        printf '\033[%d;1H%s%s%s' "$r" "$GN_FAINT" "${grain:$(( RANDOM % (glen - cols) )):cols}" "$GN_R" >&3
    done
    _gn_press_banner "${frames[0]}"
    while kill -0 "$bg" 2>/dev/null; do
        r=$(( RANDOM % body + 1 ))
        _gn_press_in_banner "$r" && continue
        len=$(( cols / 6 + RANDOM % (cols / 4 + 1) ))
        c=$(( RANDOM % cols + 1 ))
        [ $(( c + len )) -gt "$cols" ] && len=$(( cols - c + 1 ))
        off=$(( RANDOM % (plen - len) ))
        printf '\033[%d;%dH%s%s%s' "$r" "$c" "$GN_FAINT" "${pool:off:len}" "$GN_R" >&3
        t=$(( t + 1 ))
        if [ $(( t % 8 )) -eq 0 ]; then
            i=$(( (i + 1) % ${#frames[@]} ))
            _gn_press_text $(( by + 3 )) "$GN_DIM" "${frames[i]} on the press…"
        fi
        if [ $(( t % 96 )) -eq 0 ]; then   # wash a couple of rows back to grain
            for (( len=0; len<2; len++ )); do
                r=$(( RANDOM % body + 1 ))
                _gn_press_in_banner "$r" && continue
                printf '\033[%d;1H%s%s%s' "$r" "$GN_FAINT" "${grain:$(( RANDOM % (glen - cols) )):cols}" "$GN_R" >&3
            done
        fi
        sleep 0.02
    done
}

# ── shared helpers ────────────────────────────────────────────────────────────

# One ASCII-only newsprint pool (byte == column, so fixed-width slicing stays
# aligned); the extra spaces in the tr set bias toward word-like gaps. Sets
# pool/plen in the calling style's scope. (gn_press helper)
_gn_press_pool() {
    pool="$(LC_ALL=C head -c 32768 /dev/urandom 2>/dev/null | LC_ALL=C tr -dc 'a-z   .,;:' | head -c 4096)"
    plen=${#pool}
    while [ "$plen" -le $(( cols * 2 )) ]; do pool="$pool$pool ipsum lorem "; plen=${#pool}; done
}

# The masthead banner, all five rows at once. <spin> rides the third text row;
# pass '' for the static face. (gn_press helper)
_gn_press_banner() {  # _gn_press_banner <spinner-glyph|''>
    local sp="$1"
    _gn_press_rule "$by" top
    _gn_press_text $(( by + 1 )) "$GN_B$GN_YEL" "THE GIT TIMES"
    _gn_press_text $(( by + 2 )) "$GN_R" "setting the $label edition"
    if [ -n "$sp" ]; then _gn_press_text $(( by + 3 )) "$GN_DIM" "$sp on the press…"
    else                  _gn_press_text $(( by + 3 )) "$GN_DIM" "on the press…"; fi
    _gn_press_rule $(( by + 4 )) bot
}

# A banner border row (┌──┐ / └──┘) at <row>; column and width come from the
# gn_press scope (bx, bnr_bar). Draws on fd 3. (gn_press helper)
_gn_press_rule() {  # _gn_press_rule <row> <top|bot>
    case "$2" in
        top) printf '\033[%d;%dH%s┌%s┐%s' "$1" "$bx" "$GN_DIM" "$bnr_bar" "$GN_R" >&3 ;;
        *)   printf '\033[%d;%dH%s└%s┘%s' "$1" "$bx" "$GN_DIM" "$bnr_bar" "$GN_R" >&3 ;;
    esac
}

# A centered text row inside the banner box: │ <centered text> │. Colour codes are
# zero-width, so the padding maths uses gn_strwidth on the visible glyphs only.
# Column and width come from the gn_press scope (bx, bw). (gn_press helper)
_gn_press_text() {  # _gn_press_text <row> <color> <text>
    local r="$1" col="$2" txt="$3" inner w lp rp
    inner=$(( bw - 4 ))
    w="$(gn_strwidth "$txt")"
    [ "$w" -gt "$inner" ] && { txt="${txt:0:inner}"; w="$inner"; }
    lp=$(( (inner - w) / 2 )); rp=$(( inner - w - lp ))
    printf '\033[%d;%dH%s│%s %*s%s%s%s%*s %s│%s' \
        "$r" "$bx" "$GN_DIM" "$GN_R" "$lp" '' "$col" "$txt" "$GN_R" "$rp" '' "$GN_DIM" "$GN_R" >&3
}

# ── the feature desk (the writing animation while `F` drafts the long read) ─────
# A SECOND full-screen animation, distinct from the press loader and its metaphor:
# while the engine drafts the edition feature (reader `F` -> feature_write, a
# blocking LLM call of several seconds), the long read composes itself on the page.
# Note on timing: this animation has no runtime of its own — its loop is
# `while kill -0 <bg>`, so it lasts exactly as long as the draft and breaks within
# one sleep of the PID exiting; it never makes `F` slower (the engine sets the
# clock), it only gives the wait a face. Four interchangeable faces, sticky like
# the press intro (settings `w`, GIT_TIMES_COMPOSE baseline, gn_compose_resolve):
#   galley   the column sets itself — an ink bar fills under a live word count
#   sweep    a bright band sweeps across the laid-down type, catching ink
#   quill    a nib glides each line, an ink underline growing behind it
#   write    the typewriter — headline then body typed out as wet ink
#   off      a static desk — the wait still has a face, nothing moves
# Each face is deliberately CPU-light: a cursor move plus a few bytes per frame, no
# forks in the loop (the corpus/measure are set once), short sleeps. Same discipline
# as gn_press: the masthead banner (top-anchored here, to leave the page below for
# the copy) carries a braille spinner, drawing is on /dev/tty (fd 3) only, the motion
# master (settings `C`) holds every face to the static desk, and with no tty
# (pipe/cron) it just waits the draft out. The leaf helpers
# (_gn_press_text/_rule/_in_banner) and the shared _gn_compose_corpus/_stage/_bar are
# reused; only the copy and the motion differ. <bg> is the feature_write PID — the
# loop ends when it exits. <byline> names the engine for the banner ("claude at the
# desk..."). The geometry preamble mirrors gn_press deliberately (a focused copy,
# not a refactor of the tested intro path). (gn_compose)
gn_compose() {  # gn_compose <bg-pid> [byline]
    local bg="$1" byline="${2:-the desk}" sz rows cols body i=0
    local -a frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    { exec 3>/dev/tty; } 2>/dev/null
    if ! { true >&3; } 2>/dev/null; then
        while kill -0 "$bg" 2>/dev/null; do sleep 0.1; done; return
    fi
    sz="$(gn_term_size)"; rows="${sz%% *}"; cols="${sz##* }"
    [ "$rows" -ge 6  ] 2>/dev/null || rows=24
    [ "$cols" -ge 20 ] 2>/dev/null || cols=80
    body=$(( rows - 1 ))
    # Banner box: same five-row masthead as gn_press, but pinned to the TOP (by=1)
    # so the whole page below it is free for the copy to write into.
    local label bw bx bh=5 by=1 bnr_bar
    label="$(gn_tf_label "$TF")"
    bw=$(( cols - 6 )); [ "$bw" -gt 46 ] && bw=46; [ "$bw" -lt 22 ] && bw=22
    bx=$(( (cols - bw) / 2 + 1 )); [ "$bx" -lt 1 ] && bx=1
    printf -v bnr_bar '%*s' $(( bw - 2 )) ''; bnr_bar="${bnr_bar// /─}"
    printf '\033[?25l\033[H\033[2J' >&3
    # Four interchangeable writing faces, sticky like the press intro (settings `w`,
    # GIT_TIMES_COMPOSE as the env baseline, resolved by gn_compose_resolve); the
    # motion master holds them all to the static desk. Every face is CPU-light — a
    # cursor move plus a few bytes per frame, no forks in the loop — and breaks within
    # one sleep of the draft PID exiting, so none of them ever extends the wait.
    local style; style="$(gn_compose_resolve)"
    [ "$(gn_motion_resolve)" = off ] && style=off
    case "$style" in
        off)    _gn_compose_off ;;
        sweep)  _gn_compose_sweep ;;
        quill)  _gn_compose_quill ;;
        write)  _gn_compose_write ;;
        *)      _gn_compose_galley ;;
    esac
    printf '\033[0m' >&3
    exec 3>&-
}

# The masthead for the desk: same box as the press banner, feature copy. <spin>
# rides the third row; pass '' for the static face. (gn_compose helper)
_gn_compose_banner() {  # _gn_compose_banner <spin|''>
    local sp="$1"
    _gn_press_rule "$by" top
    _gn_press_text $(( by + 1 )) "$GN_B$GN_YEL" "THE GIT TIMES"
    _gn_press_text $(( by + 2 )) "$GN_R" "drafting the $label feature"
    if [ -n "$sp" ]; then _gn_press_text $(( by + 3 )) "$GN_DIM" "$sp  $byline at the desk…"
    else                  _gn_press_text $(( by + 3 )) "$GN_DIM" "$byline at the desk…"; fi
    _gn_press_rule $(( by + 4 )) bot
}

# A plain centered row on the full width (no banner border) — for the manuscript
# slug and the static-face line. Colour codes are zero-width, so the centring uses
# gn_strwidth on the visible glyphs. (gn_compose helper)
_gn_compose_ctr() {  # _gn_compose_ctr <row> <color> <text>
    local r="$1" col="$2" txt="$3" w lp
    w="$(gn_strwidth "$txt")"
    lp=$(( (cols - w) / 2 + 1 )); [ "$lp" -lt 1 ] && lp=1
    printf '\033[%d;%dH\033[K%s%s%s' "$r" "$lp" "$col" "$txt" "$GN_R" >&3
}

# Tick the banner spinner — but only every fifth keystroke, so the braille turns at
# a calm pace through a long line instead of blurring. Reads/sets sc and i from the
# writing loop scope (bash dynamic scoping, the house pattern). (gn_compose helper)
_gn_compose_tick() {
    sc=$(( sc + 1 ))
    [ $(( sc % 5 )) -eq 0 ] || return
    i=$(( (i + 1) % ${#frames[@]} ))
    _gn_press_text $(( by + 3 )) "$GN_DIM" "${frames[i]}  $byline at the desk…"
}

# off — the static desk: the master motion toggle is off, so the banner and one
# faint slug name the wait, but nothing types. (gn_compose style)
_gn_compose_off() {
    _gn_compose_banner ''
    _gn_compose_ctr $(( by + bh + 1 )) "$GN_FAINT" "❡ the long read is being composed…"
    while kill -0 "$bg" 2>/dev/null; do sleep 0.1; done
}

# The corpus the writing faces draw from — feature headlines and body sentences,
# every element apostrophe-free on purpose (a stray ' in a single-quoted array
# element closes the string, the same family of trap the jq programs guard against).
# Fills heads[]/para[] in the caller scope (declared local there — the house
# pattern). (gn_compose helper)
_gn_compose_corpus() {
    heads=(
        'The week the repository worked late'
        'Inside the commits that closed the edition'
        'A quiet sprint, measured in diffs'
        'How the late shift set the front page'
        'The long arc of a busy seven days'
        'Notes from a desk that did not sleep'
    )
    para=(
        'The editors weigh the week commit by commit, and a story takes shape on the page.'
        'Additions pile against deletions, and somewhere in the balance the real work shows.'
        'A repository keeps its own hours, and the late entries read like a confession.'
        'Between the merges and the reverts the writer looks for the line that holds.'
        'Every branch is a sentence the author has not finished saying out loud yet.'
        'The galley fills, the deadline leans in, and the copy is set one word at a time.'
        'By the last paragraph the numbers have become a narrative, and the desk exhales.'
    )
}

# Shared stage for the writing faces: the top banner and the centered measure. Sets
# mw/mx/wt/btop in the caller scope (declared local there) and paints the banner
# plus the manuscript slug. mw is the writing measure, mx its left column, wt the
# slug row, btop the first copy row. (gn_compose helper)
_gn_compose_stage() {
    mw=$(( cols - 8 )); [ "$mw" -gt 64 ] && mw=64; [ "$mw" -lt 16 ] && mw=16
    mx=$(( (cols - mw) / 2 + 1 )); [ "$mx" -lt 1 ] && mx=1
    wt=$(( by + bh + 1 )); [ "$wt" -gt "$body" ] && wt="$body"
    btop=$(( wt + 2 )); [ "$btop" -gt "$body" ] && btop="$body"
    _gn_compose_banner "${frames[0]}"
    _gn_compose_ctr "$wt" "$GN_DIM" "❡ THE LONG READ"
}

# A galley fill bar <cells> wide, <fill-eighths> filled — full █, one leading
# eighth-block, the rest ░. Sets `bar` in the caller scope; the partial glyphs come
# from the caller's blk[] (index 1..7). The byte-wise // substitution on a multibyte
# glyph is the same trick the press border bar uses, so it survives LC_ALL=C.
# (gn_compose helper)
_gn_compose_bar() {  # _gn_compose_bar <fill-eighths> <cells>
    local fi="$1" cw="$2" f p e pad
    f=$(( fi / 8 )); p=$(( fi % 8 )); [ "$f" -gt "$cw" ] && f="$cw"
    printf -v bar '%*s' "$f" ''; bar="${bar// /█}"
    if [ "$f" -lt "$cw" ]; then
        if [ "$p" -gt 0 ]; then bar="$bar${blk[p]}"; f=$(( f + 1 )); fi
        e=$(( cw - f )); if [ "$e" -gt 0 ]; then printf -v pad '%*s' "$e" ''; bar="$bar${pad// /░}"; fi
    fi
}

# write — the desk at work: a headline types in bold, then the body fills as faint
# ink, line by line, the caret riding the writing point; a full sheet feeds up and
# the next take begins. Sentence pools are apostrophe-free on purpose (a stray ' in
# a single-quoted array element would close the string, the same family of trap the
# jq programs guard against). (gn_compose style)
_gn_compose_write() {
    local -a heads para; _gn_compose_corpus
    local wt mw mx btop row hl txt cl word ln j n=0 ph=0 sc=0
    _gn_compose_stage
    row="$btop"
    while kill -0 "$bg" 2>/dev/null; do
        # 1) the headline types itself out in bold, three glyphs a step, caret riding
        hl="${heads[n % ${#heads[@]}]}"; [ "${#hl}" -gt "$mw" ] && hl="${hl:0:mw}"
        for (( j=0; j<=${#hl}; j+=3 )); do
            kill -0 "$bg" 2>/dev/null || break 2
            printf '\033[%d;%dH\033[K%s%s%s▌%s' "$row" "$mx" "$GN_B$GN_YEL" "${hl:0:j}" "$GN_R" "$GN_R" >&3
            _gn_compose_tick
            sleep 0.018
        done
        printf '\033[%d;%dH\033[K%s%s%s' "$row" "$mx" "$GN_B$GN_YEL" "$hl" "$GN_R" >&3
        row=$(( row + 2 ))   # one blank line under the headline
        # 2) the body — two sentences word-wrapped to the measure, typed faint
        txt="${para[ph % ${#para[@]}]} ${para[(ph + 1) % ${#para[@]}]}"; ph=$(( ph + 1 ))
        local -a wrap=(); cl=''
        for word in $txt; do
            if [ -z "$cl" ]; then cl="$word"
            elif [ $(( ${#cl} + 1 + ${#word} )) -le "$mw" ]; then cl="$cl $word"
            else wrap+=("$cl"); cl="$word"; fi
        done
        [ -n "$cl" ] && wrap+=("$cl")
        for ln in "${wrap[@]}"; do
            [ "$row" -gt "$body" ] && break
            for (( j=0; j<=${#ln}; j+=4 )); do
                kill -0 "$bg" 2>/dev/null || break 3
                printf '\033[%d;%dH\033[K%s%s%s▌%s' "$row" "$mx" "$GN_FAINT" "${ln:0:j}" "$GN_R" "$GN_R" >&3
                _gn_compose_tick
                sleep 0.008
            done
            printf '\033[%d;%dH\033[K%s%s%s' "$row" "$mx" "$GN_FAINT" "$ln" "$GN_R" >&3
            row=$(( row + 1 ))
        done
        row=$(( row + 1 )); n=$(( n + 1 ))   # a blank line between takes
        if [ "$row" -gt "$body" ]; then      # sheet full — let it sit, then feed a fresh one
            sleep 0.25
            for (( j=btop; j<=body; j++ )); do printf '\033[%d;1H\033[K' "$j" >&3; done
            row="$btop"
        fi
        sleep 0.08
    done
}

# galley — the column sets itself: the headline locks in bold, then an ink galley
# bar fills cell by cell (eighth-blocks) under a live percentage and a climbing
# word count; a full column is set, the deadline leans, and the next take begins.
# The most graphical face and the lightest — one bar row and one meter row repaint
# per frame, no per-glyph typing. (gn_compose style)
_gn_compose_galley() {
    local -a heads para; _gn_compose_corpus
    local -a blk=(' ' ▏ ▎ ▍ ▌ ▋ ▊ ▉)
    local wt mw mx btop hl bar barrow metarow cells maxf fill col=1 pct words sc=0
    _gn_compose_stage
    barrow=$(( btop + 2 )); [ "$barrow" -gt "$body" ] && barrow="$body"
    metarow=$(( barrow + 1 )); [ "$metarow" -gt "$body" ] && metarow="$barrow"
    cells="$mw"; maxf=$(( cells * 8 ))
    while kill -0 "$bg" 2>/dev/null; do
        hl="${heads[(col - 1) % ${#heads[@]}]}"; [ "${#hl}" -gt "$mw" ] && hl="${hl:0:mw}"
        printf '\033[%d;%dH\033[K%s%s%s' "$btop" "$mx" "$GN_B$GN_YEL" "$hl" "$GN_R" >&3
        for (( fill=0; fill<=maxf; fill+=5 )); do
            kill -0 "$bg" 2>/dev/null || break 2
            _gn_compose_bar "$fill" "$cells"
            pct=$(( fill * 100 / maxf ))
            words=$(( (col - 1) * 820 + fill * 820 / maxf ))
            printf '\033[%d;%dH\033[K%s%s%s' "$barrow" "$mx" "$GN_DIM" "$bar" "$GN_R" >&3
            printf '\033[%d;%dH\033[K%s%3d%%  ~%d words set · column %d%s' \
                "$metarow" "$mx" "$GN_FAINT" "$pct" "$words" "$col" "$GN_R" >&3
            _gn_compose_tick
            sleep 0.02
        done
        col=$(( col + 1 ))
        kill -0 "$bg" 2>/dev/null && sleep 0.3
    done
}

# sweep — the type catches ink: the headline and a faint paragraph are laid down at
# once, then a bright band sweeps left to right across every line, again and again,
# as if the ink were being drawn through the set type. Each pass rotates a fresh
# take. Every row is fully repainted each frame (base + the moving band), so the
# band reverts behind itself with no residue. (gn_compose style)
_gn_compose_sweep() {
    local -a heads para; _gn_compose_corpus
    local wt mw mx btop sc=0 n=0 ph=0 band=4
    _gn_compose_stage
    local bb="$GN_B$GN_YEL"
    while kill -0 "$bg" 2>/dev/null; do
        # compose this take: the headline row, then the body wrapped to the measure
        local hl txt cl word r k
        hl="${heads[n % ${#heads[@]}]}"; [ "${#hl}" -gt "$mw" ] && hl="${hl:0:mw}"
        txt="${para[ph % ${#para[@]}]} ${para[(ph + 1) % ${#para[@]}]}"; ph=$(( ph + 1 ))
        local -a rtxt=() rbase=() rrow=()
        rtxt+=("$hl"); rbase+=("$GN_YEL"); rrow+=("$btop")
        r=$(( btop + 2 )); cl=''
        for word in $txt; do
            if [ -z "$cl" ]; then cl="$word"
            elif [ $(( ${#cl} + 1 + ${#word} )) -le "$mw" ]; then cl="$cl $word"
            else
                [ "$r" -le "$body" ] && { rtxt+=("$cl"); rbase+=("$GN_FAINT"); rrow+=("$r"); r=$(( r + 1 )); }
                cl="$word"
            fi
        done
        [ -n "$cl" ] && [ "$r" -le "$body" ] && { rtxt+=("$cl"); rbase+=("$GN_FAINT"); rrow+=("$r"); }
        for (( k=btop; k<=body; k++ )); do printf '\033[%d;1H\033[K' "$k" >&3; done
        # sweep a bright band of width <band> across all rows, -band .. mw
        local c a w len t b pre mid post
        for (( c=-band; c<=mw; c++ )); do
            kill -0 "$bg" 2>/dev/null || break 2
            for k in "${!rtxt[@]}"; do
                t="${rtxt[k]}"; b="${rbase[k]}"; len=${#t}
                a="$c"; w="$band"
                [ "$a" -lt 0 ] && { w=$(( band + a )); a=0; }
                [ "$w" -lt 0 ] && w=0
                [ "$a" -gt "$len" ] && a="$len"
                [ $(( a + w )) -gt "$len" ] && w=$(( len - a ))
                [ "$w" -lt 0 ] && w=0
                pre="${t:0:a}"; mid="${t:a:w}"; post="${t:a+w}"
                printf '\033[%d;%dH%s%s%s%s%s%s%s' \
                    "${rrow[k]}" "$mx" "$b" "$pre" "$bb" "$mid" "$GN_R$b" "$post" "$GN_R" >&3
            done
            _gn_compose_tick
            sleep 0.018
        done
        n=$(( n + 1 ))
        kill -0 "$bg" 2>/dev/null && sleep 0.2
    done
}

# quill — the pen at work: a nib ✎ glides along each line and an ink underline ▁
# grows behind it, line after line; the headline first, then a body line, then the
# sheet feeds fresh. Less text per beat than the typewriter, more motion in the
# stroke. (gn_compose style)
_gn_compose_quill() {
    local -a heads para; _gn_compose_corpus
    local wt mw mx btop row hl txt cl word ln j n=0 ph=0 sc=0 ul
    _gn_compose_stage
    row="$btop"
    while kill -0 "$bg" 2>/dev/null; do
        hl="${heads[n % ${#heads[@]}]}"; [ "${#hl}" -gt "$mw" ] && hl="${hl:0:mw}"
        for (( j=0; j<=${#hl}; j+=2 )); do
            kill -0 "$bg" 2>/dev/null || break 2
            printf '\033[%d;%dH\033[K%s%s%s✎%s' "$row" "$mx" "$GN_B$GN_YEL" "${hl:0:j}" "$GN_R" "$GN_R" >&3
            if [ $(( row + 1 )) -le "$body" ] && [ "$j" -gt 0 ]; then
                printf -v ul '%*s' "$j" ''; ul="${ul// /▁}"
                printf '\033[%d;%dH\033[K%s%s%s' $(( row + 1 )) "$mx" "$GN_DIM" "$ul" "$GN_R" >&3
            fi
            _gn_compose_tick; sleep 0.02
        done
        printf '\033[%d;%dH\033[K%s%s%s' "$row" "$mx" "$GN_B$GN_YEL" "$hl" "$GN_R" >&3
        if [ $(( row + 1 )) -le "$body" ]; then
            printf -v ul '%*s' "${#hl}" ''; ul="${ul// /▁}"
            printf '\033[%d;%dH\033[K%s%s%s' $(( row + 1 )) "$mx" "$GN_DIM" "$ul" "$GN_R" >&3
        fi
        row=$(( row + 3 ))
        txt="${para[ph % ${#para[@]}]}"; ph=$(( ph + 1 ))
        local -a wrap=(); cl=''
        for word in $txt; do
            if [ -z "$cl" ]; then cl="$word"
            elif [ $(( ${#cl} + 1 + ${#word} )) -le "$mw" ]; then cl="$cl $word"
            else wrap+=("$cl"); cl="$word"; fi
        done
        [ -n "$cl" ] && wrap+=("$cl")
        for ln in "${wrap[@]}"; do
            [ "$row" -gt "$body" ] && break
            for (( j=0; j<=${#ln}; j+=2 )); do
                kill -0 "$bg" 2>/dev/null || break 3
                printf '\033[%d;%dH\033[K%s%s%s✎%s' "$row" "$mx" "$GN_FAINT" "${ln:0:j}" "$GN_R" "$GN_R" >&3
                _gn_compose_tick; sleep 0.014
            done
            printf '\033[%d;%dH\033[K%s%s%s' "$row" "$mx" "$GN_FAINT" "$ln" "$GN_R" >&3
            row=$(( row + 1 ))
        done
        row=$(( row + 1 )); n=$(( n + 1 ))
        if [ "$row" -gt "$body" ]; then
            sleep 0.25
            for (( j=btop; j<=body; j++ )); do printf '\033[%d;1H\033[K' "$j" >&3; done
            row="$btop"
        fi
        sleep 0.1
    done
}
