# shellcheck shell=bash
# git-times — editorial model server helpers (engine endpoints, served-model
# discovery, reachability, warmup, reasoning-leak detection, feature provenance,
# cache-warmer state). Sourced by gittimes-lib.sh; never executed directly, no
# `set` flags (would leak to the caller). Needs the GIT_TIMES_* engine config
# baselines in scope — provided by the lib that sources this file.

# Does this engine call a model? THE single source of truth for "is an LLM
# engine" — it gates feature writing, the editorial reuse gate, the colophon's
# ✓/✗ mark and editorial.sh's fallback exit code. template/off/facts are the
# deterministic engines; everything else drafts prose with a model. These same
# engines are also exactly the ones that carry a switchable model list (live
# API discovery or a configured alias list), so `models`/the `E` picker gate
# on this too. A new engine is added HERE, in gn_engine_server/gn_served_models
# below, and in GT_ENGINE_MENU (git-times).
gn_engine_is_llm() { case "$1" in omlx|ollama|openai|anthropic|api|claude|codex) return 0 ;; *) return 1 ;; esac; }

# ── editorial model server (omlx/ollama/openai are OpenAI-compatible) ─────────
# The base URL + key for an OpenAI-compatible engine, tab-separated; empty for any
# other engine. One place that maps engine → endpoint, shared by discovery and warmup.
gn_engine_server() {  # gn_engine_server <engine>  → "<url>\t<key>"
    case "$1" in
        omlx)   printf '%s\t%s' "$GIT_TIMES_OMLX_URL"   "$GIT_TIMES_OMLX_KEY" ;;
        ollama) printf '%s\t%s' "$GIT_TIMES_OLLAMA_URL" "" ;;
        openai) printf '%s\t%s' "$GIT_TIMES_OPENAI_URL" "$GIT_TIMES_OPENAI_KEY" ;;
    esac
}

# The models an engine can switch to, one id per line — empty when there is nothing to
# switch to (server down, no key, missing curl/jq, empty list). Three transports:
#   omlx/ollama/openai  GET <base>/v1/models (OpenAI-compatible; optional bearer)
#   anthropic/api       GET api.anthropic.com/v1/models (x-api-key + version header)
#   claude/codex        no models endpoint → a configured space-separated alias list
# Short timeouts: this drives a live `E` key press, so it must never hang the reader.
# Filter a model-id stream (one per line on stdin) down to chat-capable ids: drop
# embedding models, rerankers, document converters (MarkItDown echoes the prompt back
# instead of summarising), and the stray `mlx-community` parent dir omlx lists as a
# model. Heavy/35B chat models are kept — a caller that wants them out (the bench's
# slow cold-load) opts them out itself. Shared by gn_served_models (so the reader's
# `E` picker and `models list` never offer a non-editorial model) and the bench.
gn_chat_models_only() {
    grep -ivE 'minilm|sentence-transformers|embed|markitdown|rerank|^mlx-community$'
}
# Emit a space-separated alias/id list one-per-line (the configured-list engines:
# claude, codex, and anthropic's optional allowlist). Unquoted on purpose — IFS
# word-splits the list; an empty value yields zero lines. set -f so a glob char in
# a configured id never expands against the cwd (same guard as the desk subjects).
gn_emit_word_list() { local m; set -f; for m in $1; do printf '%s\n' "$m"; done; set +f; }
gn_served_models() {  # gn_served_models <engine>
    local engine="$1" s url key cf m
    case "$engine" in
        claude) gn_emit_word_list "$GIT_TIMES_CLAUDE_MODELS"; return 0 ;;
        codex)  gn_emit_word_list "$GIT_TIMES_CODEX_MODELS";  return 0 ;;
        anthropic|api)
            # An explicit allowlist short-circuits the live catalog (30+ ids) — the same
            # curated-list pattern as claude/codex, and it needs no key or network.
            if [ -n "$GIT_TIMES_ANTHROPIC_MODELS" ]; then
                gn_emit_word_list "$GIT_TIMES_ANTHROPIC_MODELS"; return 0
            fi
            key="$GIT_TIMES_ANTHROPIC_KEY"
            [ -n "$key" ] || return 0
            command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
            cf="$(mktemp "${TMPDIR:-/tmp}/gt-mdl.XXXXXX")" || return 0
            { printf 'url = "https://api.anthropic.com/v1/models"\n'
              printf 'header = "x-api-key: %s"\n' "$key"
              printf 'header = "anthropic-version: 2023-06-01"\n'
              printf 'connect-timeout = 3\nmax-time = 8\n'; } > "$cf"
            curl -sS -K "$cf" 2>/dev/null | jq -r '.data[]?.id // empty' 2>/dev/null
            rm -f "$cf"
            return 0 ;;
        omlx|ollama|openai)
            s="$(gn_engine_server "$engine")"; [ -n "$s" ] || return 0
            url="${s%%$'\t'*}"; key="${s#*$'\t'}"
            [ -n "$url" ] || return 0
            command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 0
            cf="$(mktemp "${TMPDIR:-/tmp}/gt-mdl.XXXXXX")" || return 0
            { printf 'url = "%s/models"\n' "$url"
              printf 'connect-timeout = 2\nmax-time = 5\n'
              [ -n "$key" ] && printf 'header = "Authorization: Bearer %s"\n' "$key"; } > "$cf"
            curl -sS -K "$cf" 2>/dev/null | jq -r '.data[]?.id // empty' 2>/dev/null | gn_chat_models_only
            rm -f "$cf"
            return 0 ;;
    esac
}

