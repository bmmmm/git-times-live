#!/usr/bin/env bash
# Collect the user's GitHub activity within [SINCE, UNTIL) as a JSON object —
# the same schema collect-forgejo.sh emits, plus "source":"github".
#
# Auto-detected: uses the `gh` CLI when it is installed and authenticated
# (`gh auth status`), otherwise a token from the env. The user login is resolved
# via `gh api user` or $GIT_TIMES_GITHUB_USER. Fail-soft: no auth / no user /
# network failure → {"enabled":false,reason,...} with zeroed counts.
# Tokens are read from env / gh and are NEVER printed.
#
# Offline-testable: set GIT_TIMES_GITHUB_FIXTURE=<file> to a raw events JSON
# array and the network is skipped — the parser runs against the fixture.
#
# Usage: collect-github.sh --since <epoch> [--until <epoch>]

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

disabled() { gn_collect_fail github "$1"; exit 0; }  # fail-soft payload, then give up

command -v jq >/dev/null 2>&1 || { printf '{"enabled":false,"source":"github","reason":"jq-missing","prs_merged":0,"issues_closed":0,"pushes":0,"prs_opened":0,"issues_opened":0,"events":[]}'; exit 0; }

USER_LOGIN="${GIT_TIMES_GITHUB_USER:-}"
TOKEN="${GIT_TIMES_GITHUB_TOKEN:-${GITHUB_TOKEN:-${GH_TOKEN:-}}}"
FIX="${GIT_TIMES_GITHUB_FIXTURE:-}"

if [ -n "$FIX" ] && [ -f "$FIX" ]; then
    RAW="$(cat "$FIX")"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    # gh CLI: authenticated. Resolve the login if not pinned, then page the feed.
    [ -n "$USER_LOGIN" ] || USER_LOGIN="$(gh api user --jq .login 2>/dev/null || true)"
    [ -n "$USER_LOGIN" ] || disabled "no-user"
    _page() { gh api "/users/${USER_LOGIN}/events?per_page=100&page=$1" 2>/dev/null; }
    RAW="$(gn_page_feed 3 100 _page)"
elif [ -n "$TOKEN" ] && [ -n "$USER_LOGIN" ]; then
    # No gh, but a token + login were provided: hit the REST API directly. The token-
    # bearing auth header goes into a mode-600 -K config file (not -H on argv, where ps
    # would expose it); removed on every exit path by the trap.
    command -v curl >/dev/null 2>&1 || disabled "curl-missing"
    AUTHCF="$(mktemp "${TMPDIR:-/tmp}/gt-gh.XXXXXX")" || disabled "tmp-failed"
    printf 'header = "Authorization: token %s"\n' "$TOKEN" > "$AUTHCF"
    trap 'rm -f "$AUTHCF"' EXIT INT TERM HUP
    _page() { curl -sS --max-time 5 -K "$AUTHCF" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/users/${USER_LOGIN}/events?per_page=100&page=$1" 2>/dev/null; }
    RAW="$(gn_page_feed 3 100 _page)"
else
    disabled "no-auth"
fi
[ -n "$RAW" ] || disabled "fetch-failed"

# GitHub timestamps are always UTC ("...Z"); the shared toepoch def parses that
# (and a trailing +/-offset, would the API ever change). Map types to shared counts.
printf '%s\n' "$RAW" | jq -s --argjson since "$SINCE" --argjson until "$UNTIL" "$(gn_toepoch_jq)$(gn_dark_jq)"'
    . as $pages
    # No array among the pages means every body was an API error object (HTTP 401/
    # 403/5xx; curl exits 0 on 4xx, so the error body flows through the slurp). Treat
    # the source as dark, not enabled-with-zero-activity. A genuinely empty feed is
    # [] (an array) and takes the else branch below with zero counts instead.
    | ($pages | map(select(type=="array")) | add) as $rows
    | if $rows == null then ($pages | gn_dark("github"))
    else
    # A leftover object beside real rows is the mid-paging gt_truncated marker.
    ($pages | map(select(type=="object")) | length > 0) as $trunc
    | $rows
    | map(. + {ts: (.created_at | (toepoch? // 0))})
    | map(select(.ts >= $since and .ts < $until))
    | unique_by(.id // "\(.type)|\(.created_at)|\(.repo.name // "")")
    | {
        enabled: true,
        source: "github",
        truncated: $trunc,
        prs_merged:    (map(select(.type=="PullRequestEvent" and .payload.action=="closed" and (.payload.pull_request.merged==true))) | length),
        issues_closed: (map(select(.type=="IssuesEvent" and .payload.action=="closed"))        | length),
        pushes:        (map(select(.type=="PushEvent"))                                         | length),
        prs_opened:    (map(select(.type=="PullRequestEvent" and .payload.action=="opened"))    | length),
        issues_opened: (map(select(.type=="IssuesEvent" and .payload.action=="opened"))         | length),
        events: (sort_by(-.ts) | .[0:12] | map({
            type: .type,
            kind: (if   .type=="PushEvent"        then "push"
                   elif .type=="PullRequestEvent" then "pr"
                   elif .type=="IssuesEvent"      then "issue"
                   else "other" end),
            repo: (.repo.name // "?"),
            ts:   .ts,
            title:(
              (if   .type=="PushEvent"        then ((.payload.commits // [] | last | .message) // "pushed")
               elif .type=="PullRequestEvent" then (.payload.pull_request.title // "pull request")
               elif .type=="IssuesEvent"      then (.payload.issue.title // "issue")
               else .type end) | tostring | gsub("\n";" ") | .[0:60]),
            source:"github"
        }))
      }
    end
' 2>/dev/null || disabled "parse-failed"
