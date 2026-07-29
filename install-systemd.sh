#!/usr/bin/env sh
set -eu

root_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
host=127.0.0.1
port=4182
upstream=https://agentrouter.org
service_name=agentrouter-proxy
skip_tests=false
uninstall=false

usage() {
    cat <<'EOF'
Usage: ./install-systemd.sh [options]

Options:
  --host ADDRESS       Listen address (default: 127.0.0.1)
  --port PORT          Listen port (default: 4182)
  --upstream URL       AgentRouter HTTPS URL
  --service-name NAME  systemd unit prefix (default: agentrouter-proxy)
  --skip-tests         Skip offline unit tests
  --uninstall          Remove the installed systemd units
  -h, --help           Show this help
EOF
}

while [ "$#" -gt 0 ]; do
    case "$1" in
        --host)
            host=${2:?Missing value for --host}
            shift 2
            ;;
        --port)
            port=${2:?Missing value for --port}
            shift 2
            ;;
        --upstream)
            upstream=${2:?Missing value for --upstream}
            shift 2
            ;;
        --service-name)
            service_name=${2:?Missing value for --service-name}
            shift 2
            ;;
        --skip-tests)
            skip_tests=true
            shift
            ;;
        --uninstall)
            uninstall=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$port" in
    *[!0-9]*|'')
        echo "Port must be a number." >&2
        exit 2
        ;;
esac
if [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
    echo "Port must be between 1 and 65535." >&2
    exit 2
fi

case "$service_name" in
    *[!A-Za-z0-9_.-]*|'')
        echo "Service name may contain only letters, numbers, dot, dash, and underscore." >&2
        exit 2
        ;;
esac

if ! command -v systemctl >/dev/null 2>&1 || [ ! -d /run/systemd/system ]; then
    echo "A running systemd installation is required." >&2
    exit 1
fi

if [ "$(id -u)" -eq 0 ]; then
    as_root() {
        "$@"
    }
    service_user=${SUDO_USER:-root}
elif command -v sudo >/dev/null 2>&1; then
    as_root() {
        sudo "$@"
    }
    service_user=$(id -un)
else
    echo "Run this installer as root or install sudo." >&2
    exit 1
fi

main_unit="/etc/systemd/system/${service_name}.service"
health_unit="/etc/systemd/system/${service_name}-health.service"
recover_unit="/etc/systemd/system/${service_name}-recover.service"
timer_unit="/etc/systemd/system/${service_name}-health.timer"

if [ "$uninstall" = true ]; then
    as_root systemctl disable --now "${service_name}-health.timer" 2>/dev/null || true
    as_root systemctl disable --now "${service_name}.service" 2>/dev/null || true
    as_root rm -f "$main_unit" "$health_unit" "$recover_unit" "$timer_unit"
    as_root systemctl daemon-reload
    as_root systemctl reset-failed "$service_name" 2>/dev/null || true
    echo "Removed ${service_name}.service and its health watchdog."
    exit 0
fi

if command -v python3 >/dev/null 2>&1; then
    python_cmd=$(command -v python3)
elif command -v python >/dev/null 2>&1; then
    python_cmd=$(command -v python)
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

if [ "$skip_tests" = false ]; then
    "$python_cmd" -m unittest discover -s "$root_dir/tests" -v
fi

service_group=$(id -gn "$service_user")
quote_unit_arg() {
    "$python_cmd" -c \
        'import sys
value = sys.argv[1]
if "\n" in value or "\r" in value:
    raise SystemExit("Unit arguments cannot contain newlines")
print("\"" + value.replace("\\", "\\\\").replace("\"", "\\\"") + "\"")' \
        "$1"
}

python_arg=$(quote_unit_arg "$python_cmd")
proxy_arg=$(quote_unit_arg "$root_dir/agentrouter-proxy.py")
check_arg=$(quote_unit_arg "$root_dir/check-setup.py")
workdir_arg=$(quote_unit_arg "$root_dir")
key_arg=$(quote_unit_arg "$root_dir/api.txt")
host_arg=$(quote_unit_arg "$host")
upstream_arg=$(quote_unit_arg "$upstream")
case "$host" in
    0.0.0.0)
        health_host=127.0.0.1
        ;;
    ::|'[::]')
        health_host='[::1]'
        ;;
    *:*)
        health_host="[$host]"
        ;;
    *)
        health_host=$host
        ;;
esac
health_url="http://${health_host}:${port}"
health_url_arg=$(quote_unit_arg "$health_url")

main_tmp=$(mktemp)
health_tmp=$(mktemp)
recover_tmp=$(mktemp)
timer_tmp=$(mktemp)
cleanup() {
    rm -f "$main_tmp" "$health_tmp" "$recover_tmp" "$timer_tmp"
}
trap cleanup EXIT HUP INT TERM

cat >"$main_tmp" <<EOF
[Unit]
Description=AgentRouter compatibility proxy for 9Router
Documentation=https://github.com/sitaurs/agentrouter-proxy-9router
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=10

[Service]
Type=simple
User=$service_user
Group=$service_group
WorkingDirectory=$workdir_arg
ExecStart=$python_arg $proxy_arg --host $host_arg --port $port --upstream $upstream_arg --key-file $key_arg
Restart=always
RestartSec=3
TimeoutStopSec=10
KillSignal=SIGINT
Environment=PYTHONUNBUFFERED=1
Environment=PYTHONDONTWRITEBYTECODE=1
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
TasksMax=64

[Install]
WantedBy=multi-user.target
EOF

cat >"$health_tmp" <<EOF
[Unit]
Description=Health check for ${service_name}
OnFailure=${service_name}-recover.service

[Service]
Type=oneshot
ExecStart=$python_arg $check_arg --proxy-url $health_url_arg --timeout 5
EOF

cat >"$recover_tmp" <<EOF
[Unit]
Description=Recover ${service_name} after a failed health check

[Service]
Type=oneshot
ExecStart=$(command -v systemctl) restart ${service_name}.service
EOF

cat >"$timer_tmp" <<EOF
[Unit]
Description=Run ${service_name} health check every 30 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=30s
AccuracySec=5s
Unit=${service_name}-health.service
Persistent=true

[Install]
WantedBy=timers.target
EOF

as_root install -m 0644 "$main_tmp" "$main_unit"
as_root install -m 0644 "$health_tmp" "$health_unit"
as_root install -m 0644 "$recover_tmp" "$recover_unit"
as_root install -m 0644 "$timer_tmp" "$timer_unit"
as_root systemctl daemon-reload
as_root systemctl enable --now "${service_name}.service"
as_root systemctl enable --now "${service_name}-health.timer"

attempt=0
while [ "$attempt" -lt 20 ]; do
    if "$python_cmd" "$root_dir/check-setup.py" \
        --proxy-url "$health_url" --timeout 2 >/dev/null 2>&1; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.25
done

if [ "$attempt" -ge 20 ]; then
    as_root systemctl status "${service_name}.service" --no-pager || true
    echo "The proxy service did not become healthy." >&2
    exit 1
fi

echo
echo "Installed reliable systemd service: ${service_name}.service"
echo "Health watchdog: ${service_name}-health.timer"
echo "Provider Base URL: http://${host}:${port}/v1"
echo "Store the real AgentRouter API key in 9Router's API Key field."
echo "Logs: journalctl -u ${service_name}.service -f"
