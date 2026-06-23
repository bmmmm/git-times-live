# shellcheck shell=bash
# git-times — viewport geometry helpers. Sourced by gittimes-lib.sh; never executed
# directly, and carries no `set` flags (they would leak into the caller's shell).
# Pure terminal measurement — real window size, content-column fitting, and a
# locale-independent display-width count — the primitives the renderers frame on.

# ── viewport geometry (the interactive reader frames a centered column) ───────
# Real terminal size, robust on macOS. `$(tput cols)` / `$(tput lines)` return the
# *static* terminfo default (80x24) there, not the live window: Apple's ncurses
# does not probe /dev/tty when its stdout is a pipe — and a $() capture always is.
# `stty size </dev/tty` reads the winsize straight from the controlling terminal;
# tput stays as the fallback for tty-less contexts (pipes, cron). Echoes "LINES COLS".
gn_term_size() {
    local s l c
    # Test/debug override: GIT_TIMES_LINES / GIT_TIMES_COLS pin the window so layout
    # edge cases (the live feed height, footer wrap) stay deterministic regardless of
    # the controlling tty. Either may be set alone; a non-numeric value is ignored and
    # that dimension is probed for real.
    l="${GIT_TIMES_LINES:-}"; case "$l" in ''|*[!0-9]*) l="" ;; esac
    c="${GIT_TIMES_COLS:-}";  case "$c" in ''|*[!0-9]*) c="" ;; esac
    if [ -z "$l" ] || [ -z "$c" ]; then
        # Group-redirect so the *shell's* failed-open error for </dev/tty (cron, no
        # controlling tty) is suppressed too — a bare `2>/dev/null` only silences stty.
        s="$( { stty size </dev/tty; } 2>/dev/null )"   # "rows cols", empty without a tty
        [ -z "$l" ] && { l="${s%% *}"; case "$l" in ''|*[!0-9]*) l="$( { tput lines 2>/dev/null || echo 24; } )" ;; esac; }
        [ -z "$c" ] && { c="${s##* }"; case "$c" in ''|*[!0-9]*) c="$( { tput cols  2>/dev/null || echo 80; } )" ;; esac; }
    fi
    printf '%s %s' "$l" "$c"
}
gn_term_cols() { local s; s="$(gn_term_size)"; printf '%s' "${s##* }"; }

# Fit a readable content column into the terminal: fill the width minus a side
# margin so the page never hugs the edge, but never wider than max (long lines
# read badly — newspapers keep columns narrow) nor below the floor (the renderers'
# minimum). Returns the content width; the reader centers a block of this width.
gn_fit_width() {  # gn_fit_width <cols> [maxw] [side] [floor]
    local cols="${1:-80}" maxw="${2:-140}" side="${3:-4}" floor="${4:-62}" w
    w=$(( cols - 2*side ))
    [ "$w" -gt "$maxw" ] 2>/dev/null && w="$maxw"
    [ "$w" -lt "$floor" ] 2>/dev/null && w="$floor"
    printf '%s' "$w"
}

# Left margin that centers a content column of width <cw> in <cols> columns.
gn_center_pad() {  # gn_center_pad <cols> <cw>
    local cols="${1:-80}" cw="${2:-80}" p
    p=$(( (cols - cw) / 2 )); [ "$p" -lt 0 ] 2>/dev/null && p=0
    printf '%s' "$p"
}

