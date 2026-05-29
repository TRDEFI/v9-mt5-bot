import { Kline, Signal } from './types.js';

export function calcRsi(klines: Kline[], period: number = 14): number {
  if (klines.length <= period) return 50;
  let gains = 0, losses = 0;
  for (let i = 1; i <= period; i++) {
    const diff = klines[i].c - klines[i - 1].c;
    if (diff > 0) gains += diff;
    else losses -= diff;
  }
  let avgGain = gains / period;
  let avgLoss = losses / period;
  for (let i = period + 1; i < klines.length; i++) {
    const diff = klines[i].c - klines[i - 1].c;
    const gain = diff > 0 ? diff : 0;
    const loss = diff < 0 ? -diff : 0;
    avgGain = (avgGain * (period - 1) + gain) / period;
    avgLoss = (avgLoss * (period - 1) + loss) / period;
  }
  if (avgLoss === 0) return 100;
  return 100 - (100 / (1 + avgGain / avgLoss));
}

export function calcMa(klines: Kline[], period: number): number {
  if (klines.length < period) return 0;
  return klines.slice(-period).reduce((s, k) => s + k.c, 0) / period;
}

export function calcEma(klines: Kline[], period: number): number {
  if (klines.length < period) return 0;
  const k = 2 / (period + 1);
  let ema = klines.slice(0, period).reduce((s, kline) => s + kline.c, 0) / period;
  for (let i = period; i < klines.length; i++) {
    ema = (klines[i].c - ema) * k + ema;
  }
  return ema;
}

export function calcAtr(klines: Kline[], period: number = 14): number {
  if (klines.length < period) return 0;
  let trSum = 0;
  for (let i = klines.length - period; i < klines.length; i++) {
    const high = klines[i].h;
    const low = klines[i].l;
    const prevClose = i > 0 ? klines[i - 1].c : low;
    const tr = Math.max(high - low, Math.abs(high - prevClose), Math.abs(low - prevClose));
    trSum += tr;
  }
  return trSum / period;
}

export function calcBollingerBands(klines: Kline[], period: number = 20, numStdDev: number = 2) {
  if (klines.length < period) return null;
  const slice = klines.slice(-period);
  const sma = slice.reduce((s, k) => s + k.c, 0) / period;
  let variance = 0;
  for (const k of slice) {
    variance += Math.pow(k.c - sma, 2);
  }
  variance /= period;
  const stdDev = Math.sqrt(variance);
  return { upper: sma + numStdDev * stdDev, lower: sma - numStdDev * stdDev, sma };
}

export function calcVolumeRatio(klines: Kline[], period: number = 20): number {
  if (klines.length < period + 1) return 1;
  const cur = klines[klines.length - 1].v;
  const avg = klines.slice(-period - 1, -1).reduce((s, k) => s + k.v, 0) / period;
  return avg === 0 ? 1 : cur / avg;
}

