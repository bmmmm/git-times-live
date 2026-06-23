#!/usr/bin/env bash
# Collect remote activity across every forge the machine is logged into, merged
# into ONE object within [SINCE, UNTIL). Each endpoint collector auto-detects its
# own login (Forgejo: host+owner+token / tea · GitHub: gh / token · GitLab:
# glab / token) and returns the shared schema; this merges the enabled ones:
# summed counts, source-tagged events concatenated newest-first, and a sources[]
# list naming the forges that contributed. All fail-soft — a dark or erroring
# endpoint is simply skipped, never fatal.
#
# Usage: collect-remote.sh --since <epoch> [--until <epoch>]
# Output: {enabled, sources[], reason?, prs_merged, issues_closed, pushes,
#          prs_opened, issues_opened, events:[{type,repo,ts,title,source}]}

set -uo pipefail
# shellcheck source=lib/gittimes-lib.sh
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/gittimes-lib.sh"

SINCE=0; UNTIL=$(date +%s)
while [ $# -gt 0 ]; do
    case "$1" in
        --since) gn_need_val "$1" $#; SINCE="${2:-0}"; shift 2 ;;
        --until) gn_need_val "$1" $#; UNTIL="${2:-$UNTIL}"; shift 2 ;;
        *)       shift ;;
    esac
done

command -v jq >/dev/null 2>&1 || { printf '{"enabled":false,"sources":[],"reason":"jq-missing","prs_merged":0,"issues_closed":0,"pushes":0,"prs_opened":0,"issues_opened":0,"events":[]}'; exit 0; }

# Run the endpoint collectors in parallel — each forge call is network-bound, so
# wall time is max(forge), not the sum. Each prints its object (enabled true or
# false) into its own temp file; a hard-disabled endpoint (GIT_TIMES_<EP>=0) is
# skipped before launch.
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/gt-remote.XXXXXX")"
pids=()
# ${pids[@]+…} guard: empty-array expansion is an error under set -u on bash <4.4
trap 'kill ${pids[@]+"${pids[@]}"} 2>/dev/null; rm -rf "$tmpd"; exit 143' INT TERM
for ep in forgejo github gitlab; do
    var="GIT_TIMES_$(printf '%s' "$ep" | tr '[:lower:]' '[:upper:]')"
    [ "${!var:-}" = 0 ] && continue   # bash-native indirection — no eval needed
    if [ "${GIT_TIMES_DEBUG:-0}" = 1 ]; then
        # keep the forge stderr (auth/rate-limit detail) instead of eating it
        bash "$DIR/collect-$ep.sh" --since "$SINCE" --until "$UNTIL" > "$tmpd/$ep.json" &
    else
        bash "$DIR/collect-$ep.sh" --since "$SINCE" --until "$UNTIL" 2>/dev/null > "$tmpd/$ep.json" &
    fi
    pids+=($!)
done
wait ${pids[@]+"${pids[@]}"}
parts="$(cat "$tmpd"/*.json 2>/dev/null)"
rm -rf "$tmpd"

# Merge the enabled endpoints. No enabled source → a single disabled object whose
# reason names the endpoints that were tried (so the renderer can show why).
printf '%s\n' "$parts" | jq -s '
    (map(select(type=="object")) ) as $all
    | ($all | map(select(.enabled==true))) as $on
    | if ($on|length)==0 then
        { enabled:false, sources:[],
          reason:(($all|map(.source // "remote")|join("+")) as $tried
                  | if $tried=="" then "no-endpoint" else "dark:\($tried)" end),
          prs_merged:0, issues_closed:0, pushes:0, prs_opened:0, issues_opened:0, events:[] }
      else
        { enabled:true,
          sources:       ($on | map(.source // "remote") | unique),
          # any forge whose feed came back incomplete (rate limit, page error)
          truncated:     ($on | map(.truncated // false) | any),
          prs_merged:    ($on | map(.prs_merged)    | add),
          issues_closed: ($on | map(.issues_closed) | add),
          pushes:        ($on | map(.pushes)        | add),
          prs_opened:    ($on | map(.prs_opened)    | add),
          issues_opened: ($on | map(.issues_opened) | add),
          # per-forge action tally so the renderer can show a Forgejo-vs-GitHub split
          # bar — the summed totals above lose which forge did what.
          by_source:     ($on | map({source:(.source // "remote"),
                                      actions:((.pushes//0)+(.prs_merged//0)+(.issues_closed//0))})
                              | sort_by(-.actions)),
          events:        ($on | map(.events[]?) | sort_by(-.ts) | .[0:16]) }
      end
'
