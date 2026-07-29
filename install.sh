#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

if [ "${1:-}" = "--background" ]; then
    shift
elif command -v systemctl >/dev/null 2>&1 && [ -d /run/systemd/system ]; then
    exec "$root_dir/install-systemd.sh" "$@"
fi

if [ "$#" -gt 0 ]; then
    echo "Unknown option: $1" >&2
    echo "Use --background to bypass automatic systemd installation." >&2
    exit 2
fi

if command -v python3 >/dev/null 2>&1; then
    python_cmd=python3
elif command -v python >/dev/null 2>&1; then
    python_cmd=python
else
    echo "Python 3.11 or newer is required." >&2
    exit 1
fi

"$python_cmd" -c '
import sys
if sys.version_info < (3, 11):
    raise SystemExit("Python 3.11 or newer is required")
print(f"Python {sys.version.split()[0]} found")
'

"$python_cmd" -m unittest discover -s "$root_dir/tests" -v
chmod +x \
    "$root_dir/start-agentrouter-proxy.sh" \
    "$root_dir/stop-agentrouter-proxy.sh" \
    "$root_dir/install-systemd.sh"
"$root_dir/start-agentrouter-proxy.sh"
"$python_cmd" "$root_dir/check-setup.py"

cat <<'EOF'

9Router provider settings:
  Name:       AgentRouter Local
  Prefix:     ar
  API Type:   Chat Completions
  Base URL:   http://127.0.0.1:4182/v1
  API Key:    YOUR_AGENTROUTER_API_KEY
  Test model: claude-opus-5

Store the real AgentRouter API key in 9Router's API Key field.
Installation is complete.
EOF