export function getSignal(klines: Kline[]): Signal | null {
  if (!klines || klines.length < 20) return null;

  const rsi = calcRsi(klines, 14);
  const ma10 = calcMa(klines, 10);
  const ma20 = calcMa(klines, 20);
  const ema9 = calcEma(klines, 9);
  const ema21 = calcEma(klines, 21);
  const ema50 = calcEma(klines, 50);
  const vr = calcVolumeRatio(klines, 20);
  const atr = calcAtr(klines, 14);
  const avg = atr;
  const p = klines[klines.length - 1].c;
  const dev = ((p - ma10) / ma10) * 100;
  const bb = calcBollingerBands(klines, 20, 2);

  const sigs: Signal[] = [];

  const prevKlines = klines.slice(0, -1);
  const rsiPrev = prevKlines.length >= 14 ? calcRsi(prevKlines, 14) : rsi;
  const lastCandle = klines[klines.length - 1];
  const justOversold = rsiPrev >= 30 && rsi < 30;
  const justOverbought = rsiPrev <= 70 && rsi > 70;

  if (justOversold && lastCandle.c > lastCandle.o) {
    sigs.push({ name: 'RSI_OVERSOLD', score: 0.90, side: 'LONG', avg_move: avg });
  }
  if (justOverbought && lastCandle.c < lastCandle.o) {
    sigs.push({ name: 'RSI_OVERBOUGHT', score: 0.90, side: 'SHORT', avg_move: avg });
  }

  if (dev < -2.5 && rsi < 40) sigs.push({ name: 'MA10_BOUNCE', score: 0.88, side: 'LONG', avg_move: avg });
  if (dev > 2.5 && rsi > 60) sigs.push({ name: 'MA10_REJECT', score: 0.88, side: 'SHORT', avg_move: avg });

  const klinesClosed = klines.slice(0, -1);
  const ema9Curr = calcEma(klines, 9);
  const ema21Curr = calcEma(klines, 21);
  let ema9Prev = ema9Curr, ema21Prev = ema21Curr;
  if (klinesClosed.length >= 21) {
    const prevKlines2 = klinesClosed.slice(0, -1);
    if (prevKlines2.length >= 21) {
      ema9Prev = calcEma(prevKlines2, 9);
      ema21Prev = calcEma(prevKlines2, 21);
    }
  }

  const justCrossedUp = ema9Prev <= ema21Prev && ema9Curr > ema21Curr;
  const justCrossedDn = ema9Prev >= ema21Prev && ema9Curr < ema21Curr;
  const isGreenCandle = lastCandle.c > lastCandle.o;
  const ema21Slope = ema21Curr > 0 && ema21Prev > 0 ? (ema21Curr - ema21Prev) / ema21Prev : 0;
  if (justCrossedUp && vr > 2.0 && rsi < 65 && isGreenCandle && ema21Slope > -0.0005) {
    sigs.push({ name: 'EMA_CROSS_UP', score: 0.86, side: 'LONG', avg_move: avg });
  }
  if (justCrossedDn && vr > 2.0 && rsi > 35) {
    sigs.push({ name: 'EMA_CROSS_DN', score: 0.86, side: 'SHORT', avg_move: avg });
  }

  if (bb && p < bb.lower * 1.002 && rsi < 35 && vr > 1.3 && ema50 > 0 && p > ema50 * 0.995) {
    sigs.push({ name: 'BB_REVERSION_LONG', score: 0.87, side: 'LONG', avg_move: atr, tp_target: bb.sma, sl_target: bb.lower * 0.997 });
  }
  if (bb && p > bb.upper * 0.998 && rsi > 65 && vr > 1.3 && ema50 > 0 && p < ema50 * 1.005) {
    sigs.push({ name: 'BB_REVERSION_SHORT', score: 0.87, side: 'SHORT', avg_move: atr, tp_target: bb.sma, sl_target: bb.upper * 1.003 });
  }

  if (ma10 > ma20 && dev < -1.5 && rsi < 50) {
    sigs.push({ name: 'TREND_LONG', score: 0.85, side: 'LONG', avg_move: avg });
  }
  if (ma10 < ma20 && dev > 1.5 && rsi > 50) {
    sigs.push({ name: 'TREND_SHORT', score: 0.85, side: 'SHORT', avg_move: avg });
  }

  if (vr > 2.5 && p > ma10 && rsi < 60) {
    sigs.push({ name: 'VOL_BREAKUP', score: 0.82, side: 'LONG', avg_move: avg });
  }
  if (vr > 2.5 && p < ma10 && rsi > 40) {
    sigs.push({ name: 'VOL_BREAKDN', score: 0.82, side: 'SHORT', avg_move: avg });
  }

  if (vr > 2.0 && klines.length >= 3) {
    const c1 = klines[klines.length - 3];
    const c2 = klines[klines.length - 2];
    const c3 = klines[klines.length - 1];
    const dir1 = c1.c > c1.o ? 1 : -1;
    const dir2 = c2.c > c2.o ? 1 : -1;
    const dir3 = c3.c > c3.o ? 1 : -1;
    const momentumConfirmed = (dir1 === dir2 && dir2 === dir3);
    if (momentumConfirmed) {
      const isBullish = dir3 === 1;
      if (isBullish && p > ema50 && rsi < 60) {
        sigs.push({ name: 'MOMENTUM_LONG', score: 0.84, side: 'LONG', avg_move: atr, tp_target: p + atr * 1.5, sl_target: p - atr * 0.7 });
      }
      if (!isBullish && p < ema50 && rsi > 40) {
        sigs.push({ name: 'MOMENTUM_SHORT', score: 0.84, side: 'SHORT', avg_move: atr, tp_target: p - atr * 1.5, sl_target: p + atr * 0.7 });
      }
    }
  }

  if (vr < 0.5) {
    if (rsi < 35) sigs.push({ name: 'SQUEEZE_LONG', score: 0.80, side: 'LONG', avg_move: avg });
    if (rsi > 65) sigs.push({ name: 'SQUEEZE_SHORT', score: 0.80, side: 'SHORT', avg_move: avg });
  }

  const min_score = 0.80;
  const valid = sigs.filter(s => s.score >= min_score);
  if (valid.length === 0) return null;
  return valid.sort((a, b) => b.score - a.score)[0];
}
