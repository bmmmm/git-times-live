#!/usr/bin/env bash
# Collect the user's Forgejo activity within [SINCE, UNTIL) as a JSON object.
# Fail-soft: when the host/owner/token is missing or the network fails, returns
# {"enabled":false,...} with zeroed counts so downstream never needs null-guards.
# The token is read from env or tea's config and is NEVER printed.
#
# Usage: collect-forgejo.sh --since <epoch> [--until <epoch>]
# Output: {enabled, reason?, prs_merged, issues_closed, pushes,
#          prs_opened, issues_opened, events:[{type,repo,ts,title}]}

set -uo pipefail
# shellcheck source=lib/gittimes-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/gittimes-lib.sh"

SINCE=0; UNTIL=$(date +%s)
while [ $# -gt 0 ]; do
    case "$1" in
        --since) gn_need_val "$1" $#; SINCE="${2:-0}"; shift 2 ;;
        --until) gn_need_val "$1" $#; UNTIL="${2:-$UNTIL}"; shift 2 ;;
        *)       shift ;;
    esac
done

disabled() { gn_collect_fail forgejo "$1"; exit 0; }  # fail-soft payload, then give up

command -v jq   >/dev/null 2>&1 || { printf '{"enabled":false,"source":"forgejo","reason":"jq-missing","prs_merged":0,"issues_closed":0,"pushes":0,"prs_opened":0,"issues_opened":0,"events":[]}'; exit 0; }
command -v curl >/dev/null 2>&1 || disabled "curl-missing"

HOST="$GIT_TIMES_FORGEJO_HOST"; OWNER="$GIT_TIMES_FORGEJO_OWNER"
[ -n "$HOST" ]  || disabled "no-host"
[ -n "$OWNER" ] || disabled "no-owner"

# Resolve token: explicit env first, then tea's config (plain-text, never echoed).
TOKEN="${GIT_TIMES_FORGEJO_TOKEN:-${FORGEJO_TOKEN:-}}"
if [ -z "$TOKEN" ]; then
    for p in "$HOME/Library/Application Support/tea/config.yml" "$HOME/.config/tea/config.yml"; do
        [ -f "$p" ] || continue
        TOKEN="$(grep -F -A5 "$HOST" "$p" 2>/dev/null | grep 'token:' | head -1 \
                 | sed 's/.*token:[[:space:]]*//' | tr -d '[:space:]"' || true)"
        [ -n "$TOKEN" ] && break
    done
fi
[ -n "$TOKEN" ] || disabled "no-token"

# The auth header carries the token, so it goes into a mode-600 -K config file (mktemp
# creates it 0600) instead of -H on argv, where `ps` would expose it. A literal " or \
# in a token would corrupt its quoted value, but forgejo tokens are [A-Za-z0-9]. Removed
# on every exit path (incl. a signal mid-fetch) by the trap.
AUTHCF="$(mktemp "${TMPDIR:-/tmp}/gt-fj.XXXXXX")" || disabled "tmp-failed"
printf 'header = "Authorization: token %s"\n' "$TOKEN" > "$AUTHCF"
trap 'rm -f "$AUTHCF"' EXIT INT TERM HUP
# Fetch up to 4 pages of the user's own feed; stop early once a page predates the
# window. Concatenate into one array.
_page() { curl -sS --max-time 4 -K "$AUTHCF" \
    -H "Accept: application/json" \
    "https://${HOST}/api/v1/users/${OWNER}/activities/feeds?only-performed-by=true&limit=50&page=$1" \
    2>/dev/null; }
# stop paging once the oldest row in a page is already before the window
_predates() {  # _predates <page-body> — true when this page's oldest row < SINCE
    local oldest
    oldest="$(printf '%s' "$1" | jq -r 'def te: .[0:19]|strptime("%Y-%m-%dT%H:%M:%S")|mktime; try (map(.created|(te? // 0))|min) catch 0' 2>/dev/null || echo 0)"
    [ "${oldest:-0}" -lt "$SINCE" ]
}
RAW="$(gn_page_feed 4 50 _page _predates)"
[ -n "$RAW" ] || disabled "fetch-failed"

printf '%s\n' "$RAW" | jq -s --argjson since "$SINCE" --argjson until "$UNTIL" "$(gn_toepoch_jq)$(gn_dark_jq)"'
    # Forgejo activity .content is not a plain title: issue/PR actions carry a JSON
    # array [index, title] (title often empty), pushes carry {Commits:[...]}. Map each
    # to a human label so downstream (the paper wire + live broadcast) never shows raw
    # structured content. A plain-string content (branch ops, etc.) passes through.
    def gt_title:
        (.content // "") as $c
        | ($c | (fromjson? // .)) as $j
        | (if ($j | type) == "array" then
               (($j[1] // "") | tostring) as $t
               | (if ($t | length) > 0 then $t
                  else (($j[0] // "") | tostring) as $i
                       | (if ($i | length) > 0 then "#\($i)" else "" end) end)
           elif ($j | type) == "object" then
               (($j.Commits // []) | length) as $n
               | (if $n > 0
                  then (($j.HeadCommit.Message // ($j.Commits[-1].Message // "")) | tostring | split("\n")[0])
                  else "" end)
           else ($j | tostring) end)
        | gsub("\n"; " ") | .[0:60];
    . as $pages
    # No array among the pages means every body was an API error object (HTTP 401/
    # 403/5xx; curl exits 0 on 4xx, so the error body flows through the slurp). Treat
    # the source as dark, not enabled-with-zero-activity. A genuinely empty feed is
    # [] (an array) and takes the else branch below with zero counts instead.
    | ($pages | map(select(type=="array")) | add) as $rows
    | if $rows == null then ($pages | gn_dark("forgejo"))
    else
    # A leftover object beside real rows is the mid-paging gt_truncated marker.
    ($pages | map(select(type=="object")) | length > 0) as $trunc
    | $rows
    # .ts alone is a bad dedup fallback: two distinct same-second events collapse.
    | map(. + {ts: (.created | (toepoch? // 0))})
    | map(select(.ts >= $since and .ts < $until))
    | unique_by(.id // "\(.op_type)|\(.created)|\(.repo.full_name // .repo.name // "")")
    | {
        enabled: true,
        source: "forgejo",
        truncated: $trunc,
        prs_merged:    (map(select(.op_type=="merge_pull_request")) | length),
        issues_closed: (map(select(.op_type=="close_issue"))        | length),
        pushes:        (map(select(.op_type=="commit_repo"))        | length),
        prs_opened:    (map(select(.op_type=="create_pull_request"))| length),
        issues_opened: (map(select(.op_type=="create_issue"))       | length),
        events: (sort_by(-.ts) | .[0:12] | map({
            type: .op_type,
            kind: ((.op_type // "") as $o
                   | if   ($o|test("comment")) then "other"
                     elif ($o|test("pull"))    then "pr"
                     elif ($o|test("issue"))   then "issue"
                     elif ($o=="commit_repo")  then "push"
                     else "other" end),
            repo: (.repo.full_name // .repo.name // "?"),
            ts:   .ts,
            title: gt_title,
            source:"forgejo"
        }))
      }
    end
' 2>/dev/null || disabled "parse-failed"
