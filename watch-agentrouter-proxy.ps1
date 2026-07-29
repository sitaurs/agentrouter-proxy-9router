param(
    [int]$IntervalSeconds = 30,
    [int]$Port = 4182
)

$ErrorActionPreference = "Continue"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$startScript = Join-Path $root "start-agentrouter-proxy.ps1"
$watchdogLog = Join-Path $root "agentrouter-proxy-watchdog.log"
$mutex = New-Object Threading.Mutex($true, "Local\AgentRouterProxy9RouterWatchdog", [ref]$createdNew)

if (-not $createdNew) {
    Write-Output "AgentRouter proxy watchdog is already running."
    exit 0
}

try {
    while ($true) {
        $healthy = $false
        try {
            $health = Invoke-RestMethod -Uri "http://127.0.0.1:${Port}/health" -TimeoutSec 3
            $healthy = $health.ok -eq $true
        } catch {
            $healthy = $false
        }

        if (-not $healthy) {
            try {
                & $startScript -Port $Port |
                    Out-File -LiteralPath $watchdogLog -Append -Encoding utf8
            } catch {
                "$(Get-Date -Format o) $($_.Exception.Message)" |
                    Out-File -LiteralPath $watchdogLog -Append -Encoding utf8
            }
        }

        Start-Sleep -Seconds ([Math]::Max($IntervalSeconds, 10))
    }
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
