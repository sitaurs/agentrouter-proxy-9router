param(
    [switch]$NoAutoStart,
    [switch]$NoStart,
    [switch]$SkipTests
)

$ErrorActionPreference = "Stop"

function Write-Step([string]$Message) {
    Write-Host ""
    Write-Host "==> $Message" -ForegroundColor Cyan
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$startupDir = [Environment]::GetFolderPath("Startup")
$shortcutPath = Join-Path $startupDir "AgentRouter Proxy for 9Router.lnk"

Write-Step "Checking Python"
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    throw @"
Python was not found.
Install Python 3.11 or newer from https://www.python.org/downloads/
Enable 'Add Python to PATH', then run install.cmd again.
"@
}

$pythonVersionText = & $python.Source -c "import platform; print(platform.python_version())"
$pythonVersion = [Version]$pythonVersionText
if ($pythonVersion -lt [Version]"3.11") {
    throw "Python 3.11 or newer is required. Found: $pythonVersionText"
}
Write-Host "Python $pythonVersionText found."

if (-not $SkipTests) {
    Write-Step "Running offline tests"
    & $python.Source -m unittest discover -s (Join-Path $root "tests") -v
    if ($LASTEXITCODE -ne 0) {
        throw "Offline tests failed."
    }
}

if (-not $NoAutoStart) {
    Write-Step "Enabling watchdog at Windows logon"
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPath)
    $shortcut.TargetPath = "powershell.exe"
    $shortcut.Arguments = "-NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$root\watch-agentrouter-proxy.ps1`""
    $shortcut.WorkingDirectory = $root
    $shortcut.Description = "Monitor AgentRouter compatibility proxy for 9Router"
    $shortcut.Save()
    Write-Host "Startup shortcut created: $shortcutPath"
}

if (-not $NoStart) {
    Write-Step "Starting and verifying the proxy"
    & (Join-Path $root "start-agentrouter-proxy.ps1")
    & $python.Source (Join-Path $root "check-setup.py")
    if ($LASTEXITCODE -ne 0) {
        throw "Proxy verification failed."
    }
}

Write-Step "9Router provider settings"
Write-Host @"
Name:      AgentRouter Local
Prefix:    ar
API Type:  Chat Completions
Base URL:  http://127.0.0.1:4182/v1
API Key:   YOUR_AGENTROUTER_API_KEY
Test model: claude-opus-5
"@

Write-Host "Store the real AgentRouter API key in 9Router's API Key field."
Write-Host "Installation is complete." -ForegroundColor Green
