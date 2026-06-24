#!/usr/bin/env bash
# Usage adapter: Claude Code transcripts → normalized token-usage buckets.
#
# One of the A.I.-desk source adapters (collect-usage-<src>.sh). Reads the local
# Claude Code transcript tree (~/.claude/projects/*/*.jsonl) and emits, on stdout,
# the windowed buckets the orchestrator (collect-usage.sh) tags and prices:
#
#   {"buckets":[ {date,repo,model,input,output,cache_read,cache_write_5m,
#                 cache_write_1h,web_search,web_fetch,requests,sessions:[id,...]} ]}
#
# date = UTC calendar day of the message (timestamp[0:10]) — deterministic and
# TZ-pin-safe; repo = basename(cwd), matching collect-local naming so the desk
# rows line up with the git desks. No billing channel and no cost here — those are
# the orchestrator's job; this adapter only normalizes raw counts.
#
# Performance: an incremental index ($GIT_TIMES_HOME/usage/claude.json) keyed by
# each transcript's mtime+size. Unchanged files are reused from the index; only
# new/changed files are re-parsed (one batched jq over them via input_filename).
# The first run parses every transcript (one-off, can take a moment on a big tree);
# later runs touch only what moved.
#
# Fail-soft: a missing dir, missing jq, or an unreadable transcript yields an empty
# desk, never an error. Always exits 0.
#
# Usage: collect-usage-claude.sh --since <epoch> --until <epoch>
#                                [--dir <transcript-root>] [--index <index.json>]

set -uo pipefail
# shellcheck source=lib/gittimes-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gittimes-lib.sh"

SINCE=0; UNTIL=$(date +%s)
DIR="$GIT_TIMES_USAGE_CLAUDE_DIR"
INDEX="$GIT_TIMES_HOME/usage/claude.json"
while [ $# -gt 0 ]; do
    case "$1" in
        --since) gn_need_val "$1" $#; SINCE="${2:-0}"; shift 2 ;;
        --until) gn_need_val "$1" $#; UNTIL="${2:-$UNTIL}"; shift 2 ;;
        --dir)   gn_need_val "$1" $#; DIR="${2:-}"; shift 2 ;;
        --index) gn_need_val "$1" $#; INDEX="${2:-}"; shift 2 ;;
        *)       shift ;;
    esac
done
case "$SINCE" in ''|*[!0-9]*) SINCE=0 ;; esac
case "$UNTIL" in ''|*[!0-9]*) UNTIL=$(date +%s) ;; esac