# Zero-width code points: combining marks, joiners, variation selectors, the
# bidi/format controls. A real wcwidth counts these as 0 columns (they stack on the
# previous glyph). Intervals follow Markus Kuhn's reference wcwidth table. Returns
# success (0) when <cp> is zero-width. Locale-independent — pure arithmetic.
_gn_zerowidth() {  # _gn_zerowidth <codepoint>
    local cp=$1
    (( (cp>=0x0300 && cp<=0x036F) || (cp>=0x0483 && cp<=0x0489) || \
       (cp>=0x0591 && cp<=0x05BD) || cp==0x05BF || (cp>=0x05C1 && cp<=0x05C2) || \
       (cp>=0x05C4 && cp<=0x05C5) || cp==0x05C7 || (cp>=0x0600 && cp<=0x0605) || \
       (cp>=0x0610 && cp<=0x061A) || (cp>=0x064B && cp<=0x065F) || cp==0x0670 || \
       (cp>=0x06D6 && cp<=0x06DC) || (cp>=0x06DF && cp<=0x06E4) || \
       (cp>=0x06E7 && cp<=0x06E8) || (cp>=0x06EA && cp<=0x06ED) || cp==0x070F || \
       cp==0x0711 || (cp>=0x0730 && cp<=0x074A) || (cp>=0x07A6 && cp<=0x07B0) || \
       (cp>=0x07EB && cp<=0x07F3) || (cp>=0x0816 && cp<=0x0819) || \
       (cp>=0x081B && cp<=0x0823) || (cp>=0x0825 && cp<=0x0827) || \
       (cp>=0x0829 && cp<=0x082D) || (cp>=0x0900 && cp<=0x0902) || cp==0x093C || \
       (cp>=0x0941 && cp<=0x0948) || cp==0x094D || (cp>=0x0951 && cp<=0x0957) || \
       (cp>=0x0962 && cp<=0x0963) || cp==0x0981 || cp==0x09BC || \
       (cp>=0x09C1 && cp<=0x09C4) || cp==0x09CD || (cp>=0x09E2 && cp<=0x09E3) || \
       (cp>=0x0A01 && cp<=0x0A02) || cp==0x0A3C || (cp>=0x0A41 && cp<=0x0A42) || \
       (cp>=0x0A47 && cp<=0x0A48) || (cp>=0x0A4B && cp<=0x0A4D) || \
       (cp>=0x0A70 && cp<=0x0A71) || (cp>=0x0A81 && cp<=0x0A82) || cp==0x0ABC || \
       (cp>=0x0AC1 && cp<=0x0AC5) || (cp>=0x0AC7 && cp<=0x0AC8) || cp==0x0ACD || \
       (cp>=0x0AE2 && cp<=0x0AE3) || cp==0x0B01 || cp==0x0B3C || cp==0x0B3F || \
       (cp>=0x0B41 && cp<=0x0B44) || cp==0x0B4D || cp==0x0B56 || cp==0x0B82 || \
       cp==0x0BC0 || cp==0x0BCD || (cp>=0x0C3E && cp<=0x0C40) || \
       (cp>=0x0C46 && cp<=0x0C48) || (cp>=0x0C4A && cp<=0x0C4D) || \
       (cp>=0x0C55 && cp<=0x0C56) || cp==0x0CBC || cp==0x0CBF || cp==0x0CC6 || \
       (cp>=0x0CCC && cp<=0x0CCD) || (cp>=0x0CE2 && cp<=0x0CE3) || \
       (cp>=0x0D41 && cp<=0x0D44) || cp==0x0D4D || cp==0x0DCA || \
       (cp>=0x0DD2 && cp<=0x0DD4) || cp==0x0DD6 || cp==0x0E31 || \
       (cp>=0x0E34 && cp<=0x0E3A) || (cp>=0x0E47 && cp<=0x0E4E) || cp==0x0EB1 || \
       (cp>=0x0EB4 && cp<=0x0EB9) || (cp>=0x0EBB && cp<=0x0EBC) || \
       (cp>=0x0EC8 && cp<=0x0ECD) || (cp>=0x0F18 && cp<=0x0F19) || cp==0x0F35 || \
       cp==0x0F37 || cp==0x0F39 || (cp>=0x0F71 && cp<=0x0F7E) || \
       (cp>=0x0F80 && cp<=0x0F84) || (cp>=0x0F86 && cp<=0x0F87) || \
       (cp>=0x0F90 && cp<=0x0F97) || (cp>=0x0F99 && cp<=0x0FBC) || cp==0x0FC6 || \
       (cp>=0x102D && cp<=0x1030) || (cp>=0x1032 && cp<=0x1037) || \
       (cp>=0x1039 && cp<=0x103A) || (cp>=0x1058 && cp<=0x1059) || \
       (cp>=0x1160 && cp<=0x11FF) || cp==0x135F || (cp>=0x1712 && cp<=0x1714) || \
       (cp>=0x1732 && cp<=0x1734) || (cp>=0x1752 && cp<=0x1753) || \
       (cp>=0x1772 && cp<=0x1773) || (cp>=0x17B4 && cp<=0x17B5) || \
       (cp>=0x17B7 && cp<=0x17BD) || cp==0x17C6 || (cp>=0x17C9 && cp<=0x17D3) || \
       cp==0x17DD || (cp>=0x180B && cp<=0x180D) || cp==0x18A9 || \
       (cp>=0x1920 && cp<=0x1922) || (cp>=0x1927 && cp<=0x1928) || cp==0x1932 || \
       (cp>=0x1939 && cp<=0x193B) || (cp>=0x1A17 && cp<=0x1A18) || \
       (cp>=0x1B00 && cp<=0x1B03) || cp==0x1B34 || (cp>=0x1B36 && cp<=0x1B3A) || \
       cp==0x1B3C || cp==0x1B42 || (cp>=0x1B6B && cp<=0x1B73) || \
       (cp>=0x1DC0 && cp<=0x1DFF) || (cp>=0x200B && cp<=0x200F) || \
       (cp>=0x202A && cp<=0x202E) || (cp>=0x2060 && cp<=0x2063) || \
       (cp>=0x206A && cp<=0x206F) || (cp>=0x20D0 && cp<=0x20EF) || \
       (cp>=0x302A && cp<=0x302F) || (cp>=0x3099 && cp<=0x309A) || \
       (cp>=0xFE00 && cp<=0xFE0F) || (cp>=0xFE20 && cp<=0xFE26) || cp==0xFEFF || \
       (cp>=0xFFF9 && cp<=0xFFFB) || (cp>=0x1D167 && cp<=0x1D169) || \
       (cp>=0x1D173 && cp<=0x1D182) || (cp>=0x1D185 && cp<=0x1D18B) || \
       (cp>=0x1D1AA && cp<=0x1D1AD) || (cp>=0x1D242 && cp<=0x1D244) || \
       cp==0xE0001 || (cp>=0xE0020 && cp<=0xE007F) || (cp>=0xE0100 && cp<=0xE01EF) ))
}

