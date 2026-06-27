#!/usr/bin/env bash
#
# bash_unit tests for klue
#
# Run with: bash_unit tests/test_klue.sh
#

KLUE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/klue"
TEST_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_config.toml"
TEST_SESSION="klue-test"

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
    bash "$KLUE" --config "$TEST_CONFIG" &
    local pid=$!
    sleep 3

    assert "tmux has-session -t '$TEST_SESSION'" \
        "tmux session '$TEST_SESSION' should exist after startup"

    # Check window name
    local window
    window=$(tmux list-windows -t "$TEST_SESSION" -F '#{window_name}' | head -1)
    assert_equals "test-win" "$window" "window name should match config"

    # Check panes exist (config has 2 rows: 2 panes + 1 pane = 3 total)
    local pane_count
    pane_count=$(tmux list-panes -t "$TEST_SESSION:test-win" | wc -l | tr -d ' ')
    assert_equals "3" "$pane_count" "should have 3 panes"

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

# Re-attachment (session already exists)
test_reattachment_does_not_destroy_session() {
    # Start session first time
    bash "$KLUE" --config "$TEST_CONFIG" &
    local pid1=$!
    sleep 3
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Run klue again (should re-attach, not kill session)
    bash "$KLUE" --config "$TEST_CONFIG" &
    local pid2=$!
    sleep 2
    kill "$pid2" 2>/dev/null
    wait "$pid2" 2>/dev/null || true

    assert "tmux has-session -t '$TEST_SESSION'" \
        "session should still exist after re-run"
}

# Streaming
test_stream_starts_http_server() {
    # Create session first
    bash "$KLUE" --config "$TEST_CONFIG" &
    local pid1=$!
    sleep 3
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Start streaming on existing session
    bash "$KLUE" --config "$TEST_CONFIG" --stream --stream-port 5999 --stream-fps 1 &
    local stream_pid=$!
    sleep 10

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
    bash "$KLUE" --config "$TEST_CONFIG" &
    local pid1=$!
    sleep 3
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Start streaming
    bash "$KLUE" --config "$TEST_CONFIG" --stream --stream-port 5999 --stream-fps 1 &
    local stream_pid=$!
    sleep 10

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
    bash "$KLUE" --config "$TEST_CONFIG" &
    local pid1=$!
    sleep 3
    kill "$pid1" 2>/dev/null
    wait "$pid1" 2>/dev/null || true

    # Verify session exists
    assert "tmux has-session -t '$TEST_SESSION'" "session should exist"

    # Start stream (should skip layout creation, just stream)
    bash "$KLUE" --config "$TEST_CONFIG" --stream --stream-port 5999 --stream-fps 1 &
    local stream_pid=$!
    sleep 10

    # Session should still exist with same pane count
    local pane_count
    pane_count=$(tmux list-panes -t "$TEST_SESSION:test-win" | wc -l | tr -d ' ')
    assert_equals "3" "$pane_count" \
        "pane count should be preserved after stream re-attach"

    # Stream should be serving
    local http_code
    http_code=$(curl -s -o /dev/null -w "%{http_code}" http://localhost:5999/)
    assert_equals "200" "$http_code" "stream should be serving after re-attach"

    kill "$stream_pid" 2>/dev/null
    wait "$stream_pid" 2>/dev/null || true
}
