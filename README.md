# v9-mt5-bot

MetaTrader 5 automated trading bot — pure MQL5 Expert Advisor with config-driven strategy, multi-timeframe signals, and execution cost tracking.

## Architecture

| Component | Location | Purpose |
|-----------|----------|---------|
| `v9-mt5-bot.mq5` | `MQL5/Experts/` | Main EA — timer-based 200ms scan loop |
| `v9-config.txt` | `MQL5/Files/` | Runtime config (symbols, risk, SL/TP, magic) |
| `SocketBridgeEA.ex5` | `MQL5/Experts/` | REST API bridge for remote control (port 8890) |

## Key Features

- **Timer-based execution**: 200ms `OnTimer()` loop, 1s scan interval — not tick-dependent
- **1-second kline builder**: Circular buffer of 300 `SecBar` structs built from `SymbolInfoTick()`
- **Multi-timeframe signals**: 1m + 3m + 15m candles with RSI/EMA/BB/MACD/Stoch/ADX
- **Execution tracking**: Logs requested vs filled price, slippage, commission, swap, net PnL
- **Closed trade logging**: Auto-detects close reason (SL/TP/time stop/breakeven)
- **Risk management**: 1% per trade via `OrderCalcProfit`, max 4 open positions
- **Config-driven**: Edit `v9-config.txt` and refresh EA — no recompilation needed

## Strategy Signals

| Signal | Type | Confirmation |
|--------|------|--------------|
| `RSI_OVERSOLD` / `RSI_OVERBOUGHT` | Mean reversion | 3m RSI alignment |
| `MA10_BOUNCE` / `MA10_REJECT` | Trend pullback | MTF trend filter |
| `EMA_CROSS_UP` / `EMA_CROSS_DN` | Momentum | Volume + ADX > 20 |
| `BB_REV_LONG` / `BB_REV_SHORT` | Bollinger reversal | MACD histogram |
| `TREND_LONG` / `TREND_SHORT` | Trend following | Stochastic confirmation |
| `VOL_BREAKUP` / `VOL_BREAKDN` | Volume breakout | 1m RSI + trend |
| `MOMENTUM_LONG` / `MOMENTUM_SHORT` | 3-bar momentum | 3m trend alignment |
| `SQUEEZE_LONG` / `SQUEEZE_SHORT` | Volatility squeeze | ADX < 20, Stoch extreme |

## Position Management

- **Stop Loss**: Minimum 15 pips, ATR-based or signal-defined
- **Take Profit**: 1.5x SL distance, or signal-defined, or minimum $10 net target
- **Breakeven**: Moves SL to entry after 10 pips profit
- **Trailing stop**: 15 pips trailing after 1.5x trail distance
- **Time stop**: Auto-close after 4 hours if neither SL nor TP hit

## Setup

### Prerequisites
- MetaTrader 5 (Windows)
- MetaEditor 5
- Demo or live account (hedging mode recommended)

### Installation

1. Copy `v9-mt5-bot.mq5` to `MQL5/Experts/`
2. Copy `v9-config.txt` to `MQL5/Files/`
3. Compile via MetaEditor: `metaeditor64.exe /compile:"MQL5/Experts/v9-mt5-bot.mq5"`
4. Attach `v9-mt5-bot.ex5` to a chart (any symbol, H1 recommended)
5. Ensure `SocketBridgeEA.ex5` is attached for REST API on port 8890

### Configuration

Edit `MQL5/Files/v9-config.txt`:

```ini
SYMBOLS=EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,NZDUSD,USDCHF,EURGBP,EURJPY,GBPJPY,XAUUSD,XAGUSD,US30,UK100
RISK_PCT=1.0
MAX_OPEN=4
MAGIC=999001
MIN_SCORE=0.75
MAX_SPREAD=50.0
COOLDOWN_SEC=300
MIN_SL_PIPS=15
TIME_STOP_MIN=240
BREAKEVEN_PIPS=10
TRAIL=true
TRAIL_PIPS=15
LOG_EVERY=10
TARGET_PROFIT=10
TRACK_EXECUTION=true
```

### Compile Script (Windows)

```bat
"C:\Program Files\MetaTrader 5\metaeditor64.exe" /compile:"%APPDATA%\MetaQuotes\Terminal\<ID>\MQL5\Experts\v9-mt5-bot.mq5"
```

## REST API (via SocketBridgeEA)

| Endpoint | Method | Description |
|----------|--------|-------------|
| `/v1/account` | GET | Account balance, equity, margin |
| `/v1/order/list` | GET | Open positions |
| `/v1/quote?symbol=EURUSD` | GET | Current bid/ask |
| `/v1/order/close` | POST | Close position by ticket |

## Risk Disclaimer

This bot is for **educational purposes only**. Trading Forex/CFDs involves significant risk of loss. Past performance does not guarantee future results. Always test on demo accounts before live trading.

## Version History

- **v2.10** — Multi-timeframe signals (1m+3m+15m), execution tracking, closed trade logging, $10 profit target enforcement
- **v2.01** — Config file support, 14 symbols, RSI/EMA/BB strategy
- **v2.00** — Initial timer-based 200ms loop, 1s kline builder

## License

MIT — use at your own risk.
