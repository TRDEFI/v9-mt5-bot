export interface Kline {
  o: number;
  h: number;
  l: number;
  c: number;
  v: number;
  t: number;
}

export interface Signal {
  name: string;
  score: number;
  avg_move: number;
  side: 'LONG' | 'SHORT';
  tp_target?: number;
  sl_target?: number;
}

export interface Mt5Position {
  ticket: number;
  symbol: string;
  type: 'buy' | 'sell';
  volume: number;
  openPrice: number;
  currentPrice: number;
  stopLoss: number;
  takeProfit: number;
  profit: number;
  swap: number;
  openTime: number;
}

export interface Mt5Account {
  balance: number;
  equity: number;
  margin: number;
  freeMargin: number;
  marginLevel: number;
  leverage: number;
  currency: string;
  name: string;
  server: string;
  login: number;
}

export interface Mt5Rate {
  symbol: string;
  bid: number;
  ask: number;
  spread: number;
  time: number;
}

export interface Mt5Bar {
  time: number;
  open: number;
  high: number;
  low: number;
  close: number;
  tick_volume: number;
  real_volume: number;
  spread: number;
}
