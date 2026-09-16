#!/usr/bin/env bash
# Unit-style tests: temp state dir, fake herdr binary, no running Herdr needed.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

export HERDR_PLUGIN_STATE_DIR="$tmp/state dir"
export HERDR_PLUGIN_ID="shved270189.worktree-status"
export HERDR_BIN_PATH="$tmp/fake-herdr"
export FAKE_HERDR_LOG="$tmp/herdr.log"
export FAKE_HERDR_WORKSPACES="$tmp/workspaces.json"

cat > "$HERDR_BIN_PATH" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_HERDR_LOG"
case "$1 $2" in
  "workspace list") cat "$FAKE_HERDR_WORKSPACES" ;;
  "workspace get")
    case "$3" in
      w1) printf '{"id":"cli","result":{"workspace":{"label":"a","workspace_id":"w1","worktree":{"checkout_path":"%s","is_linked_worktree":true}}}}' "$WT_A" ;;
      w2) printf '{"id":"cli","result":{"workspace":{"label":"b","workspace_id":"w2"}}}' ;;
      w3) printf '{"id":"cli","result":{"workspace":{"label":"c","workspace_id":"w3","worktree":{"checkout_path":"%s","is_linked_worktree":true}}}}' "$WT_C" ;;
      *) printf '{"error":{"code":"workspace_not_found"}}'; exit 1 ;;
    esac ;;
  "workspace report-metadata") [ "$3" != wBAD ] || exit 1 ;;
esac
FAKE
chmod +x "$HERDR_BIN_PATH"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
assert_eq() { [ "$1" = "$2" ] || fail "$3: expected [$2], got [$1]"; }
last_call() { tail -n 1 "$FAKE_HERDR_LOG"; }

. "$root/bin/lib.sh"

# --- json helpers -----------------------------------------------------------
json='{"a":"x","checkout_path":"/tmp/with space/q\"uote\\back","b":"y"}'
assert_eq "$(json_string_field "$json" checkout_path)" '/tmp/with space/q"uote\back' "json escapes"
json_string_field '{"other":"z"}' checkout_path && fail "missing key should return 1"
assert_eq "$(json_workspace_ids '{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2:x"}]}' | tr '\n' ' ')" "w1 w2:x " "workspace ids"
assert_eq "$(workspace_key '{"workspace_id":"w9"}' w9)" "workspace:w9" "fallback key"

# --- state file -------------------------------------------------------------
: > "$FAKE_HERDR_LOG"
save_status "/p/a b" in_progress
save_status "/p/c" "done"
assert_eq "$(load_status "/p/a b")" in_progress "load after save"
save_status "/p/a b" review
assert_eq "$(load_status "/p/a b")" review "overwrite"
assert_eq "$(wc -l < "$(state_file)" | tr -d ' ')" 2 "no duplicate rows"
save_status "/p/a b" ""
assert_eq "$(load_status "/p/a b")" "" "clear removes row"
assert_eq "$(load_status "/p/c")" "done" "other row untouched"

# --- apply_status -----------------------------------------------------------
apply_status w1 blocked
assert_eq "$(last_call)" "workspace report-metadata w1 --source shved270189.worktree-status --token worktree_status=⛔" "set token"
apply_status w1 ""
assert_eq "$(last_call)" "workspace report-metadata w1 --source shved270189.worktree-status --clear-token worktree_status" "clear token"
apply_status wBAD "done" && fail "herdr failure should propagate"
(apply_status w1 bogus 2>/dev/null) && fail "unknown status should fail"

# --- set-status action ------------------------------------------------------
: > "$FAKE_HERDR_LOG"
HERDR_WORKSPACE_ID=w1 HERDR_PLUGIN_CONTEXT_JSON='{"workspace_id":"w1","worktree":{"checkout_path":"/p/a b"}}' \
  bash "$root/bin/set-status"
