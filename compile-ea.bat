@echo off
echo Compiling v9-mt5-bot.mq5...
"C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"%APPDATA%\MetaQuotes\Terminal\D0E8209F77C8CF37AD8BF550E51FF075\MQL5\Experts\v9-mt5-bot.mq5" /log:"%TEMP%\v9-compile-log.txt"
echo Done. Check compile log:
type "%TEMP%\v9-compile-log.txt"
pause
