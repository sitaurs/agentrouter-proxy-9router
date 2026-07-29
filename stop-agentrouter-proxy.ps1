param(
    [int]$Port = 4182
)

$ErrorActionPreference = "Stop"

$proxyDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pidFile = Join-Path $proxyDir ".agentrouter-proxy.pid"

if (Test-Path -LiteralPath $pidFile) {
    $proxyPid = (Get-Content -Raw -LiteralPath $pidFile).Trim()
} else {
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $listener) {
        Write-Output "AgentRouter proxy is already stopped."
        exit 0
    }
    $proxyPid = "$($listener.OwningProcess)"
}

if ($proxyPid -notmatch "^\d+$") {
    throw "Invalid PID file: $pidFile"
}

$process = Get-CimInstance Win32_Process -Filter "ProcessId = $proxyPid" -ErrorAction SilentlyContinue
if ($process -and $process.CommandLine -like "*agentrouter-proxy.py*") {
    Stop-Process -Id ([int]$proxyPid) -Force
    Write-Output "AgentRouter proxy stopped (PID $proxyPid)."
} elseif ($process) {
    throw "PID $proxyPid belongs to another process; refusing to stop it."
} else {
    Write-Output "Proxy process $proxyPid is no longer running."
}

Remove-Item -LiteralPath $pidFile -Force -ErrorAction SilentlyContinue
