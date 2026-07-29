#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pid_file="$root_dir/.agentrouter-proxy.pid"
stdout_log="$root_dir/agentrouter-proxy.log"
stderr_log="$root_dir/agentrouter-proxy-error.log"

if command -v python3 >/dev/null 2>&1; then
    python_cmd=python3
else
    python_cmd=python
fi

if [ -f "$pid_file" ]; then
    old_pid=$(cat "$pid_file")
    if kill -0 "$old_pid" 2>/dev/null; then
        echo "AgentRouter proxy is already running (PID $old_pid)."
        exit 0
    fi
    rm -f "$pid_file"
fi

if [ -z "${AGENTROUTER_API_KEY:-}" ] && [ ! -f "$root_dir/api.txt" ]; then
    echo "API key not found. Run ./install.sh first." >&2
    exit 1
fi

nohup "$python_cmd" "$root_dir/agentrouter-proxy.py" \
    --host 127.0.0.1 \
    --port 4182 \
    --key-file "$root_dir/api.txt" \
    >"$stdout_log" 2>"$stderr_log" &
proxy_pid=$!
printf "%s" "$proxy_pid" > "$pid_file"

attempt=0
while [ "$attempt" -lt 20 ]; do
    if ! kill -0 "$proxy_pid" 2>/dev/null; then
        echo "AgentRouter proxy failed to start. See $stderr_log" >&2
        exit 1
    fi
    if "$python_cmd" -c \
        'import urllib.request; urllib.request.urlopen("http://127.0.0.1:4182/health", timeout=1).read()' \
        >/dev/null 2>&1; then
        echo "AgentRouter proxy started (PID $proxy_pid) on http://127.0.0.1:4182."
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 0.25
done

kill "$proxy_pid" 2>/dev/null || true
echo "AgentRouter proxy did not become healthy. See $stderr_log" >&2
exit 1
