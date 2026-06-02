@echo off
setlocal
set "WORKSPACE=%~dp0v9-mt5-bot.mq5"
set "SANDBOX=%APPDATA%\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\v9-mt5-bot.mq5"

if exist "%WORKSPACE%" (
    if exist "%SANDBOX%" (
        fc /b "%WORKSPACE%" "%SANDBOX%" >nul 2>&1
        if errorlevel 1 (
            echo Syncing workspace -^> sandbox...
            copy /Y "%WORKSPACE%" "%SANDBOX%" >nul
        )
    ) else (
        echo Sandbox mq5 missing, copying workspace...
        copy /Y "%WORKSPACE%" "%SANDBOX%" >nul
    )
)

echo Compiling v9-mt5-bot.mq5...
"C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"%SANDBOX%" /log:"%TEMP%\v9-compile-log.txt"
echo Done. Check compile log:
type "%TEMP%\v9-compile-log.txt"
pause