# Provenance of a feature.md: an engine-written article carries a machine-readable
# HTML comment as its FIRST line — `<!-- git-times-feature engine=… model=… snap=… -->`
# (snap = a checksum of the snapshot it was drafted from, for staleness checks).
# Prints the "engine=… model=… snap=…" fields for an engine-written file, nothing for
# a hand-filed (/git-times skill) article — the writers and renderers branch on that.
gn_feature_marker() {  # gn_feature_marker <feature.md>
    local l=""
    [ -f "${1:-}" ] && IFS= read -r l < "$1" 2>/dev/null
    case "$l" in
        '<!-- git-times-feature '*' -->') l="${l#<!-- git-times-feature }"; printf '%s' "${l% -->}" ;;
    esac
}

# Can the editorial engine actually answer? rc 0 = ready. Local servers: /models
# responds with at least one model. Cloud: a key is present. CLI: the command exists.
# template/off are always ready. The cache-warmer guard and `models status` use this.
gn_editorial_reachable() {  # gn_editorial_reachable <engine>
    case "$1" in
        template|off)  return 0 ;;
        omlx|ollama)   [ -n "$(gn_served_models "$1")" ] ;;
        openai)        [ -n "$GIT_TIMES_OPENAI_KEY" ] ;;
        anthropic|api) [ -n "$GIT_TIMES_ANTHROPIC_KEY" ] ;;
        claude)        command -v "$GIT_TIMES_CLAUDE_CMD" >/dev/null 2>&1 ;;
        codex)         command -v "$GIT_TIMES_CODEX_CMD"  >/dev/null 2>&1 ;;
        *)             return 1 ;;
    esac
}

