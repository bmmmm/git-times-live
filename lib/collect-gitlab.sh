#!/usr/bin/env bash
# Collect the user's GitLab activity within [SINCE, UNTIL) as a JSON object —
# the same schema collect-forgejo.sh emits, plus "source":"gitlab".
#
# Auto-detected: uses the `glab` CLI when installed and authenticated
# (`glab auth status`), otherwise a token from the env. Host defaults to
# gitlab.com ($GIT_TIMES_GITLAB_HOST to override / for self-hosted). Fail-soft:
# no auth / network failure → {"enabled":false,reason,...}. Token never printed.
#
# Offline-testable: set GIT_TIMES_GITLAB_FIXTURE=<file> to a raw events JSON
# array and the network is skipped — the parser runs against the fixture.
#
# Usage: collect-gitlab.sh --since <epoch> [--until <epoch>]

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

disabled() { gn_collect_fail gitlab "$1"; exit 0; }  # fail-soft payload, then give up

command -v jq >/dev/null 2>&1 || { printf '{"enabled":false,"source":"gitlab","reason":"jq-missing","prs_merged":0,"issues_closed":0,"pushes":0,"prs_opened":0,"issues_opened":0,"events":[]}'; exit 0; }

HOST="${GIT_TIMES_GITLAB_HOST:-${GITLAB_HOST:-gitlab.com}}"
TOKEN="${GIT_TIMES_GITLAB_TOKEN:-${GITLAB_TOKEN:-}}"
FIX="${GIT_TIMES_GITLAB_FIXTURE:-}"

if [ -n "$FIX" ] && [ -f "$FIX" ]; then
    RAW="$(cat "$FIX")"
elif command -v glab >/dev/null 2>&1 && glab auth status >/dev/null 2>&1; then
    # glab CLI: authenticated. Its `api` subcommand targets the configured host.
    _page() { glab api "events?per_page=100&page=$1" 2>/dev/null; }
    RAW="$(gn_page_feed 3 100 _page)"
elif [ -n "$TOKEN" ]; then
    # No glab, but a token was provided: the events endpoint returns the
    # authenticated user's own events for that token. The token-bearing header goes
    # into a mode-600 -K config file (not -H on argv, where ps would expose it);
    # removed on every exit path by the trap.
    command -v curl >/dev/null 2>&1 || disabled "curl-missing"
    AUTHCF="$(mktemp "${TMPDIR:-/tmp}/gt-gl.XXXXXX")" || disabled "tmp-failed"
    printf 'header = "PRIVATE-TOKEN: %s"\n' "$TOKEN" > "$AUTHCF"
    trap 'rm -f "$AUTHCF"' EXIT INT TERM HUP
    _page() { curl -sS --max-time 5 -K "$AUTHCF" \
        -H "Accept: application/json" \
        "https://${HOST}/api/v4/events?per_page=100&page=$1" 2>/dev/null; }
    RAW="$(gn_page_feed 3 100 _page)"
else
    disabled "no-auth"
fi
[ -n "$RAW" ] || disabled "fetch-failed"

# GitLab created_at carries millis and either Z or a ±HH:MM offset — the shared
# toepoch def handles both. Map action_name + target_type to the shared counts.
printf '%s\n' "$RAW" | jq -s --argjson since "$SINCE" --argjson until "$UNTIL" "$(gn_toepoch_jq)$(gn_dark_jq)"'
    . as $pages
    # No array among the pages means every body was an API error object (HTTP 401/
    # 403/5xx; curl exits 0 on 4xx, so the error body flows through the slurp). Treat
    # the source as dark, not enabled-with-zero-activity. A genuinely empty feed is
    # [] (an array) and takes the else branch below with zero counts instead.
    | ($pages | map(select(type=="array")) | add) as $rows
    | if $rows == null then ($pages | gn_dark("gitlab"))
    else
    # A leftover object beside real rows is the mid-paging gt_truncated marker.
    ($pages | map(select(type=="object")) | length > 0) as $trunc
    | $rows
    # .ts alone is a bad dedup fallback: two distinct same-second events collapse.
    | map(. + {ts: (.created_at | (toepoch? // 0))})
    | map(select(.ts >= $since and .ts < $until))
    | unique_by(.id // "\(.action_name)|\(.created_at)|\(.project_id // "")")
    | {
        enabled: true,
        source: "gitlab",
        truncated: $trunc,
        prs_merged:    (map(select(.target_type=="MergeRequest" and (.action_name=="accepted" or .action_name=="merged"))) | length),
        issues_closed: (map(select(.target_type=="Issue" and .action_name=="closed"))   | length),
        pushes:        (map(select(.action_name|tostring|startswith("pushed")))          | length),
        prs_opened:    (map(select(.target_type=="MergeRequest" and .action_name=="opened")) | length),
        issues_opened: (map(select(.target_type=="Issue" and .action_name=="opened"))    | length),
        events: (sort_by(-.ts) | .[0:12] | map({
            type: (.action_name // "event"),
            kind: (if   (.target_type=="MergeRequest")               then "pr"
                   elif (.target_type=="Issue")                      then "issue"
                   elif (.action_name|tostring|startswith("pushed")) then "push"
                   else "other" end),
            repo: ("project " + (.project_id // 0 | tostring)),
            ts:   .ts,
            title:((.target_title // .push_data.commit_title // .action_name // "") | tostring | gsub("\n";" ") | .[0:60]),
            source:"gitlab"
        }))
      }
    end
' 2>/dev/null || disabled "parse-failed"
