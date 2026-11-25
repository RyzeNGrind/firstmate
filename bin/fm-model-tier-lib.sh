#!/usr/bin/env bash
# fm-model-tier-lib.sh - model-tier detection, reasoning-effort defaults, and
# MCP-first fast-context discovery helpers for Firstmate.
#
# Sourced by bin/fm-session-start.sh, bin/fm-bearings-snapshot.sh,
# bin/fm-pass-digest.sh, and bin/fm-spawn.sh. Safe to source multiple times;
# keeps all functions Bash 3.2+ portable and side-effect-free on load.

if [ -n "${_FM_MODEL_TIER_LIB_LOADED:-}" ]; then
  return 0 2>/dev/null || exit 0
fi
_FM_MODEL_TIER_LIB_LOADED=1

_fm_mt_lower() {
  printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

_fm_mt_read_first_token() {  # <file>
  local file=$1 line token
  [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    line=$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    [ -n "$line" ] || continue
    token=${line%%[[:space:]]*}
    printf '%s\n' "$token"
    return 0
  done < "$file"
  return 1
}

_fm_mt_config_dir() {
  if [ -n "${CONFIG:-}" ]; then
    printf '%s\n' "$CONFIG"
  elif [ -n "${FM_CONFIG_OVERRIDE:-}" ]; then
    printf '%s\n' "$FM_CONFIG_OVERRIDE"
  elif [ -n "${FM_HOME:-}" ]; then
    printf '%s/config\n' "$FM_HOME"
  elif [ -n "${FM_ROOT:-}" ]; then
    printf '%s/config\n' "$FM_ROOT"
  else
    printf ''
  fi
}

# fm_detect_model_name: best-effort detection of the active session model.
# Precedence: explicit FM_MODEL > harness model env vars > home config >
# Codex config.toml (only when Codex is the active harness or no Claude env).
fm_detect_model_name() {
  local cfg_dir tok codex_cfg model_val
  for model_val in \
    "${FM_MODEL:-}" \
    "${CLAUDE_MODEL:-}" \
    "${ANTHROPIC_MODEL:-}" \
    "${CODEX_MODEL:-}" \
    "${OPENAI_MODEL:-}" \
    "${PI_MODEL:-}" \
    "${OPENCODE_MODEL:-}" \
    "${GEMINI_MODEL:-}"; do
    if [ -n "$model_val" ]; then
      printf '%s\n' "$model_val"
      return 0
    fi
  done

  cfg_dir=$(_fm_mt_config_dir)
  if [ -n "$cfg_dir" ]; then
    if tok=$(_fm_mt_read_first_token "$cfg_dir/primary-model" 2>/dev/null) && [ -n "$tok" ]; then
      printf '%s\n' "$tok"
      return 0
    fi
    if tok=$(_fm_mt_read_first_token "$cfg_dir/model" 2>/dev/null) && [ -n "$tok" ]; then
      printf '%s\n' "$tok"
      return 0
    fi
  fi

  codex_cfg="${FM_CODEX_CONFIG:-${HOME:-}/.codex/config.toml}"
  if [ "${PRIMARY_HARNESS:-}" = "codex" ] || { [ -z "${CLAUDECODE:-}${CLAUDE_CODE_ENTRYPOINT:-}" ] && [ -z "${PRIMARY_HARNESS:-}" ]; }; then
    if [ -r "$codex_cfg" ]; then
      model_val=$(sed -n 's/^[[:space:]]*model[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$codex_cfg" 2>/dev/null | head -n 1)
      if [ -n "$model_val" ]; then
        printf '%s\n' "$model_val"
        return 0
      fi
    fi
  fi
  return 1
}

# fm_model_is_fast_name <model>: exit 0 if <model> is a fast/smaller-tier model
# (Luna, Haiku, Flash, Mini, Nano) that benefits from compact prompts, cached
# supervision passes, and low/medium reasoning effort.
fm_model_is_fast_name() {
  local norm
  norm=$(_fm_mt_lower "${1:-}")
  [ -n "$norm" ] || return 1
  case "$norm" in
    *luna*|*haiku*|*flash*|*-mini|*-mini-*|*-mini/*|*/mini|mini|*-nano|*-nano-*|*-nano/*|*/nano|nano)
      return 0
      ;;
  esac
  return 1
}

# fm_model_tier: prints "fast" or "standard".
# Explicit FM_MODEL_TIER or config/model-tier always takes precedence over
# auto-detection from the active model name.
fm_model_tier() {
  local raw cfg_dir model_name
  raw=$(_fm_mt_lower "${FM_MODEL_TIER:-}")
  if [ -z "$raw" ]; then
    cfg_dir=$(_fm_mt_config_dir)
    if [ -n "$cfg_dir" ]; then
      raw=$(_fm_mt_read_first_token "$cfg_dir/model-tier" 2>/dev/null || true)
      raw=$(_fm_mt_lower "$raw")
    fi
  fi
  case "$raw" in
    fast|compact|luna|haiku|small|lite)
      printf 'fast\n'
      return 0
      ;;
    standard|full|default|heavy|opus|sonnet|sol)
      printf 'standard\n'
      return 0
      ;;
  esac

  model_name=$(fm_detect_model_name 2>/dev/null || true)
  if fm_model_is_fast_name "$model_name"; then
    printf 'fast\n'
  else
    printf 'standard\n'
  fi
}

