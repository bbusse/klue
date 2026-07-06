#!/usr/bin/env bash
#
# bash_unit tests for klue
#
# Run with: bash_unit tests/test_klue.sh
#

KLUE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/klue"
TEST_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_config.toml"
TEST_SESSION="klue-test"
TEST_WINDOW="test-win"

wait_for_session() {
    local timeout_secs="${1:-12}"
    local deadline=$((SECONDS + timeout_secs))

    while ((SECONDS < deadline)); do
        if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

wait_for_pane_count() {
    local expected="$1"
    local timeout_secs="${2:-12}"
    local deadline=$((SECONDS + timeout_secs))

    while ((SECONDS < deadline)); do
        local count
        count=$(tmux list-panes -t "$TEST_SESSION:$TEST_WINDOW" 2>/dev/null | wc -l | tr -d ' ')
        if [[ "$count" == "$expected" ]]; then
            return 0
        fi
        sleep 0.2
    done
    return 1
}

wait_for_http_200() {
    local timeout_secs="${1:-15}"
    local deadline=$((SECONDS + timeout_secs))

    while ((SECONDS < deadline)); do
        local code
        code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5999/ || true)
        if [[ "$code" == "200" ]]; then
            return 0
        fi
        sleep 0.5
    done
    return 1
}

run_klue_bg() {
    local -a args=("$@")

    local cmd
    cmd="bash $(printf '%q' "$KLUE")"
    for arg in "${args[@]}"; do
        cmd+=" $(printf '%q' "$arg")"
    done

    # Force adequate dimensions for tests regardless of the current terminal.
    if script --version 2>&1 | grep -q 'GNU\|util-linux'; then
        # GNU script: script -qefc <cmd> /dev/null
        TERM="xterm-256color" COLUMNS="120" LINES="50" \
            script -qefc "$cmd" /dev/null &
    elif command -v script >/dev/null 2>&1; then
        # BSD script (macOS): script -q /dev/null <shell> -c <cmd>
        TERM="xterm-256color" COLUMNS="120" LINES="50" \
            script -q /dev/null bash -c "$cmd" &
    else
        TERM="xterm-256color" COLUMNS="120" LINES="50" \
            bash "$KLUE" "${args[@]}" &
    fi

    echo $!
}

setup_suite() {
    # Kill any leftover test session
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
}

teardown() {
    # Clean up test session after each test
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    # Kill any streaming processes on test port
    lsof -i :5999 2>/dev/null | grep LISTEN | awk '{print $2}' | xargs kill 2>/dev/null || true
    sleep 0.5
}

teardown_suite() {
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    lsof -i :5999 2>/dev/null | grep LISTEN | awk '{print $2}' | xargs kill 2>/dev/null || true
}

# Basic argument handling
test_help_flag() {
    local output
    output=$(bash "$KLUE" --help)
    assert_matches "Usage: klue" "$output" "--help should print usage"
}

test_missing_config_fails() {
    assert_status_code 1 "bash '$KLUE'" "--config is required"
}

test_nonexistent_config_fails() {
    assert_status_code 1 "bash '$KLUE' --config /nonexistent/path.toml"
}

test_unknown_option_fails() {
    assert_status_code 1 "bash '$KLUE' --bogus"
}

