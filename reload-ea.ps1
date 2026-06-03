# reload-ea.ps1 - Copies new ex5/config then reattaches EA to EURUSD chart

$terminalId = "D0E8209F77C8CF37AD8BF550E51FF075"
$mql5 = "$env:APPDATA\MetaQuotes\Terminal\$terminalId\MQL5"
$ex5Path = "$mql5\Experts\v9-mt5-bot.ex5"
$tplPath = "$mql5\Profiles\Templates\v9-bot.tpl"
$mt5Exe = "C:\Program Files\MetaTrader 5\terminal64.exe"

Write-Host "=== RELOAD EA ==="

# Ensure config is synced (in case compile-ea.bat didn't)
Copy-Item "$PSScriptRoot\v9-config.txt" "$mql5\Files\v9-config.txt" -Force
Write-Host "  [OK] Config synced"

if (-not (Test-Path $ex5Path)) {
    Write-Host "  [FAIL] $ex5Path not found - compile first!"
    return
}

function CloseEurusdChart {
    $wshell = New-Object -ComObject wscript.shell
    $wshell.AppActivate("MetaTrader")
    Start-Sleep -Milliseconds 300
    $wshell.SendKeys("^{F4}")
    Start-Sleep -Milliseconds 800
}

function OpenEurusdWithTemplate {
    param([string]$templateArg)
    if ($templateArg) {
        Start-Process $mt5Exe -ArgumentList "symbol:EURUSD", "timeframe:M1", "template:v9-bot"
    } else {
        Start-Process $mt5Exe -ArgumentList "symbol:EURUSD", "timeframe:M1"
    }
}

# Check if template exists
if (Test-Path $tplPath) {
    Write-Host "  [INFO] v9-bot.tpl found - auto-reloading"
    $proc = Get-Process MetaTrader -ErrorAction SilentlyContinue
    if ($proc) {
        CloseEurusdChart
    }
    OpenEurusdWithTemplate -templateArg $true
    Write-Host "  [OK] EURUSD reopened with v9-bot template (EA should reload)"
} else {
    Write-Host "`n  ================ ONE-TIME SETUP ================"
    Write-Host "  Template 'v9-bot.tpl' not found."
    Write-Host "  To enable auto-reload, do this ONCE:"
    Write-Host "  1. Attach v9-mt5-bot to EURUSD M1 chart manually"
    Write-Host "  2. Right-click chart -> Template -> Save Template -> 'v9-bot'"
    Write-Host "  3. Rerun compile-ea.bat - it will auto-reload from now on"
    Write-Host "  ==============================================`n"
    
    $proc = Get-Process MetaTrader -ErrorAction SilentlyContinue
    if ($proc) {
        CloseEurusdChart
    }
    OpenEurusdWithTemplate -templateArg $false
    Write-Host "  [OK] EURUSD opened - please attach the EA manually (once), then save template."
}

Write-Host "=== DONE ==="
