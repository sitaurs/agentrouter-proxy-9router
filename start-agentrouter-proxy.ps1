param(
    [string]$ListenAddress = "127.0.0.1",
    [int]$Port = 4182,
    [string]$Upstream = "https://agentrouter.org",
    [string]$KeyFile = ""
)

$ErrorActionPreference = "Stop"

$proxyDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$proxyScript = Join-Path $proxyDir "agentrouter-proxy.py"
$stdoutLog = Join-Path $proxyDir "agentrouter-proxy.log"
$stderrLog = Join-Path $proxyDir "agentrouter-proxy-error.log"
$pidFile = Join-Path $proxyDir ".agentrouter-proxy.pid"
$healthAddress = if ($ListenAddress -in @("0.0.0.0", "::", "[::]")) {
    "127.0.0.1"
} else {
    $ListenAddress
}

if ([string]::IsNullOrWhiteSpace($KeyFile)) {
    $KeyFile = Join-Path $proxyDir "api.txt"
}

$listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
if ($listeners) {
    $ownerPid = ($listeners | Select-Object -First 1).OwningProcess
    try {
        $health = Invoke-RestMethod -Uri "http://${healthAddress}:${Port}/health" -TimeoutSec 2
        if ($health.ok -eq $true) {
            Write-Output "AgentRouter proxy is already healthy on port $Port (PID $ownerPid)."
            $ownerPid | Set-Content -LiteralPath $pidFile -NoNewline
            exit 0
        }
    } catch {
        # Verify ownership below before recovering an unhealthy listener.
    }

    $owner = Get-CimInstance Win32_Process -Filter "ProcessId = $ownerPid" -ErrorAction SilentlyContinue
    if ($owner -and $owner.CommandLine -like "*agentrouter-proxy.py*") {
        Write-Output "Recovering unhealthy AgentRouter proxy (PID $ownerPid)."
        Stop-Process -Id $ownerPid -Force
        Start-Sleep -Milliseconds 500
    } else {
        throw "Port $Port is occupied by another process (PID $ownerPid)."
    }
}

$python = Get-Command python -ErrorAction Stop
$arguments = @(
    "`"$proxyScript`"",
    "--host", $ListenAddress,
    "--port", "$Port",
    "--upstream", $Upstream,
    "--key-file", "`"$KeyFile`""
)

$process = Start-Process `
    -FilePath $python.Source `
    -ArgumentList $arguments `
    -WorkingDirectory $proxyDir `
    -WindowStyle Hidden `
    -RedirectStandardOutput $stdoutLog `
    -RedirectStandardError $stderrLog `
    -PassThru

$process.Id | Set-Content -LiteralPath $pidFile -NoNewline

$healthUrl = "http://${healthAddress}:${Port}/health"
$ready = $false
for ($attempt = 0; $attempt -lt 20; $attempt++) {
    Start-Sleep -Milliseconds 250
    if ($process.HasExited) {
        throw "AgentRouter proxy failed to start. See $stderrLog"
    }
    try {
        $health = Invoke-RestMethod -Uri $healthUrl -TimeoutSec 2
        if ($health.ok -eq $true) {
            $ready = $true
            break
        }
    } catch {
        # The listener may still be starting.
    }
}

if (-not $ready) {
    Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    throw "AgentRouter proxy did not become healthy. See $stderrLog"
}

Write-Output "AgentRouter proxy started (PID $($process.Id)) on $healthUrl."
