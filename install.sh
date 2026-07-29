#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
key_file="$root_dir/api.txt"
example_key="paste-your-agentrouter-api-key-here"

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

needs_key=1
if [ -n "${AGENTROUTER_API_KEY:-}" ]; then
    needs_key=0
    echo "Using AGENTROUTER_API_KEY from the environment."
elif [ -f "$key_file" ]; then
    current_key=$(tr -d '\r\n' < "$key_file")
    if [ -n "$current_key" ] && [ "$current_key" != "$example_key" ]; then
        needs_key=0
        echo "Existing api.txt found; keeping it."
    fi
fi

if [ "$needs_key" -eq 1 ]; then
    printf "Paste your AgentRouter API key: "
    trap 'stty echo 2>/dev/null || true' EXIT INT TERM
    stty -echo
    IFS= read -r api_key
    stty echo
    trap - EXIT INT TERM
    printf "\n"
    if [ -z "$api_key" ]; then
        echo "The API key cannot be empty." >&2
        exit 1
    fi
    umask 077
    printf "%s" "$api_key" > "$key_file"
    unset api_key
    chmod 600 "$key_file"
    echo "API key saved to ignored local file api.txt."
fi

"$python_cmd" -m unittest discover -s "$root_dir/tests" -v
chmod +x "$root_dir/start-agentrouter-proxy.sh" "$root_dir/stop-agentrouter-proxy.sh"
"$root_dir/start-agentrouter-proxy.sh"
"$python_cmd" "$root_dir/check-setup.py"

cat <<'EOF'

9Router provider settings:
  Name:       AgentRouter Local
  Prefix:     ar
  API Type:   Chat Completions
  Base URL:   http://127.0.0.1:4182/v1
  API Key:    local-proxy
  Test model: claude-opus-5

Installation is complete.
EOF