# Double-width (East-Asian Wide / Fullwidth) and emoji code points → 2 columns.
# Ranges per Kuhn's wide table plus the modern emoji blocks (which terminals — incl.
# Ghostty — render double-width). Returns success (0) when <cp> is double-width.
_gn_wide() {  # _gn_wide <codepoint>
    local cp=$1
    (( (cp>=0x1100 && cp<=0x115F) || cp==0x2329 || cp==0x232A || \
       (cp>=0x2E80 && cp<=0x303E) || (cp>=0x3041 && cp<=0x33FF) || \
       (cp>=0x3400 && cp<=0x4DBF) || (cp>=0x4E00 && cp<=0x9FFF) || \
       (cp>=0xA000 && cp<=0xA4CF) || (cp>=0xAC00 && cp<=0xD7A3) || \
       (cp>=0xF900 && cp<=0xFAFF) || (cp>=0xFE10 && cp<=0xFE19) || \
       (cp>=0xFE30 && cp<=0xFE6F) || (cp>=0xFF00 && cp<=0xFF60) || \
       (cp>=0xFFE0 && cp<=0xFFE6) || (cp>=0x1F300 && cp<=0x1F6FF) || \
       (cp>=0x1F900 && cp<=0x1F9FF) || (cp>=0x1FA70 && cp<=0x1FAFF) || \
       (cp>=0x20000 && cp<=0x3FFFD) ))
}

