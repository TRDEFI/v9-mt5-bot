@echo off
setlocal
set "WORKSPACE=%~dp0"
set "SANDBOX_MQL5=%APPDATA%\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5"

rem === 1. Sync .mq5 source ===
set "SRC=%WORKSPACE%v9-mt5-bot.mq5"
set "DST=%SANDBOX_MQL5%\Experts\v9-mt5-bot.mq5"
if exist "%SRC%" (
    if exist "%DST%" (
        fc /b "%SRC%" "%DST%" >nul 2>&1
        if errorlevel 1 (
            echo Syncing mq5 -^> sandbox...
            copy /Y "%SRC%" "%DST%" >nul
        )
    ) else (
        echo Sandbox mq5 missing, copying...
        copy /Y "%SRC%" "%DST%" >nul
    )
)

rem === 2. Sync config file ===
copy /Y "%WORKSPACE%v9-config.txt" "%SANDBOX_MQL5%\Files\v9-config.txt" >nul
echo Config synced.

rem === 3. Compile ===
echo Compiling v9-mt5-bot.mq5...
"C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"%DST%" /log:"%TEMP%\v9-compile-log.txt"
echo Done. Compile log:
type "%TEMP%\v9-compile-log.txt"

rem === 4. Reload EA on chart (if PowerShell available) ===
where powershell >nul 2>&1
if not errorlevel 1 (
    powershell -ExecutionPolicy Bypass -File "%WORKSPACE%reload-ea.ps1"
) else (
    echo PowerShell not found — reload skipped. Manually reattach the EA.
)

pause