assert_eq "$(last_call)" "plugin pane open --plugin shved270189.worktree-status --entrypoint status-picker --env WORKTREE_STATUS_WORKSPACE_ID=w1 --env WORKTREE_STATUS_KEY=/p/a b --focus" "action opens popup with env"
(HERDR_WORKSPACE_ID='' bash "$root/bin/set-status" 2>"$tmp/err") && fail "missing workspace should fail"
grep -q HERDR_WORKSPACE_ID "$tmp/err" || fail "useful error expected"

# --- picker -----------------------------------------------------------------
rm -f "$(state_file)"; : > "$FAKE_HERDR_LOG"
printf '\033[B\033[B\r' | WORKTREE_STATUS_WORKSPACE_ID=w1 WORKTREE_STATUS_KEY="/p/a b" bash "$root/bin/picker" >/dev/null
assert_eq "$(last_call)" "workspace report-metadata w1 --source shved270189.worktree-status --token worktree_status=👀" "down down enter -> review"
assert_eq "$(load_status "/p/a b")" review "picker persists"
printf 'jjj\r' | WORKTREE_STATUS_WORKSPACE_ID=w1 WORKTREE_STATUS_KEY="/p/a b" bash "$root/bin/picker" >/dev/null
assert_eq "$(last_call)" "workspace report-metadata w1 --source shved270189.worktree-status --clear-token worktree_status" "j x3 from review -> clear"
assert_eq "$(load_status "/p/a b")" "" "picker clear forgets"
save_status "/p/a b" "done"; : > "$FAKE_HERDR_LOG"
printf 'q' | WORKTREE_STATUS_WORKSPACE_ID=w1 WORKTREE_STATUS_KEY="/p/a b" bash "$root/bin/picker" >/dev/null
printf '\033' | WORKTREE_STATUS_WORKSPACE_ID=w1 WORKTREE_STATUS_KEY="/p/a b" bash "$root/bin/picker" >/dev/null
[ ! -s "$FAKE_HERDR_LOG" ] || fail "cancel must not call herdr"
assert_eq "$(load_status "/p/a b")" "done" "cancel keeps state"
printf '\r' | WORKTREE_STATUS_WORKSPACE_ID=w1 WORKTREE_STATUS_KEY="/p/a b" bash "$root/bin/picker" >/dev/null
assert_eq "$(last_call)" "workspace report-metadata w1 --source shved270189.worktree-status --token worktree_status=✅" "preselects current status"
(printf '\r' | bash "$root/bin/picker" 2>"$tmp/err") && fail "picker without env should fail"
grep -q WORKTREE_STATUS "$tmp/err" || fail "useful picker error expected"

# --- restore ----------------------------------------------------------------
export WT_A="$tmp/wt a" WT_C="$tmp/wt c"
mkdir -p "$WT_A"
printf '{"result":{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w2"},{"workspace_id":"w3"}]}}' > "$FAKE_HERDR_WORKSPACES"
rm -f "$(state_file)"
save_status "$WT_A" in_progress
save_status "workspace:w2" planning
save_status "$WT_C" "done"
save_status "$tmp/gone" review
: > "$FAKE_HERDR_LOG"
bash "$root/bin/restore-statuses"
grep -q "report-metadata w1 --source shved270189.worktree-status --token worktree_status=🔨" "$FAKE_HERDR_LOG" || fail "restore w1 by path"
grep -q "report-metadata w2 --source shved270189.worktree-status --token worktree_status=📝" "$FAKE_HERDR_LOG" || fail "restore w2 by id"
grep -q "report-metadata w3 --source shved270189.worktree-status --token worktree_status=✅" "$FAKE_HERDR_LOG" || fail "restore w3 (dir missing but open)"
assert_eq "$(load_status "$tmp/gone")" "" "missing dir pruned"
assert_eq "$(load_status "$WT_C")" "" "open workspace with missing dir pruned too"
assert_eq "$(load_status "$WT_A")" in_progress "existing dir kept"
rm -f "$(state_file)"; : > "$FAKE_HERDR_LOG"
bash "$root/bin/restore-statuses"
[ ! -s "$FAKE_HERDR_LOG" ] || fail "no state -> no herdr calls"

printf 'all tests passed\n'
