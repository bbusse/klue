#!/usr/bin/env bash
#
# bash_unit tests for klue copy mode regression
#
# Run with: bash_unit tests/test_no_copy_mode.sh
#

KLUE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/klue"
TEST_CONFIG="$(mktemp)"
TEST_SESSION="klue-copy-test"

setup_suite() {
    # Kill any leftover test session
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}

teardown() {
    # Clean up test session after each test
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}

teardown_suite() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -f "$TEST_CONFIG"
}

test_klue_no_copy_mode_on_startup() {
    # Create a minimal test config
    cat > "$TEST_CONFIG" <<'EOF'
[session]
name = "klue-copy-test"
window = "test"
source = "/dev/null"

[options]
mouse = true

[[row]]
height = 5
command = [
    "echo 'pane1'",
    "echo 'pane2'",
]
EOF

    # Start klue with test config
    timeout 10 "$KLUE" --config "$TEST_CONFIG" || true

    # Give it a moment to settle
    sleep 1

    # Verify the session and window exist
    assert "tmux has-session -t $TEST_SESSION 2>/dev/null" "klue session should be created"

    # Check that panes exist (commands were sent)
    local pane_count
    pane_count=$(tmux list-panes -t "$TEST_SESSION:test" -F '#{pane_id}' 2>/dev/null | wc -l)
    assert "test $pane_count -ge 2" "should have at least 2 panes"

    # Verify commands executed (pane has output)
    local pane_output
    pane_output=$(tmux capture-pane -t "$TEST_SESSION:test.0" -p 2>/dev/null)
    assert "test -n '$pane_output'" "pane should have output from executed command"

    # Core regression: no pane should be in copy-mode
    # pane_in_mode is 1 when a pane is in any special mode (copy-mode, etc.)
    local panes_in_mode
    panes_in_mode=$(tmux list-panes -t "$TEST_SESSION:test" \
        -F '#{pane_index} #{pane_in_mode} #{pane_mode}' 2>/dev/null)
    assert_equals "" \
        "$(echo "$panes_in_mode" | awk '$2 != "0" {print $0}')" \
        "no pane should be in copy-mode or any other special mode after klue starts"
}

test_klue_send_keys_uses_literal_flag() {
    # Regression: klue must use 'send-keys -l' (literal) when sending command
    # strings to panes. Without -l, special characters trigger tmux key
    # bindings such as entering copy-mode.
    #
    # We only check lines that send a variable or quoted string — bare key
    # names like 'Enter' don't need -l.
    #
    # This is a static code check — it doesn't require a running tmux session.
    local bare_send_keys
    bare_send_keys=$(grep 'send-keys' "$KLUE" \
        | grep -v -- '-l' \
        | grep -v '^[[:space:]]*#' \
        | grep -E '"|\$' \
        || true)
    assert_equals "" "$bare_send_keys" \
        "found send-keys without -l flag (causes copy-mode): $bare_send_keys"
}
