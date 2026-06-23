#!/usr/bin/env bash
# git-times-live — hermetic, headless static smoke test.
#
# GENERATED FILE — do not hand-edit. Emitted by scripts/build-live-dist.sh in
# the git-times source tree. Regenerate to update.
#
# This does NOT run the live loop: the broadcast is wall-clock driven and spawns
# background jobs, so it cannot run in a sandbox / CI without a real tty. Instead
# it verifies STATICALLY — bash -n of every script, source-closure presence,
# --help / --version behaviour, and a secret/host/home leak scan.
#
# NOTE — the one live runtime check (capturing a single ON AIR frame) must be run
# OUTSIDE the sandbox by the operator, on a real terminal:
#
#   printf 'q' | GIT_TIMES_HOME=$TMPDIR/gtl ./git-times-live --scope local --no-color
#
# That should paint one frame and quit; the smoke below deliberately stops short
# of it.

set -uo pipefail

ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENTRY="$ROOT/git-times-live"
LIBDIR="$ROOT/lib"

FAIL=0
pass() { printf '  ok   %s\n' "$1"; }
fail() { printf '  FAIL %s\n' "$1"; FAIL=1; }

printf 'git-times-live smoke (static, headless)\n'

# 1. bash -n the entry and every lib file.
if bash -n "$ENTRY" 2>/dev/null; then pass "bash -n git-times-live"; else fail "bash -n git-times-live"; fi
for f in "$LIBDIR"/*.sh; do
    if bash -n "$f" 2>/dev/null; then pass "bash -n lib/$(basename "$f")"; else fail "bash -n lib/$(basename "$f")"; fi
done

# 2. Source-closure: every `. "$GN_LIB_DIR/<x>"` / `. "$DIR/<x>"` target exists in lib/.
#    (archive.sh is sourced behind a `[ -f ]` guard and is intentionally absent.)
miss=0
while IFS= read -r tgt; do
    [ -z "$tgt" ] && continue
    [ "$tgt" = "archive.sh" ] && continue
    if [ ! -f "$LIBDIR/$tgt" ]; then fail "closure missing: lib/$tgt"; miss=1; fi
done < <(grep -rhoE '\. "\$(GN_LIB_DIR|DIR)/[A-Za-z0-9_./-]+\.sh"' "$LIBDIR" \
            | sed -E 's#.*/([A-Za-z0-9_.-]+\.sh)".*#\1#' | sort -u)
[ "$miss" = 0 ] && pass "source closure complete"

# 2b. Function-reachability: the closure check proves SOURCE FILES exist, but a
#     copied-but-unsourced fragment still leaves its functions undefined. live.sh
#     is a sourced-only fragment (no shebang/set flags) defining live_broadcast,
#     sourced by the ENTRY (not by gittimes-lib.sh); bash -n cannot resolve a
#     runtime call, so a dropped source slips past every check above yet dies at
#     runtime. Replay the entry's own source lines and assert it actually resolves.
# Build the verifier here (single-quoted grep pattern — a `\$` nested inside a
# `bash -c "…"` collapses to a literal `$`, an ERE end-anchor → zero matches).
reach_home="$(mktemp -d "${TMPDIR:-/tmp}/gtl-smoke-reach.XXXXXX")"
reach_script="$reach_home/reach.sh"
{
    printf 'set +u\n'
    printf 'DIR=%q\n' "$ROOT"
    printf 'GN_LIB_DIR=%q\n' "$LIBDIR"
    grep -E '^[[:space:]]*\.[[:space:]]+"\$(DIR|GN_LIB_DIR)/' "$ENTRY"
    printf 'declare -F live_broadcast >/dev/null\n'
} > "$reach_script"
if GIT_TIMES_HOME="$reach_home/home" bash "$reach_script" >/dev/null 2>&1; then
    pass "live_broadcast resolves via the entry source chain"
else
    fail "live_broadcast UNREACHABLE — entry missing a source (e.g. . \"\$GN_LIB_DIR/live.sh\")"
fi
rm -rf "$reach_home"

# 3. --help and --version exit 0 and print expected text.
set +e
OUT="$("$ENTRY" --help 2>&1)"; RC=$?
set -u
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'live broadcast'; then
    pass "--help exits 0 with usage text"
else
    fail "--help (rc=$RC)"
fi

set +e
OUT="$("$ENTRY" --version 2>&1)"; RC=$?
set -u
if [ "$RC" = 0 ] && printf '%s' "$OUT" | grep -q 'generated from git-times'; then
    pass "--version exits 0 with provenance"
else
    fail "--version (rc=$RC)"
fi

# 4. Bad --scope exits 2 with an actionable message.
set +e
OUT="$("$ENTRY" --scope bogus 2>&1)"; RC=$?
set -u
if [ "$RC" = 2 ] && printf '%s' "$OUT" | grep -q 'unknown --scope'; then
    pass "--scope bogus rejected (rc 2)"
else
    fail "--scope validation (rc=$RC)"
fi

# 5. No secret / host / home / owner leak anywhere in the tracked tree.
#    Scan source files only (skip .env, the local cache, binaries, and THIS
#    file — the scanner legitimately carries the very patterns it hunts for, so
#    self-scanning would always self-flag).
LEAK=0
SELF="$(basename "${BASH_SOURCE[0]}")"
scan() {  # scan <pattern> <label>
    local hits
    # grep exits 1 on no-match; the script runs without set -e so that is harmless,
    # and `|| true` keeps it explicit for anyone who adds -e later.
    hits="$(grep -rIlE "$1" "$ROOT" \
                --exclude='.env' --exclude='.env.local' --exclude="$SELF" \
                --exclude-dir='.git' --exclude-dir='.cache' --exclude-dir='tmp' 2>/dev/null || true)"
    if [ -n "$hits" ]; then
        fail "leak ($2): $(printf '%s' "$hits" | tr '\n' ' ')"
        LEAK=1
    fi
}
# Token patterns require a realistic length so prose substrings (e.g. "desk-h"
# matching a loose "sk-") cannot self-flag.
scan '/Users/'                 'home path'
scan '/home/[a-z]'             'home path'
scan 'git\.6bm\.de'            'real forge host'
scan 'ghp_[A-Za-z0-9]{20,}'    'github token'
scan 'sk-[A-Za-z0-9]{20,}'     'api key'
scan 'eyJ[A-Za-z0-9_-]{20,}'   'jwt'
scan '@qmmq\.de|@brtsz\.de'    'operator email'
[ "$LEAK" = 0 ] && pass "no secret/host/home leak"

printf '\n'
if [ "$FAIL" = 0 ]; then
    printf 'git-times-live smoke: PASS\n'
    exit 0
else
    printf 'git-times-live smoke: FAIL\n'
    exit 1
fi