fm_model_is_fast() {
  [ "$(fm_model_tier)" = "fast" ]
}

# fm_model_recommended_effort <model>: prints a safe default reasoning effort
# ("low") for fast-tier models (Luna/Haiku/Flash/Mini/Nano) when the caller did
# not explicitly pin --effort or a config effort token. Returns 1 for standard
# models so their harness defaults remain unchanged.
fm_model_recommended_effort() {
  if fm_model_is_fast_name "${1:-}"; then
    printf 'low\n'
    return 0
  fi
  return 1
}

fm_mcp_gateway_url() {
  local cfg_dir val
  if [ -n "${MCP_GATEWAY_URL:-}" ]; then
    printf '%s\n' "$MCP_GATEWAY_URL"
    return 0
  fi
  cfg_dir=$(_fm_mt_config_dir)
  if [ -n "$cfg_dir" ] && val=$(_fm_mt_read_first_token "$cfg_dir/mcp-gateway-url" 2>/dev/null) && [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi
  printf 'https://mcp.nixify.dev\n'
}

fm_graphify_url() {
  local cfg_dir val
  if [ -n "${GRAPHIFY_URL:-}" ]; then
    printf '%s\n' "$GRAPHIFY_URL"
    return 0
  fi
  cfg_dir=$(_fm_mt_config_dir)
  if [ -n "$cfg_dir" ] && val=$(_fm_mt_read_first_token "$cfg_dir/graphify-url" 2>/dev/null) && [ -n "$val" ]; then
    printf '%s\n' "$val"
    return 0
  fi
  printf 'https://graphify.nixify.dev\n'
}

# fm_mcp_endpoints_hint: concise MCP-first & batched-pass guidance emitted in
# fast-tier mode so Luna/Haiku avoid 8-12 serial grep/shell turns per pass.
fm_mcp_endpoints_hint() {
  local gw graph model tier
  gw=$(fm_mcp_gateway_url)
  graph=$(fm_graphify_url)
  tier=$(fm_model_tier)
  model=$(fm_detect_model_name 2>/dev/null || true)
  printf 'FAST-TIER SUPERVISION MODE (tier=%s model=%s):\n' "$tier" "${model:-auto}"
  printf '  - One-call pass digest: run bin/fm-pass-digest.sh (batched readiness + wake peek + cached bearings in <50ms).\n'
  printf '  - MCP-first discovery: query Graphify (%s) and MCP Gateway (%s) in 1 structured call before falling back to serial grep/shell sweeps.\n' "$graph" "$gw"
  printf '  - Keep reasoning effort low/medium for routine wake/bearings turns; escalate only on complex debugging or architecture.\n'
}
