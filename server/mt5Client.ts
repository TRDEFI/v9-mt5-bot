import axios from 'axios';
import { BOT_CONFIG } from './config.js';
import { Kline, Mt5Account, Mt5Bar, Mt5Position } from './types.js';

function normalizeBars(bars: Mt5Bar[]): Kline[] {
  return bars.map(b => ({
    o: b.open,
    h: b.high,
    l: b.low,
    c: b.close,
    v: b.real_volume || b.tick_volume,
    t: b.time,
  }));
}

export class Mt5Client {
  private http;

  constructor() {
    this.http = axios.create({
      baseURL: BOT_CONFIG.bridgeUrl,
      timeout: 10_000,
    });
  }

  async getAccount(): Promise<Mt5Account | null> {
    try {
      const r = await this.http.get('/api/v1/account');
      return r.data as Mt5Account;
    } catch {
      return null;
    }
  }

  async getPositions(): Promise<Mt5Position[]> {
    try {
      const r = await this.http.get('/api/v1/positions');
      return Array.isArray(r.data) ? (r.data as Mt5Position[]) : [];
    } catch {
      return [];
    }
  }

  async getRates(symbol: string): Promise<{ bid: number; ask: number; spread: number } | null> {
    try {
      const r = await this.http.get(`/api/v1/rates`, { params: { symbol } });
      return r.data as { bid: number; ask: number; spread: number };
    } catch {
      return null;
    }
  }

  async getKlines(symbol: string, timeframe: string, count: number = 100): Promise<Kline[]> {
    try {
      const r = await this.http.get(`/api/v1/rates/history`, {
        params: { symbol, timeframe, count },
      });
      const bars = r.data as Mt5Bar[];
      if (!Array.isArray(bars)) return [];
      return normalizeBars(bars);
    } catch {
      return [];
    }
  }

  async placeOrder(params: {
    symbol: string;
    type: 'buy' | 'sell';
    volume: number;
    sl?: number;
    tp?: number;
  }): Promise<{ ticket: number; error?: string } | null> {
    try {
      const r = await this.http.post('/api/v1/order', {
        symbol: params.symbol,
        type: params.type,
        volume: params.volume,
        stopLoss: params.sl,
        takeProfit: params.tp,
        comment: 'v9-mt5-bot',
      });
      return r.data as { ticket: number; error?: string };
    } catch {
      return null;
    }
  }

  async closeOrder(ticket: number): Promise<boolean> {
    try {
      await this.http.delete(`/api/v1/order/${ticket}`);
      return true;
    } catch {
      return false;
    }
  }

  async ping(): Promise<boolean> {
    try {
      return await this.getAccount() !== null;
    } catch {
      return false;
    }
  }
}