# May the previous edition's LLM editorial ride into a new snapshot unchanged?
# The gate that keeps a routine recollect from billing a slow engine (the claude
# CLI blocks ~8s) to every reader start. Reusable only when it is the same
# engine+model, it was a real engine answer (ok, never a template fallback), it
# is younger than GIT_TIMES_EDITORIAL_MAX_AGE, and the commit count moved less
# than GIT_TIMES_EDITORIAL_DELTA. Echoes the reusable .editorial object (tagged
# reused:true) on rc 0; rc != 0 means consult the engine. drafted_at (stamped by
# apply_editorial_to) anchors the age gate across reuses — generated_at moves on
# every recollect; older snapshots without it re-draft once and are then stamped.
gn_editorial_reuse() {  # gn_editorial_reuse <prev-snapshot> <new-base> <engine> <model> <now>
    local prev="$1" base="$2" engine="$3" model="$4" now="$5"
    [ -s "$prev" ] && [ -s "$base" ] || return 1
    jq -e --arg engine "$engine" --arg model "$model" \
       --argjson now "$now" --argjson maxage "$GIT_TIMES_EDITORIAL_MAX_AGE" \
       --argjson delta "$GIT_TIMES_EDITORIAL_DELTA" \
       --slurpfile base "$base" '
        (.editorial // {}) as $ed
        | ($base[0].totals.commits // 0) as $newc
        | select($ed.ok == true)
        # same edition window only — today guaranteed by the per-timeframe
        # snapshot path, asserted here so the invariant is explicit, not implied
        | select((.meta.timeframe // "") == ($base[0].meta.timeframe // ""))
        | select($ed.engine == $engine and ($ed.model // "") == $model)
        | select(($now - ($ed.drafted_at // 0)) < $maxage)
        | select((($newc - (.totals.commits // 0)) | if . < 0 then -. else . end) < $delta)
        | $ed + {reused: true}
    ' "$prev" 2>/dev/null
}

# Preload a local model into memory with a one-token round-trip, so the next real
# editorial call answers warm instead of paying the cold load. No-op (rc 0) for
# non-server engines; rc 1 if the server is down or the model is not served. The body
# is built with jq into a mode-600 temp file (no shell-quoting of the model name).
gn_model_warm() {  # gn_model_warm <engine> <model>
    local engine="$1" model="$2" s url key bf cf code
    case "$engine" in omlx|ollama) ;; *) return 0 ;; esac
    [ -n "$model" ] || return 1
    s="$(gn_engine_server "$engine")"; url="${s%%$'\t'*}"; key="${s#*$'\t'}"
    [ -n "$url" ] || return 1
    command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
    bf="$(mktemp "${TMPDIR:-/tmp}/gt-warm.XXXXXX")" || return 1
    cf="$(mktemp "${TMPDIR:-/tmp}/gt-warm.XXXXXX")" || { rm -f "$bf"; return 1; }
    jq -nc --arg m "$model" '{model:$m,max_tokens:1,messages:[{role:"user",content:"hi"}]}' > "$bf" || { rm -f "$bf" "$cf"; return 1; }
    { printf 'url = "%s/chat/completions"\n' "$url"
      printf 'header = "content-type: application/json"\n'
      printf 'data-binary = "@%s"\n' "$bf"
      printf 'connect-timeout = 3\nmax-time = 120\n'
      [ -n "$key" ] && printf 'header = "Authorization: Bearer %s"\n' "$key"; } > "$cf"
    code="$(curl -sS -o /dev/null -w '%{http_code}' -K "$cf" 2>/dev/null)"
    rm -f "$bf" "$cf"
    [ "$code" = 200 ]
}

# Reasoning/instruct models sometimes leak their scratchpad instead of the one-line
# summary ("Here's a thinking process:", "<think>…", "Okay, the user wants…"). That
# text is non-empty, so editorial.sh's _emit would otherwise cache it as a real
# editorial with a ✓ on the colophon — a lie, the model never produced a usable lead.
# Match the strong, unambiguous openers no upbeat one-line newspaper editorial would
# start with → rc 0 ("this is leaked reasoning"), so the caller falls back to the
# template (an honest ✗). Deliberately conservative: a borderline real sentence is kept
# rather than risk dropping good prose. We reject, not salvage — a model that needs a
# <think> block is the wrong tool for a single sentence anyway.
gn_looks_like_reasoning() {  # gn_looks_like_reasoning <text>   rc 0 = looks like reasoning
    local t h lead
    t="$(printf '%s' "${1:-}" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
    # A <think>…</think> block can appear anywhere — some models emit prose first, then
    # leak the scratchpad. _emit hands us the RAW (pre-_clean) output, so matching the
    # FULL text catches a late leak that _clean's 3-line cap would otherwise truncate away.
    case "$t" in *'<think>'*|*'</think>'*|*'thinking process'*) return 0 ;; esac
    # Openers anchor at the first real char, but the raw text may be wrapped in quotes or
    # carry leading whitespace — strip them (same leading set as _clean's `^["“ ]*`) so the
    # opener still matches on the uncleaned text. Typographic “ is multibyte → strip apart.
    lead="${t%%[![:space:]\"]*}"; t="${t#"$lead"}"
    case "$t" in '“'*) t="${t#“}" ;; esac
    # Only the first ~200 chars matter. Deliberately conservative: an opener that could be
    # a genuine lead ("Let me start with…", "I'll start with…", "First, in March…") is KEPT
    # — only unambiguous scratchpad/meta phrasings reject. (Apostrophes matched ASCII-only.)
    h="${t:0:200}"
    case "$h" in
        "here's a think"*|"here's my think"*|"here is a think"*|"here is my think"*) return 0 ;;
        "let me think"*|"let me first"*)                                    return 0 ;;
        "okay, the user"*|"okay, so"*|"okay, let"*|"alright, the user"*|"alright, so"*) return 0 ;;
        "the user wants"*|"the user is asking"*|"the user asked"*)           return 0 ;;
        "first, i "*|"first, i'"*)                                          return 0 ;;
        "reasoning:"*|"thinking:"*|"thought:"*)                             return 0 ;;
    esac
    return 1
}

# Cache-warmer (launchd) state for the front-page colophon — a cheap file check, no
# launchctl call so it adds no latency to a render. Echoes "on\t<interval-seconds>"
# when the agent plist is installed, "off" when it is not, or "" off macOS (no launchd
# → the field is simply omitted from the colophon).
gn_warmer_state() {
    [ "$(uname -s)" = Darwin ] || { printf ''; return; }
    local p="$HOME/Library/LaunchAgents/io.git-times.cache-warm.plist" iv
    if [ -f "$p" ]; then
        iv="$(awk '/<key>StartInterval<\/key>/{getline; gsub(/[^0-9]/,""); print; exit}' "$p" 2>/dev/null)"
        printf 'on\t%s' "${iv:-1800}"
    else
        printf 'off'
    fi
}
