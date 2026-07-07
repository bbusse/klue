#!/usr/bin/env bash
#
# bash_unit tests for klue
#
# Run with: bash_unit tests/test_klue.sh
#

KLUE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/klue"
TEST_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_config.toml"
TEST_CONFIG_5PANES="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test_config_5panes.toml"
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
    local cols=120
    if [[ "$1" == "--cols" ]]; then
        cols="$2"
        shift 2
    fi
    local -a args=("$@")

    local cmd
    cmd="bash $(printf '%q' "$KLUE")"
    for arg in "${args[@]}"; do
        cmd+=" $(printf '%q' "$arg")"
    done

    # Force adequate dimensions for tests regardless of the current terminal.
    if script --version 2>&1 | grep -q 'GNU\|util-linux'; then
        # GNU script: set pty cols/rows via stty so tmux attach doesn't reflow
        TERM="xterm-256color" COLUMNS="$cols" LINES="50" \
            script -qefc "stty cols $cols rows 50 2>/dev/null; $cmd" /dev/null &
    elif command -v script >/dev/null 2>&1; then
        # BSD script (macOS): same stty trick inside the subshell
        TERM="xterm-256color" COLUMNS="$cols" LINES="50" \
            script -q /dev/null bash -c "stty cols $cols rows 50 2>/dev/null; $cmd" &
    else
        TERM="xterm-256color" COLUMNS="$cols" LINES="50" \
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