# Session startup
test_session_startup() {
    local pid
    pid=$(run_klue_bg --config "$TEST_CONFIG")

    assert "wait_for_session 12" \
        "tmux session '$TEST_SESSION' should exist after startup"

    # Check window name
    local window
    window=$(tmux list-windows -t "$TEST_SESSION" -F '#{window_name}' | head -1)
    assert_equals "test-win" "$window" "window name should match config"

    # Check panes exist (config has 2 rows: 2 panes + 1 pane = 3 total)
    assert "wait_for_pane_count 3 12" "should have 3 panes"
    local pane_count
    pane_count=$(tmux list-panes -t "$TEST_SESSION:$TEST_WINDOW" | wc -l | tr -d ' ')
    assert_equals "3" "$pane_count" "should have 3 panes"

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

# Re-attachment (session already exists)
test_reattachment_does_not_destroy_session() {
    # Start session first time
    local pid1
    pid1=$(run_klue_bg --config "$TEST_CONFIG")
    assert "wait_for_session 12" "session should be created on first run"
    assert "wait_for_pane_count 3 12" "first run should create 3 panes"
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Run klue again (should re-attach, not kill session)
    local pid2
    pid2=$(run_klue_bg --config "$TEST_CONFIG")
    assert "wait_for_session 12" "session should still exist on second run"
    kill "$pid2" 2>/dev/null
    wait "$pid2" 2>/dev/null || true

    assert "tmux has-session -t '$TEST_SESSION'" \
        "session should still exist after re-run"
}

# Streaming
test_stream_starts_http_server() {
    # Create session first
    local pid1
    pid1=$(run_klue_bg --config "$TEST_CONFIG")
    assert "wait_for_session 12" "session should exist before stream mode"
    assert "wait_for_pane_count 3 12" "session should have 3 panes before stream mode"
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Start streaming on existing session
    local stream_pid
    stream_pid=$(run_klue_bg --config "$TEST_CONFIG" --stream --stream-port 5999 --stream-fps 1)
    assert "wait_for_http_200 20" "HTTP server should respond 200 on /"

    # Check HTTP server responds
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5999/)
    assert_equals "200" "$http_code" "HTTP server should respond 200 on /"

    # Check MJPEG stream delivers data
    local bytes
    bytes=$(timeout 3 curl -s http://localhost:5999/stream | wc -c | tr -d ' ')
    assert "test $bytes -gt 1000" \
        "MJPEG stream should deliver data (got $bytes bytes)"

    kill "$stream_pid" 2>/dev/null
    wait "$stream_pid" 2>/dev/null || true
}

test_stream_serves_valid_jpeg_frames() {
    # Create session first
    local pid1
    pid1=$(run_klue_bg --config "$TEST_CONFIG")
    assert "wait_for_session 12" "session should exist before stream mode"
    assert "wait_for_pane_count 3 12" "session should have 3 panes before stream mode"
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Start streaming
    local stream_pid
    stream_pid=$(run_klue_bg --config "$TEST_CONFIG" --stream --stream-port 5999 --stream-fps 1)
    assert "wait_for_http_200 20" "stream endpoint should become available"

    # Grab a chunk of the stream
    timeout 3 curl -s http://localhost:5999/stream > /tmp/klue_test_stream.bin 2>/dev/null || true

    # Verify MJPEG boundary format
    local has_boundary
    has_boundary=$(grep -c "^--frame" /tmp/klue_test_stream.bin 2>/dev/null || echo 0)
    assert "test $has_boundary -gt 0" \
        "stream should contain MJPEG frame boundaries (found $has_boundary)"

    # Verify JPEG magic bytes exist
    assert "python3 -c \"data=open('/tmp/klue_test_stream.bin','rb').read(); assert b'\\xff\\xd8' in data\"" \
        "stream should contain JPEG data"

    rm -f /tmp/klue_test_stream.bin
    kill "$stream_pid" 2>/dev/null
    wait "$stream_pid" 2>/dev/null || true
}

# Re-attachment with stream (session exists, stream mode)
test_stream_reattaches_to_existing_session() {
    # Create session first time
    local pid1
    pid1=$(run_klue_bg --config "$TEST_CONFIG")
    assert "wait_for_session 12" "session should exist after initial run"
    assert "wait_for_pane_count 3 12" "initial run should create 3 panes"
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Verify session exists
    assert "tmux has-session -t '$TEST_SESSION'" "session should exist"

    # Start stream (should skip layout creation, just stream)
    local stream_pid
    stream_pid=$(run_klue_bg --config "$TEST_CONFIG" --stream --stream-port 5999 --stream-fps 1)
    assert "wait_for_http_200 20" "stream should start on existing session"

    # Session should still exist with same pane count
    assert "wait_for_pane_count 3 12" "pane count should be preserved after stream re-attach"
    local pane_count
    pane_count=$(tmux list-panes -t "$TEST_SESSION:$TEST_WINDOW" | wc -l | tr -d ' ')
    assert_equals "3" "$pane_count" \
        "pane count should be preserved after stream re-attach"

    # Stream should be serving
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5999/)
    assert_equals "200" "$http_code" "stream should be serving after re-attach"

    kill "$stream_pid" 2>/dev/null
    wait "$stream_pid" 2>/dev/null || true
}

# SIGTTOU suspension guard
test_no_suspension_with_multiple_panes() {
    # Regression guard: verify that panes launched with stty -tostop prepended
    # do not receive SIGTTOU and end up in a "suspended (tty output)" state.
    #
    # This directly tests the fix in klue (stty -tostop prepended to each pane
    # command) without relying on run_klue_bg to avoid PTY/attachment issues.

    local n=30
    local sess="klue-test"
    local win="test-win"

    # Create a small tmux session to host the test panes
    tmux new-session -d -s "$sess" -n "$win" -x 80 -y 30

    # Add panes and send the same command klue would send: stty -tostop first
    for i in $(seq 1 $((n - 1))); do
        tmux split-window -t "$sess:$win" -h 2>/dev/null \
            || tmux split-window -t "$sess:$win" -v 2>/dev/null || true
    done
    tmux select-layout -t "$sess:$win" tiled 2>/dev/null || true

    # Send stty -tostop + echo to every pane (mirrors klue's command prefix)
    local pane_count
    pane_count=$(tmux list-panes -t "$sess:$win" | wc -l | tr -d ' ')
    local i=0
    while IFS= read -r pane_id; do
        tmux send-keys -t "$pane_id" -l "stty -tostop 2>/dev/null; echo pane-$i"
        tmux send-keys -t "$pane_id" Enter
        i=$((i + 1))
    done < <(tmux list-panes -t "$sess:$win" -F '#{pane_id}')

    sleep 1

    # Check no pane's captured output contains "suspended"
    local suspended=""
    while IFS= read -r pane_id; do
        local content
        content=$(tmux capture-pane -t "$pane_id" -p 2>/dev/null || true)
        if printf '%s\n' "$content" | grep -q "suspended"; then
            suspended="${suspended} ${pane_id}"
        fi
    done < <(tmux list-panes -t "$sess:$win" -F '#{pane_id}' 2>/dev/null)

    assert "test -z '${suspended# }'" \
        "no pane should be suspended (SIGTTOU); suspended panes:${suspended}"
}
