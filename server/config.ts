export const BOT_CONFIG = {
  bridgeUrl: process.env.BRIDGE_URL || 'http://localhost:8891',
  wsUrl: process.env.WS_URL || 'ws://localhost:8890',

  capital: 10000,
  riskPerTrade: 0.01,
  maxOpen: 4,
  targetProfitUsd: 15,
  stopLossUsd: -25,
  maxSpreadPips: 5,

  symbols: [
    'EURUSD', 'GBPUSD', 'USDJPY', 'AUDUSD', 'USDCAD',
    'NZDUSD', 'USDCHF', 'EURGBP', 'EURJPY', 'GBPJPY',
    'XAUUSD', 'XAGUSD', 'BTCUSD', 'ETHUSD',
    'US30', 'NAS100', 'SPX500', 'GER40', 'UK100',
  ],

  timeframes: {
    signal: 'M15',
    trend: 'H1',
    momentum: 'M5',
  },

  signalFreshnessMs: 10 * 60 * 1000,
  minSignalScore: 0.75,
  loopIntervalMs: 1000,
  maxLogLines: 50000,
};