# Pane width layout
test_pane_widths_single_row() {
    # Verify that explicit widths in a single-row config are honoured.
    # Config: one row, 5 panes, width = [66,35,0,35,0]
    # Panes 0, 1, 3 must end up at their specified widths.
    #
    # Run klue with stdin from /dev/null so that the tmux attach-session at
    # the end fails cleanly (no controlling tty) and the session is left
    # detached at its full 200-col width — no PTY reflow.

    local pid
    TERM="xterm-256color" COLUMNS="200" LINES="50" \
        bash "$KLUE" --config "$TEST_CONFIG_5PANES" </dev/null &>/dev/null &
    pid=$!

    assert "wait_for_session 12" \
        "tmux session should exist after startup"
    assert "wait_for_pane_count 5 12" \
        "should have 5 panes"

    # Poll until pane 0 reaches its target width — klue applies resize-pane
    # after all splits, so this may lag slightly behind pane creation.
    local deadline=$((SECONDS + 10))
    while ((SECONDS < deadline)); do
        local probe
        probe=$(tmux list-panes -t "$TEST_SESSION:$TEST_WINDOW" \
            -F '#{pane_width}' 2>/dev/null | head -1)
        [[ "$probe" == "66" ]] && break
        sleep 0.2
    done

    local -a widths=()
    while IFS= read -r w; do
        widths+=("$w")
    done < <(tmux list-panes -t "$TEST_SESSION:$TEST_WINDOW" \
        -F '#{pane_width}' 2>/dev/null)

    assert_equals "66" "${widths[0]}" \
        "pane 0 width should be 66 (got ${widths[0]:-?})"
    assert_equals "35" "${widths[1]}" \
        "pane 1 width should be 35 (got ${widths[1]:-?})"
    assert_equals "35" "${widths[3]}" \
        "pane 3 width should be 35 (got ${widths[3]:-?})"

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

# Copy-mode guard
test_no_copy_mode_on_startup() {
    # Regression guard: no pane should enter copy-mode when klue starts.
    local pid
    pid=$(run_klue_bg --config "$TEST_CONFIG")

    assert "wait_for_session 12" \
        "tmux session should exist after startup"
    assert "wait_for_pane_count 3 12" \
        "should have 3 panes"
    sleep 1

    local panes_in_mode
    panes_in_mode=$(tmux list-panes -t "$TEST_SESSION:$TEST_WINDOW" \
        -F '#{pane_index} #{pane_in_mode} #{pane_mode}' 2>/dev/null)
    assert_equals "" \
        "$(printf '%s\n' "$panes_in_mode" | awk '$2 != "0" {print $0}')" \
        "no pane should be in copy-mode or any other special mode"

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null || true
}

test_send_keys_uses_literal_flag() {
    # Static guard: every send-keys call that passes a variable or quoted
    # string as the CONTENT (last argument) must use the -l (literal) flag.
    # Key names like 'Enter' do not need -l and are excluded by checking only
    # the last token on each line.
    local bare_send_keys
    bare_send_keys=$(grep 'send-keys' "$KLUE" \
        | grep -v -- '-l' \
        | grep -v '^[[:space:]]*#' \
        | awk 'NF>0 { last=$NF; if (last ~ /["\$]/) print }' \
        || true)
    assert_equals "" "$bare_send_keys" \
        "found send-keys without -l flag (causes copy-mode): $bare_send_keys"
}

# Container tests
# Require a built klue container image (podman or docker).

CONTAINER_IMAGE="${KLUE_TEST_IMAGE:-klue}"

_container_runtime() {
    if command -v podman >/dev/null 2>&1; then
        printf 'podman'
    elif command -v docker >/dev/null 2>&1; then
        printf 'docker'
    else
        printf ''
    fi
}

_container_run() {
    local runtime
    runtime=$(_container_runtime)
    "$runtime" run --rm --entrypoint "" "$CONTAINER_IMAGE" sh -c "$1"
}

_skip_if_no_container() {
    local runtime
    runtime=$(_container_runtime)
    if [[ -z "$runtime" ]]; then
        skip "no container runtime (podman/docker) available"
    fi
    if ! "$runtime" image exists "$CONTAINER_IMAGE" 2>/dev/null \
       && ! "$runtime" inspect "$CONTAINER_IMAGE" >/dev/null 2>&1; then
        skip "container image '$CONTAINER_IMAGE' not found — build it first"
    fi
}

test_container_image_exists() {
    _skip_if_no_container
    local runtime
    runtime=$(_container_runtime)
    assert "$runtime image exists '$CONTAINER_IMAGE' 2>/dev/null \
            || $runtime inspect '$CONTAINER_IMAGE' >/dev/null 2>&1" \
        "container image '$CONTAINER_IMAGE' should exist"
}

test_container_runs_as_non_root() {
    _skip_if_no_container
    local uid
    uid=$(_container_run 'id -u')
    assert "test '$uid' -ne 0" \
        "container should not run as root (uid=$uid)"
}

test_container_user_is_klue() {
    _skip_if_no_container
    local user
    user=$(_container_run 'id -un')
    assert_equals "klue" "$user" "container user should be 'klue'"
}

test_container_aws_cli_works() {
    _skip_if_no_container
    local out
    out=$(_container_run 'aws --version 2>&1')
    assert_matches "aws-cli" "$out" "aws --version should print version string"
}

test_container_jq_works() {
    _skip_if_no_container
    local out
    out=$(_container_run 'jq --version')
    assert_matches "jq-" "$out" "jq --version should print version string"
}

test_container_kubectl_present() {
    _skip_if_no_container
    local out
    out=$(_container_run 'kubectl version --client --output=yaml 2>&1 || kubectl version --client 2>&1')
    assert_matches "gitVersion" "$out" \
        "kubectl --client should print version info"
}

test_container_textimg_present() {
    _skip_if_no_container
    local out
    out=$(_container_run 'textimg --version 2>&1')
    assert_matches "textimg" "$out" "textimg should be present and print version"
}

test_container_tmux_present() {
    _skip_if_no_container
    local out
    out=$(_container_run 'tmux -V')
    assert_matches "tmux" "$out" "tmux should be present"
}

test_container_zsh_present() {
    _skip_if_no_container
    local out
    out=$(_container_run 'zsh --version')
    assert_matches "zsh" "$out" "zsh should be present"
}

test_container_vju_t_present() {
    _skip_if_no_container
    assert "_container_run 'test -x /usr/local/bin/vju-t'" \
        "vju-t binary should be present at /usr/local/bin/vju-t"
}

test_container_klue_help() {
    _skip_if_no_container
    local out
    out=$(_container_run '/usr/local/bin/klue --help 2>&1 || true')
    assert_matches "Usage: klue" "$out" \
        "klue --help should print usage information"
}

test_container_awsh_scripts_present() {
    _skip_if_no_container
    local count
    count=$(_container_run 'find /usr/local/src/awsh -maxdepth 1 -type f -name "aws-*" | wc -l | tr -d " "')
    assert "test '$count' -gt 0" \
        "awsh scripts should be present in /usr/local/src/awsh (found $count)"
}

test_container_k8sh_present() {
    _skip_if_no_container
    assert "_container_run 'test -f /usr/local/src/k8sh/k8sh'" \
        "k8sh script should be present at /usr/local/src/k8sh/k8sh"
}

test_container_pyqdd_scripts_present() {
    _skip_if_no_container
    local count
    count=$(_container_run 'find /usr/local/src/pyqdd -maxdepth 1 -type f -name "*.py" | wc -l | tr -d " "')
    assert "test '$count' -gt 0" \
        "pyqdd Python scripts should be present in /usr/local/src/pyqdd (found $count)"
}

test_container_venv_python_works() {
    _skip_if_no_container
    local out
    out=$(_container_run 'python3 -c "import botocore; print(botocore.__version__)"')
    assert_matches "[0-9]" "$out" \
        "python3 should be able to import botocore via PYTHONPATH (got: $out)"
}

test_container_stays_alive() {
    # Regression guard: container must not exit (SIGKILL/crash) after startup.
    # Runs klue in non-stream mode (same as STREAM=false in the run script) and
    # verifies the container is still running after 10 seconds.
    _skip_if_no_container

    local runtime container_id
    runtime=$(_container_runtime)

    container_id=$("$runtime" run -d \
        -v "$TEST_CONFIG:/etc/klue/config.toml:ro" \
        --entrypoint /usr/local/bin/klue \
        "$CONTAINER_IMAGE" \
        --config /etc/klue/config.toml \
        2>/dev/null) || {
        assert_fail "container failed to start"
        return
    }

    sleep 10

    local status
    status=$("$runtime" inspect "$container_id" \
        --format '{{.State.Status}}' 2>/dev/null || printf "gone")

    "$runtime" rm -f "$container_id" >/dev/null 2>&1 || true

    assert_equals "running" "$status" \
        "container should still be running after 10 s (was: $status)"
}

test_container_stays_alive_after_exec_detach() {
    # Regression guard: container must survive an exec+detach cycle.
    # Simulates the run script: attach via exec, detach, verify container lives.
    _skip_if_no_container

    local runtime container_id
    runtime=$(_container_runtime)

    container_id=$("$runtime" run -d \
        -v "${TEST_CONFIG}:/etc/klue/config.toml:ro" \
        --entrypoint /usr/local/bin/klue \
        "$CONTAINER_IMAGE" \
        --config /etc/klue/config.toml \
        2>/dev/null) || {
        assert_fail "container failed to start"
        return
    }

    # Wait for session
    local deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        "$runtime" exec "$container_id" tmux list-sessions >/dev/null 2>&1 && break
        sleep 0.3
    done

    # Attach briefly via exec, then disconnect
    "$runtime" exec "$container_id" tmux attach-session -d 2>/dev/null || true

    sleep 5

    local status
    status=$("$runtime" inspect "$container_id" \
        --format '{{.State.Status}}' 2>/dev/null || printf "gone")

    "$runtime" rm -f "$container_id" >/dev/null 2>&1 || true

    assert_equals "running" "$status" \
        "container should survive exec+detach (was: $status)"
}

test_container_stream_stays_alive() {
    # Regression guard: container must survive in streaming mode.
    _skip_if_no_container

    local runtime stream_port container_id
    runtime=$(_container_runtime)
    stream_port=15997

    container_id=$("$runtime" run -d \
        -p "${stream_port}:${stream_port}" \
        -v "${TEST_CONFIG}:/etc/klue/config.toml:ro" \
        --entrypoint /usr/local/bin/klue \
        "$CONTAINER_IMAGE" \
        --config /etc/klue/config.toml \
        --stream --stream-port "${stream_port}" --stream-fps 1 \
        2>/dev/null) || {
        assert_fail "container failed to start in stream mode"
        return
    }

    # Wait for HTTP server to come up (up to 30 s)
    local deadline=$((SECONDS + 30))
    local http_code="000"
    while ((SECONDS < deadline)); do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://localhost:${stream_port}/" 2>/dev/null || true)
        [[ "$http_code" == "200" ]] && break
        sleep 0.5
    done

    # Simulate exec attach+detach
    "$runtime" exec "$container_id" tmux attach-session -d 2>/dev/null || true

    sleep 5

    local status
    status=$("$runtime" inspect "$container_id" \
        --format '{{.State.Status}}' 2>/dev/null || printf "gone")

    "$runtime" rm -f "$container_id" >/dev/null 2>&1 || true

    assert_equals "200" "$http_code" \
        "stream HTTP server should have responded 200 (got $http_code)"
    assert_equals "running" "$status" \
        "streaming container should survive exec+detach (was: $status)"
}

test_container_stream_http_200() {    _skip_if_no_container

    local runtime stream_port container_id
    runtime=$(_container_runtime)
    stream_port=15998

    container_id=$("$runtime" run -d \
        -p "${stream_port}:${stream_port}" \
        -v "${TEST_CONFIG}:/etc/klue/config.toml:ro" \
        --entrypoint /usr/local/bin/klue \
        "$CONTAINER_IMAGE" \
        --config /etc/klue/config.toml \
        --stream --stream-port "${stream_port}" --stream-fps 1 \
        2>/dev/null) || {
        assert_fail "container failed to start"
        return
    }

    local deadline=$((SECONDS + 30))
    local http_code="000"
    while ((SECONDS < deadline)); do
        http_code=$(curl -s -o /dev/null -w "%{http_code}" \
            "http://localhost:${stream_port}/" 2>/dev/null || true)
        [[ "$http_code" == "200" ]] && break
        sleep 0.5
    done

    "$runtime" rm -f "$container_id" >/dev/null 2>&1 || true

    assert_equals "200" "$http_code" \
        "container MJPEG HTTP server should respond 200 (got $http_code)"
}
