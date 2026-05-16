[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$ProfileName,

    [Parameter(Mandatory = $true)]
    [string]$StateRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$inputJson = [Console]::In.ReadToEnd()
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$pythonScript = Join-Path $scriptDir "claude_statusline_collector.py"
$logRoot = Join-Path $StateRoot "logs"
$logPath = Join-Path $logRoot "$ProfileName-wrapper.log"

function Write-DiagnosticLog {
    param([string]$Message)

    try {
        New-Item -ItemType Directory -Path $logRoot -Force | Out-Null
        $line = "$(Get-Date -Format o) $Message"
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch {
    }
}

$pythonExe = $null
$pythonArgs = @()

$pythonCmd = Get-Command python.exe -ErrorAction SilentlyContinue
if ($pythonCmd) {
    $pythonExe = $pythonCmd.Source
}

if (-not $pythonExe) {
    $pyCmd = Get-Command py.exe -ErrorAction SilentlyContinue
    if ($pyCmd) {
        $pythonExe = $pyCmd.Source
        $pythonArgs += "-3"
    }
}

if (-not $pythonExe) {
    Write-DiagnosticLog "python-not-found"
    Write-Output "[collector unavailable]"
    exit 0
}

$pythonArgs += @($pythonScript, "--profile", $ProfileName, "--state-root", $StateRoot)
Write-DiagnosticLog "start pythonExe=$pythonExe pythonScript=$pythonScript inputLength=$($inputJson.Length)"

try {
    $output = $inputJson | & $pythonExe @pythonArgs
    $outputText = [string]::Join("`n", @($output | ForEach-Object { $_.ToString() }))
    Write-DiagnosticLog "exitCode=$LASTEXITCODE output=$outputText"
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        Write-Output "[collector error]"
        exit 0
    }

    Write-Output $output
    exit 0
} catch {
    Write-DiagnosticLog "exception=$($_.Exception.GetType().FullName): $($_.Exception.Message)"
    Write-Output "[collector error]"
    exit 0
}
