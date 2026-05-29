import { BOT_CONFIG } from './config.js';
import { Mt5Client } from './mt5Client.js';
import { getSignal } from './strategy.js';
import { Kline, Signal } from './types.js';

let lastLog: string[] = [];
let isTrading = false;
let loopTimer: ReturnType<typeof setInterval> | null = null;
let openSignals: Map<string, { signal: Signal; entry: number; time: number }> = new Map();
let openPositions: Map<string, number> = new Map();
let cache: Map<string, Kline[]> = new Map();

function log(msg: string) {
  const t = new Date().toISOString();
  const line = `[${t}] ${msg}`;
  lastLog.push(line);
  if (lastLog.length > BOT_CONFIG.maxLogLines) {
    lastLog.splice(0, lastLog.length - BOT_CONFIG.maxLogLines);
  }
  console.log(line);
}

export function getLogs(): string[] {
  return lastLog;
}

function calcLotSize(price: number, slDistance: number): number {
  const risk = BOT_CONFIG.capital * BOT_CONFIG.riskPerTrade;
  const raw = risk / (slDistance * 100_000);
  const step = 0.01;
  const lots = Math.floor(raw / step) * step;
  return Math.max(0.01, Math.min(lots, 1.0));
}

export async function runBot(client: Mt5Client) {
  isTrading = true;
  log('Bot runner started');

  loopTimer = setInterval(async () => {
    if (!isTrading) return;
    try {
      await scan(client);
    } catch (err) {
      log(`Scan error: ${err}`);
    }
  }, BOT_CONFIG.loopIntervalMs);
}

export function stopBot() {
  isTrading = false;
  if (loopTimer) {
    clearInterval(loopTimer);
    loopTimer = null;
  }
  log('Bot runner stopped');
}

export function isRunning(): boolean {
  return isTrading;
}

async function getPositions(client: Mt5Client): Promise<Map<string, number>> {
  const positions = await client.getPositions();
  const map = new Map<string, number>();
  for (const p of positions) {
    map.set(p.symbol, (map.get(p.symbol) || 0) + p.volume);
  }
  return map;
}

async function scan(client: Mt5Client) {
  openPositions = await getPositions(client);
  const activeCount = openPositions.size;

  for (const symbol of BOT_CONFIG.symbols) {
    if (!isTrading) break;

    if (openPositions.has(symbol)) {
      continue;
    }

    if (activeCount >= BOT_CONFIG.maxOpen) {
      continue;
    }

    const closed = openSignals.get(symbol);
    try {
      await evaluateSymbol(client, symbol, closed);
    } catch (err) {
      log(`${symbol} eval error: ${err}`);
    }
  }
}

async function evaluateSymbol(
  client: Mt5Client,
  symbol: string,
  closed: { signal: Signal; entry: number; time: number } | undefined,
) {
  if (closed && Date.now() - closed.time < BOT_CONFIG.signalFreshnessMs) {
    return;
  }
  if (closed) {
    openSignals.delete(symbol);
  }

  let klines = cache.get(symbol);
  if (!klines || klines.length < 100 || Date.now() - klines[klines.length - 1].t > 60_000) {
    klines = await client.getKlines(symbol, 'M5', 100);
    if (klines.length < 20) return;
    cache.set(symbol, klines);
  }

  const rates = await client.getRates(symbol);
  if (!rates) return;

  if (rates.spread > BOT_CONFIG.maxSpreadPips * 10) {
    return;
  }

  const signal = getSignal(klines);
  if (!signal || signal.score < BOT_CONFIG.minSignalScore) return;

  const price = signal.side === 'LONG' ? rates.ask : rates.bid;
  const slDistance = Math.max(calcSlDistance(signal, klines, price), 10);
  const lots = calcLotSize(price, slDistance);

  if (lots < 0.01) return;

  const sl = signal.side === 'LONG' ? price - slDistance : price + slDistance;
  const tp = signal.tp_target ?? (
    signal.side === 'LONG' ? price + slDistance * 1.5 : price - slDistance * 1.5
  );

  const result = await client.placeOrder({
    symbol,
    type: signal.side === 'LONG' ? 'buy' : 'sell',
    volume: lots,
    sl,
    tp,
  });

  if (result && result.ticket) {
    log(`${symbol} ${signal.side} ${signal.name} score=${signal.score} lots=${lots} entry=${price} sl=${sl} tp=${tp}`);
    if (result.error) {
      log(`${symbol} order warning: ${result.error}`);
    }
    openSignals.set(symbol, { signal, entry: price, time: Date.now() });
  }
}

function calcSlDistance(signal: Signal, klines: Kline[], price: number): number {
  if (signal.sl_target) {
    return Math.abs(price - signal.sl_target);
  }
  const atr = signal.avg_move;
  const atrPips = atr * 10_000;
  return Math.max(atrPips, 20);
}

export async function closeSymbol(client: Mt5Client, symbol: string): Promise<boolean> {
  const positions = await client.getPositions();
  for (const p of positions) {
    if (p.symbol === symbol) {
      const ok = await client.closeOrder(p.ticket);
      if (ok) log(`Closed ${symbol} ticket=${p.ticket}`);
      return ok;
    }
  }
  return false;
}
