#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
pid_file="$root_dir/.agentrouter-proxy.pid"

if [ ! -f "$pid_file" ]; then
    echo "No proxy PID file was found. The proxy may already be stopped."
    exit 0
fi

proxy_pid=$(cat "$pid_file")
case "$proxy_pid" in
    *[!0-9]*|'')
        echo "Invalid PID file: $pid_file" >&2
        exit 1
        ;;
esac

if kill -0 "$proxy_pid" 2>/dev/null; then
    command_line=$(ps -p "$proxy_pid" -o command= 2>/dev/null || true)
    case "$command_line" in
        *agentrouter-proxy.py*)
            kill "$proxy_pid"
            echo "AgentRouter proxy stopped (PID $proxy_pid)."
            ;;
        *)
            echo "PID $proxy_pid belongs to another process; refusing to stop it." >&2
            exit 1
            ;;
    esac
else
    echo "Proxy process $proxy_pid is no longer running."
fi

rm -f "$pid_file"
