param(
    [switch]$KeepApiKey
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "AgentRouter Proxy for 9Router.lnk"

& (Join-Path $root "stop-agentrouter-proxy.ps1")

$watchdogs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*watch-agentrouter-proxy.ps1*" }
foreach ($watchdog in $watchdogs) {
    Stop-Process -Id $watchdog.ProcessId -Force -ErrorAction SilentlyContinue
}

if (Test-Path -LiteralPath $shortcutPath) {
    Remove-Item -LiteralPath $shortcutPath -Force
    Write-Output "Removed Windows startup shortcut."
}

if (-not $KeepApiKey) {
    $keyFile = Join-Path $root "api.txt"
    if (Test-Path -LiteralPath $keyFile) {
        Remove-Item -LiteralPath $keyFile -Force
        Write-Output "Removed api.txt."
    }
}

Get-ChildItem -LiteralPath $root -Filter "agentrouter-proxy*.log" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Output "Local AgentRouter proxy installation was removed."