# Display width of a string in terminal columns, independent of locale. Decodes the
# UTF-8 byte stream into code points (one `od` fork — fewer than the old wc+tr+wc),
# then sums each glyph's wcwidth: 0 for combining/zero-width marks, 2 for East-Asian
# Wide/Fullwidth/emoji, 1 otherwise. Every glyph the reader uses (arrows, ·, –, ⏎,
# box-drawing, braille) is single-width, so plain renders measure as before; only
# genuinely wide or stacking glyphs now count correctly. Byte-based decoding means it
# is right even under LC_ALL=C, where ${#s} counts bytes and overstates by 2–3×.
# gn_strwidth_v writes the width into <outvar>; gn_strwidth echoes it (for $(...) call
# sites). The out-var form is the hot path: gn_footer_wrap measures ~18 segments and
# _frame measures the footer rows + fold marker on EVERY keypress, and wrapping each in
# a $() command-substitution doubles the fork count (subshell + od). Calling the out-var
# form skips the subshell — measured ~2.2x faster per repaint (22→10 ms for a 19-segment
# footer here). All internals are __-prefixed so they can never collide with the caller's
# outvar name (a plain `w`/`b`/`s` would: printf -v would write the local, not the caller).
gn_strwidth_v() {  # gn_strwidth_v <outvar> <string>
    local __ov="$1" __s="$2"
    # Pin the locale: range globs collate by code point and ${#__s} counts bytes — both
    # required by the ASCII fast path (and harmless for the byte-based od decode).
    local LC_ALL=C
    # Drop CSI SGR colour codes first so width reflects only visible glyphs — the guard
    # skips the sed fork for the common plain string (the footer wrap measures plain
    # segments, so the hot path never pays for this).
    case "$__s" in *$'\033'*) __s="$(printf '%s' "$__s" | LC_ALL=C sed $'s/\033\\[[0-9;]*m//g')" ;; esac
    # Pure printable-ASCII fast path: every byte is one column, so ${#__s} IS the width —
    # no od fork. The common case (footer hints, fold markers, picker rows).
    case "$__s" in
        *[!\ -~]*) ;;
        *) printf -v "$__ov" '%s' "${#__s}"; return 0 ;;
    esac
    # Bytes as unsigned decimals; word-splitting flattens od's 16-per-line wrapping.
    # -v is REQUIRED: without it od compresses a run of >=16 identical bytes to a "*"
    # line, and the unquoted expansion then globs that "*" against the CWD (or breaks
    # the arithmetic below under noglob) — so any multibyte string with a long repeated
    # run measures wrong, CWD-dependently. With -v the output is only digits + spaces.
    # shellcheck disable=SC2207
    local -a __B=( $(printf '%s' "$__s" | od -An -v -tu1) )
    local __i=0 __n=${#__B[@]} __w=0 __b __cp __len __j
    while (( __i < __n )); do
        __b=${__B[__i]}
        if   (( __b < 0x80 )); then __cp=$__b;              __len=1
        elif (( __b < 0xE0 )); then __cp=$(( __b & 0x1F )); __len=2
        elif (( __b < 0xF0 )); then __cp=$(( __b & 0x0F )); __len=3
        else                        __cp=$(( __b & 0x07 )); __len=4
        fi
        __j=1; while (( __j < __len && __i+__j < __n )); do __cp=$(( (__cp << 6) | (__B[__i+__j] & 0x3F) )); ((__j++)); done
        __i=$(( __i + __len ))
        if   (( __b < 0x80 )); then (( __w += 1 ))        # ASCII (escapes already gone)
        elif _gn_zerowidth "$__cp"; then :                # +0
        elif _gn_wide "$__cp"; then (( __w += 2 ))
        else (( __w += 1 ))
        fi
    done
    printf -v "$__ov" '%s' "$__w"
}
gn_strwidth() {  # gn_strwidth <string> — the $()-friendly form; echoes the width
    local __sw; gn_strwidth_v __sw "$1"; printf '%s' "$__sw"
}

