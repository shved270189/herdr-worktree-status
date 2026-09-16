#!/usr/bin/env bash
# Shared helpers for the bondev.worktree-status plugin. Bash 3.2 compatible.

METADATA_SOURCE="bondev.worktree-status"
TOKEN_NAME="worktree_status"
# shellcheck disable=SC2034  # used by bin/picker
STATUS_IDS="planning in_progress review blocked done"

status_emoji() {
  case "$1" in
    planning) printf '📝' ;;
    in_progress) printf '🔨' ;;
    review) printf '👀' ;;
    blocked) printf '⛔' ;;
    done) printf '✅' ;;
    *) return 1 ;;
  esac
}

status_label() {
  case "$1" in
    planning) printf 'Planning' ;;
    in_progress) printf 'In progress' ;;
    review) printf 'Review' ;;
    blocked) printf 'Blocked' ;;
    done) printf 'Done' ;;
    *) return 1 ;;
  esac
}

die() {
  printf 'worktree-status: %s\n' "$*" >&2
  exit 1
}

herdr() {
  "${HERDR_BIN_PATH:-herdr}" "$@"
}

state_file() {
  [ -n "${HERDR_PLUGIN_STATE_DIR:-}" ] || die "HERDR_PLUGIN_STATE_DIR is not set"
  printf '%s/statuses.tsv' "$HERDR_PLUGIN_STATE_DIR"
}

# Print the first string value stored under "<key>" in a JSON document.
# Handles escaped quotes and backslashes; only for single-object responses
# where the key appears once (herdr workspace get, action context).
json_string_field() {
  local json=$1 key=$2 value
  local pattern="\"$key\":\"(([^\"\\\\]|\\\\.)*)\""
  [[ $json =~ $pattern ]] || return 1
  value=${BASH_REMATCH[1]}
  value=${value//\\\"/\"}
  value=${value//\\\\/\\}
  value=${value//\\\//\/}
  printf '%s' "$value"
}

# Print every workspace_id in a `herdr workspace list` response, one per line.
json_workspace_ids() {
  local json=$1
  local pattern='"workspace_id":"([A-Za-z0-9:_-]+)"(.*)$'
  while [[ $json =~ $pattern ]]; do
    printf '%s\n' "${BASH_REMATCH[1]}"
    json=${BASH_REMATCH[2]}
  done
}

# Stable identity for a workspace: its worktree checkout path when it has
# Git worktree provenance, otherwise the workspace id (survives a server
# restart but not closing and reopening the workspace).
workspace_key() {
  local json=$1 workspace_id=$2 path
  if path=$(json_string_field "$json" checkout_path) && [ -n "$path" ]; then
    printf '%s' "$path"
  else
    printf 'workspace:%s' "$workspace_id"
  fi
}

# Push a status to Herdr sidebar metadata; empty status clears the token.
apply_status() {
  local workspace_id=$1 status=$2 emoji
  if [ -z "$status" ]; then
    herdr workspace report-metadata "$workspace_id" --source "$METADATA_SOURCE" --clear-token "$TOKEN_NAME"
  else
    emoji=$(status_emoji "$status") || die "unknown status: $status"
    herdr workspace report-metadata "$workspace_id" --source "$METADATA_SOURCE" --token "$TOKEN_NAME=$emoji"
  fi
}

load_status() {
  local key=$1 file status stored_key
  file=$(state_file)
  [ -f "$file" ] || return 0
  while IFS=$'\t' read -r status stored_key; do
    if [ "$stored_key" = "$key" ]; then
      printf '%s' "$status"
      return 0
    fi
  done < "$file"
}

# Persist (or, with an empty status, forget) the status for a key.
save_status() {
  local key=$1 status=$2 file tmp line_status line_key
  file=$(state_file)
  mkdir -p "$(dirname "$file")"
  tmp="$file.tmp.$$"
  {
    if [ -f "$file" ]; then
      while IFS=$'\t' read -r line_status line_key; do
        [ "$line_key" = "$key" ] || printf '%s\t%s\n' "$line_status" "$line_key"
      done < "$file"
    fi
    [ -z "$status" ] || printf '%s\t%s\n' "$status" "$key"
  } > "$tmp"
  mv "$tmp" "$file"
}
