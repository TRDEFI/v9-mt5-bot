Param(
    [int]$Lines = 200
)

$ErrorActionPreference = 'SilentlyContinue'

$mt5Dir = Join-Path $env:APPDATA 'MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075'
$logsDir = Join-Path $mt5Dir 'MQL5\Logs'

if (-not (Test-Path $logsDir)) {
    Write-Host "Logs directory not found: $logsDir"
    exit 1
}

$latest = Get-ChildItem $logsDir -Filter '*.log' | Sort-Object LastWriteTime -Descending | Select-Object -First 1
if (-not $latest) {
    Write-Host "No log files found in $logsDir"
    exit 1
}

Write-Host "Latest log: $($latest.Name) ($($latest.LastWriteTime))"
Write-Host "--- LAST $Lines LINES ---"
Get-Content $latest.FullName -Tail $Lines