# Truncate <string> to at most <max> display columns WITHOUT splitting a multibyte
# glyph — the display-aware counterpart of the byte-based ${s:0:N}. Under LC_ALL=C
# (the renderers run pinned there) ${s:0:N} counts BYTES, so a subject cut mid-UTF-8
# emits an invalid byte sequence — mojibake on the page, and straight into the shell
# prompt via the greeting. Decodes the UTF-8 stream exactly like gn_strwidth and stops
# on the last whole glyph that still fits, budgeting by column cost (0 zero-width,
# 2 wide/emoji, 1 otherwise). ASCII fast path: byte == column, so the slice is already
# correct and no od fork is paid — the common case (and what keeps the tests byte-stable).
gn_truncate_v() {  # gn_truncate_v <outvar> <string> <max-cols> — assigns; no subshell
    local LC_ALL=C
    local __ov="$1" __s="$2" __max="${3:-0}"
    case "$__max" in ''|*[!0-9]*) __max=0 ;; esac      # negative / non-numeric → empty, never a bash negative-length slice
    case "$__s" in
        *[!\ -~]*) ;;                                  # carries a non-ASCII byte → decode below
        *) printf -v "$__ov" '%s' "${__s:0:__max}"; return 0 ;;   # printable ASCII: the byte slice is the right answer
    esac
    # shellcheck disable=SC2207                          # od -v: see gn_strwidth_v (no "*" run-compression)
    local -a __B=( $(printf '%s' "$__s" | od -An -v -tu1) )
    local __i=0 __n=${#__B[@]} __w=0 __bytes=0 __b __cp __len __j __cw
    while (( __i < __n )); do
        __b=${__B[__i]}
        if   (( __b < 0x80 )); then __cp=$__b;              __len=1
        elif (( __b < 0xE0 )); then __cp=$(( __b & 0x1F )); __len=2
        elif (( __b < 0xF0 )); then __cp=$(( __b & 0x0F )); __len=3
        else                        __cp=$(( __b & 0x07 )); __len=4
        fi
        __j=1; while (( __j < __len && __i+__j < __n )); do __cp=$(( (__cp << 6) | (__B[__i+__j] & 0x3F) )); ((__j++)); done
        if   (( __b < 0x80 )); then __cw=1
        elif _gn_zerowidth "$__cp"; then __cw=0
        elif _gn_wide "$__cp"; then __cw=2
        else __cw=1
        fi
        (( __w + __cw > __max )) && break              # the next glyph would overflow → stop on the boundary
        __w=$(( __w + __cw )); __i=$(( __i + __len )); __bytes=$(( __bytes + __len ))
    done
    printf -v "$__ov" '%s' "${__s:0:__bytes}"
}
gn_truncate() {  # gn_truncate <string> <max-cols> — the $()-friendly form; echoes the result
    local __t; gn_truncate_v __t "$1" "${2:-0}"; printf '%s' "$__t"
}

# Right-pad <string> to exactly <width> DISPLAY columns, truncating first if it
# overruns — the display-aware replacement for printf '%-<width>s', whose field
# width counts BYTES (a 2-byte glyph like an umlaut then pads one column short,
# shoving every following column out of line). ASCII in is byte-identical to the
# old %-Ns, so the pinned-locale tests stay byte-stable. ell=1 trades the last
# column for an ellipsis on truncation (the leaderboard / live-feed style); ell=0
# cuts hard (the exchange style). Measures with the out-var gn_strwidth_v so the
# common no-overrun case pays no subshell and no od fork for plain ASCII.
gn_pad() {  # gn_pad <string> <width> [ellipsis:0|1]
    local s w ell cur
    s="$1"; w="${2:-0}"; ell="${3:-0}"
    case "$w" in ''|*[!0-9]*) w=0 ;; esac
    gn_strwidth_v cur "$s"
    if [ "$cur" -gt "$w" ]; then
        if [ "$ell" = 1 ] && [ "$w" -ge 1 ]; then s="$(gn_truncate "$s" "$(( w - 1 ))")…"
        else                                      s="$(gn_truncate "$s" "$w")"; fi
        gn_strwidth_v cur "$s"
    fi
    printf '%s%*s' "$s" "$(( w - cur ))" ''
}
