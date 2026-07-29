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

function Get-PlainText([Security.SecureString]$SecureValue) {
    $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureValue)
    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
    }
}

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$keyFile = Join-Path $root "api.txt"
$exampleKey = "paste-your-agentrouter-api-key-here"
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

Write-Step "Configuring the AgentRouter API key"
$needsKey = $true
if (Test-Path -LiteralPath $keyFile) {
    $existingKey = (Get-Content -Raw -LiteralPath $keyFile).Trim()
    if ($existingKey -and $existingKey -ne $exampleKey) {
        $needsKey = $false
        Write-Host "Existing api.txt found; keeping it."
    }
}

if ($needsKey) {
    $secureKey = Read-Host "Paste your AgentRouter API key" -AsSecureString
    $plainKey = Get-PlainText $secureKey
    try {
        if ([string]::IsNullOrWhiteSpace($plainKey)) {
            throw "The API key cannot be empty."
        }
        $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($keyFile, $plainKey.Trim(), $utf8NoBom)
    } finally {
        $plainKey = $null
        $secureKey.Dispose()
    }
    Write-Host "API key saved to ignored local file api.txt."
}

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
API Key:   local-proxy
Test model: claude-opus-5
"@

Write-Host "Installation is complete." -ForegroundColor Green