# Any failure past this point still prints a well-formed empty desk.
command -v jq >/dev/null 2>&1 || { printf '{"buckets":[]}'; exit 0; }
[ -n "$DIR" ] && [ -d "$DIR" ] || { printf '{"buckets":[]}'; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gt-usage.XXXXXX")" || { printf '{"buckets":[]}'; exit 0; }
trap 'rm -rf "$WORK" 2>/dev/null' EXIT

# stat(1) is BSD on macOS (-f), GNU on Linux (-c). Detect once, like gn_date.
if stat -f '%m' . >/dev/null 2>&1; then _STAT=bsd; else _STAT=gnu; fi
list_files() {  # → "<mtime> <size> <path>" lines for every transcript
    if [ "$_STAT" = bsd ]; then
        find "$DIR" -name '*.jsonl' -type f -exec stat -f '%m %z %N' {} +
    else
        find "$DIR" -name '*.jsonl' -type f -exec stat -c '%Y %s %n' {} +
    fi
}

# Per-file record extractor, applied to a batch of transcripts at once. Read raw
# lines (-R) and parse each with fromjson? so ONE malformed line — common at the
# tail of a live, still-being-written transcript — is skipped, not fatal to the
# whole batch (plain `jq -n [inputs]` aborts the entire stream on the first parse
# error). input_filename tags each line with its source so one jq call covers the
# batch. The cache-write split falls back to the flat cache_creation_input_tokens
# when the 5m/1h breakdown is absent (older logs); 0 is truthy for jq // so a real
# 0 in the breakdown is kept, not overridden. No apostrophes in comments below —
# they live inside a bash single-quoted jq string.
GT_PARSE='
  [ inputs
    | fromjson?
    | select(type=="object" and .type=="assistant" and (.message.usage | type=="object"))
    | .message.usage as $u
    | { file:  input_filename,
        date:  ((.timestamp // "")[0:10]),
        repo:  ((.cwd // "") | split("/") | (.[-1] // "") | if . == "" then "unknown" else . end),
        model: (.message.model // "unknown"),
        sid:   (.sessionId // "?"),
        input:  ($u.input_tokens // 0),
        output: ($u.output_tokens // 0),
        cread:  ($u.cache_read_input_tokens // 0),
        cw5:    ($u.cache_creation.ephemeral_5m_input_tokens // $u.cache_creation_input_tokens // 0),
        cw1:    ($u.cache_creation.ephemeral_1h_input_tokens // 0),
        ws:     ($u.server_tool_use.web_search_requests // 0),
        wf:     ($u.server_tool_use.web_fetch_requests // 0) }
    | select(.date != "") ]
  | group_by(.file)
  | map({ file: .[0].file,
          buckets: ( group_by([.date, .repo, .model])
            | map({ date:.[0].date, repo:.[0].repo, model:.[0].model,
                    input:(map(.input)|add), output:(map(.output)|add),
                    cache_read:(map(.cread)|add),
                    cache_write_5m:(map(.cw5)|add), cache_write_1h:(map(.cw1)|add),
                    web_search:(map(.ws)|add), web_fetch:(map(.wf)|add),
                    requests: length,
                    sessions: (map(.sid)|unique) }) ) })
  | .[]
'

# ── load the previous index (or an empty one) ────────────────────────────────
OLD='{"files":{}}'
if [ -f "$INDEX" ]; then
    _o="$(cat "$INDEX" 2>/dev/null)"
    if printf '%s' "$_o" | jq -e '.files' >/dev/null 2>&1; then OLD="$_o"; fi
fi

# ── manifest of current transcripts (NDJSON {path,mtime,size}) ───────────────
list_files | jq -Rc 'split(" ") | select(length>=3)
    | {mtime:(.[0]|tonumber), size:(.[1]|tonumber), path:(.[2:]|join(" "))}' \
    > "$WORK/manifest.ndjson" 2>/dev/null || true
[ -s "$WORK/manifest.ndjson" ] || { printf '{"buckets":[]}'; exit 0; }

# ── stale = new or mtime/size-changed since the last index ────────────────────
jq -c --argjson old "$OLD" --slurpfile m "$WORK/manifest.ndjson" -n '
    ($old.files // {}) as $of
    | $m[]
    | . as $cur
    | ($of[$cur.path] // null) as $e
    | select($e == null or $e.mtime != $cur.mtime or $e.size != $cur.size)
' > "$WORK/stale.ndjson" 2>/dev/null || true

# ── re-parse only the stale files (one batched jq over all of them) ───────────
: > "$WORK/parsed_buckets.ndjson"
if [ -s "$WORK/stale.ndjson" ]; then
    # NUL-separate paths so xargs is safe; guard the empty case (BSD xargs lacks -r
    # and would run jq with no files, hanging on stdin).
    jq -r '.path' "$WORK/stale.ndjson" | tr '\n' '\0' \
        | xargs -0 jq -ncR "$GT_PARSE" > "$WORK/parsed_buckets.ndjson" 2>/dev/null || true
fi

# ── rebuild the index: reuse unchanged entries, splice in the re-parsed ones ──
jq -nc --argjson old "$OLD" \
    --slurpfile m "$WORK/manifest.ndjson" \
    --slurpfile s "$WORK/stale.ndjson" \
    --slurpfile b "$WORK/parsed_buckets.ndjson" '
    ($old.files // {}) as $of
    | ([$m[].path] | map({key:., value:true}) | from_entries) as $present
    | ([$s[].path] | map({key:., value:true}) | from_entries) as $stale
    | ([$b[] | {key:.file, value:.buckets}] | from_entries) as $bm
    # keep old entries that still exist and were not re-parsed
    | ($of | with_entries(select($present[.key] and ($stale[.key] | not)))) as $reused
    # the re-parsed entries, attaching mtime/size from the stale manifest
    | ([$s[] | {key:.path, value:{mtime:.mtime, size:.size, buckets:($bm[.path] // [])}}] | from_entries) as $fresh
    | {version:1, files: ($reused + $fresh)}
' > "$WORK/index.new" 2>/dev/null || true

# Persist the index atomically and keep a path to the authoritative copy for the
# emit step (file-based, not a shell var — the index can be multi-MB). A read-only
# cache dir (e.g. the Claude Code sandbox) just skips the write; FINAL then stays
# the freshly built in-WORK copy, so this run is still correct, only uncached.
FINAL="$WORK/index.new"
if [ -s "$WORK/index.new" ]; then
    _id="$(dirname "$INDEX")"
    # Stage through a UNIQUE temp in the index dir, not a fixed $INDEX.tmp: two collects
    # racing on the same index (a background greeting refresh + an interactive open) would
    # otherwise cp into the same staging path and corrupt each other. mktemp there keeps
    # the publish a same-dir atomic rename; a failed cp/mv drops the temp, never an orphan.
    if mkdir -p "$_id" 2>/dev/null && [ -w "$_id" ] && _it="$(mktemp "$INDEX.XXXXXX" 2>/dev/null)"; then
        if cp "$WORK/index.new" "$_it" 2>/dev/null && mv "$_it" "$INDEX" 2>/dev/null; then
            FINAL="$INDEX"
        else
            rm -f "$_it" 2>/dev/null
        fi
    fi
else
    # rebuild produced nothing → fall back to the previous index for this run
    printf '%s' "$OLD" > "$WORK/index.fallback"; FINAL="$WORK/index.fallback"
fi
jq -e '.files' "$FINAL" >/dev/null 2>&1 || { printf '{"files":{}}' > "$WORK/index.empty"; FINAL="$WORK/index.empty"; }

# ── emit the buckets inside the [since, until] window (UTC calendar days) ─────
SINCE_D="$(jq -nr --argjson s "$SINCE" '$s | strftime("%Y-%m-%d")' 2>/dev/null)"
UNTIL_D="$(jq -nr --argjson u "$UNTIL" '$u | strftime("%Y-%m-%d")' 2>/dev/null)"
jq -c --arg s "$SINCE_D" --arg u "$UNTIL_D" '
    { buckets: [ (.files // {})[].buckets[]? | select(.date >= $s and .date <= $u) ] }
' "$FINAL" 2>/dev/null || printf '{"buckets":[]}'
