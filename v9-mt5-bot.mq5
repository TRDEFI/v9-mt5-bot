//+------------------------------------------------------------------+
//|                                          v9-mt5-bot.mq5          |
//+------------------------------------------------------------------+
#property copyright "v9-mt5-bot"
#property version   "2.10"
#property description "1s kline from ticks + MTF signal + execution tracking"
#property description "Scans symbols, builds 1s bars, RSI/EMA/BB/MACD/Stoch/ADX strategy"
#property description "Tracks execution costs, closed trades, net profit targets"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input string InpSymbols     = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,NZDUSD,USDCHF,EURGBP,EURJPY,GBPJPY,XAUUSD,XAGUSD,US30,UK100";
input double InpRiskPercent = 1.0;
input int    InpMaxOpen     = 4;
input int    InpMagic       = 999001;
input double InpMinScore    = 0.75;
input double InpMaxSpread   = 50.0;
input int    InpCooldownSec = 300;
input int    InpMinSLPips   = 15;
input int    InpTimeStopMin = 240;
input int    InpBreakevenPips = 10;
input bool   InpTrail       = true;
input int    InpTrailPips   = 15;
input int    InpLogEvery    = 10;
input int    InpTargetProfit = 10;
input bool   InpTrackExecution = true;
input int    InpSnapIntervalSec = 5;
input bool   InpTrackBridgeCloses = true;
input int    InpLogClosedEvery = 1;

// runtime overrides (config file)
string   gSymbols;
double   gRiskPct;
int      gMaxOpen;
long     gMagic;
double   gMinScore;
double   gMaxSpread;
int      gCooldown;
int      gMinSL;
int      gTimeStop;
int      gBE;
bool     gTrail;
int      gTrailPips;
int      gLogEvery;
int      gTargetProfit;
bool     gTrackExecution;
int      gSnapIntervalSec;
bool     gTrackBridgeCloses;
int      gLogClosedEvery;

//+------------------------------------------------------------------+
//| Execution tracking structs                                       |
//+------------------------------------------------------------------+
struct ExecutionTrack {
   datetime time;
   string   symbol;
   string   type;
   string   signalName;
   double   requestedPrice;
   double   filledPrice;
   double   sl;
   double   tp;
   double   lots;
   double   commission;
   double   swap;
   double   netProfit;
   double   slippage;
   string   closeReason;
};

ExecutionTrack execHistory[];
int execCount = 0;

//+------------------------------------------------------------------+
//| Closed trade tracking                                            |
//+------------------------------------------------------------------+
struct ClosedTrade {
   datetime openTime;
   datetime closeTime;
   string   symbol;
   string   type;
   string   signalName;
   double   profit;
   double   commission;
   double   swap;
   double   netProfit;
   double   lots;
   double   sl;
   double   tp;
   ulong    ticket;
   string   closeReason;
};

ClosedTrade closedTrades[];
int closedCount = 0;

//+------------------------------------------------------------------+
//| Position snapshot for detecting server-side closes               |
//+------------------------------------------------------------------+
ulong    openTickets[];
int      lastClosedTicket = 0;

//+------------------------------------------------------------------+
//| 1s kline structs                                                 |
//+------------------------------------------------------------------+
#define MAX_SEC_BARS 300

struct SecBar {
   datetime time;
   double   open;
   double   high;
   double   low;
   double   close;
   long     volume;
};

struct TickState {
   string   symbol;
   SecBar   bars[MAX_SEC_BARS];
   int      head;
   int      count;
   int      curSec;
   double   curOpen;
   double   curHigh;
   double   curLow;
   double   curClose;
   long     curVol;
   bool     ticking;
   datetime lastSignalTime;
};

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade         trade;
CPositionInfo  pos;
CAccountInfo   acc;

string   syms[];
int      symCount;
TickState ts[];

datetime lastScanTime;
int      timerMs = 200;
int      scanIntervalMs = 1000;
int      tickCount = 0;
int      snapCounter = 0;

//+------------------------------------------------------------------+
//| Config file parser                                                |
//+------------------------------------------------------------------+
#define CONFIG_FILE "v9-config.txt"

void Trim(string &s) {
   int len = StringLen(s);
   int start = 0;
   while (start < len && (s[start] == ' ' || s[start] == '\t' || s[start] == '\r' || s[start] == '\n')) start++;
   int end = len;
   while (end > start && (s[end-1] == ' ' || s[end-1] == '\t' || s[end-1] == '\r' || s[end-1] == '\n')) end--;
   if (start > 0 || end < len)
      s = StringSubstr(s, start, end - start);
}

void ReadConfig() {
   gSymbols = InpSymbols; gRiskPct = InpRiskPercent; gMaxOpen = InpMaxOpen; gMagic = (long)InpMagic;
   gMinScore = InpMinScore; gMaxSpread = InpMaxSpread;
   gCooldown = InpCooldownSec; gMinSL = InpMinSLPips; gTimeStop = InpTimeStopMin;
   gBE = InpBreakevenPips; gTrail = InpTrail; gTrailPips = InpTrailPips; gLogEvery = InpLogEvery;
   gTargetProfit = InpTargetProfit;
   gTrackExecution = InpTrackExecution;
   gSnapIntervalSec = InpSnapIntervalSec;
   gTrackBridgeCloses = InpTrackBridgeCloses;
   gLogClosedEvery = InpLogClosedEvery;

   int h = FileOpen(CONFIG_FILE, FILE_TXT|FILE_READ|FILE_ANSI);
   if (h == INVALID_HANDLE) {
      Print("v9-config.txt not found in MQL5/Files, using EA input defaults");
      return;
   }
   Print("Reading ", CONFIG_FILE);
   while (!FileIsEnding(h)) {
      string line = FileReadString(h);
      line = StringReplace(line, "\r", "");
      line = StringReplace(line, "\n", "");
      Trim(line);
      if (StringLen(line) == 0) continue;
      if (StringFind(line, ";") == 0) continue;
      int eq = StringFind(line, "=");
      if (eq < 0) continue;
      string key = StringSubstr(line, 0, eq);
      string val = StringSubstr(line, eq + 1);
      Trim(key);
      Trim(val);
      if (key == "SYMBOLS") gSymbols = val;
      else if (key == "RISK_PCT") gRiskPct = StringToDouble(val);
      else if (key == "MAX_OPEN") gMaxOpen = (int)StringToInteger(val);
      else if (key == "MAGIC") gMagic = (long)StringToInteger(val);
      else if (key == "MIN_SCORE") gMinScore = StringToDouble(val);
      else if (key == "MAX_SPREAD") gMaxSpread = StringToDouble(val);
      else if (key == "COOLDOWN_SEC") gCooldown = (int)StringToInteger(val);
      else if (key == "MIN_SL_PIPS") gMinSL = (int)StringToInteger(val);
      else if (key == "TIME_STOP_MIN") gTimeStop = (int)StringToInteger(val);
      else if (key == "BREAKEVEN_PIPS") gBE = (int)StringToInteger(val);
      else if (key == "TRAIL") gTrail = (StringToInteger(val) != 0);
      else if (key == "TRAIL_PIPS") gTrailPips = (int)StringToInteger(val);
      else if (key == "LOG_EVERY") gLogEvery = (int)StringToInteger(val);
      else if (key == "TARGET_PROFIT") gTargetProfit = (int)StringToInteger(val);
      else if (key == "TRACK_EXECUTION") gTrackExecution = (StringToInteger(val) != 0);
      else if (key == "SNAP_INTERVAL_SEC") gSnapIntervalSec = (int)StringToInteger(val);
      else if (key == "TRACK_BRIDGE_CLOSES") gTrackBridgeCloses = (StringToInteger(val) != 0);
      else if (key == "LOG_CLOSED_EVERY") gLogClosedEvery = (int)StringToInteger(val);
      else Print("Unknown config key: ", key);
   }
   FileClose(h);
}

//+------------------------------------------------------------------+
int OnInit() {
   ReadConfig();
   trade.SetExpertMagicNumber((int)gMagic);
   string parts[];
   int n = StringSplit(gSymbols, ',', parts);
   symCount = n;
   ArrayResize(syms, n);
   ArrayResize(ts, n);
   for (int i = 0; i < n; i++) {
      syms[i] = parts[i];
      ts[i].symbol = parts[i];
      ts[i].head = 0;
      ts[i].count = 0;
      ts[i].curSec = 0;
      ts[i].ticking = false;
      ts[i].lastSignalTime = 0;
   }
   EventSetMillisecondTimer(timerMs);
   Print("v9-mt5-bot v2.10 ready — ", n, " symbols, magic=", gMagic, " timer=", timerMs, "ms");
   Print("Target profit: $", gTargetProfit, " | Execution tracking: ", (gTrackExecution ? "ON" : "OFF"));
   Print("Snap interval: ", gSnapIntervalSec, "s | Bridge close tracking: ", (gTrackBridgeCloses ? "ON" : "OFF"));
   Comment("v9-mt5-bot v2.10 INIT\n", n, " symbols | target: $", gTargetProfit, "/trade");
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int r) {
   Comment("");
   EventKillTimer();
   Print("v9-mt5-bot v2.10 stopped (reason=", r, ")");
   if (closedCount > 0)
      Print("Session summary: ", closedCount, " closed trades, total net profit: ", calcTotalNetProfit());
}

//+------------------------------------------------------------------+
//| OnTrade: detect server-side closes (SL/TP/manual)                |
//+------------------------------------------------------------------+
void OnTrade() {
   detectClosedPositions();
}

//+------------------------------------------------------------------+
//| Position snapshot for detecting server-side closes               |
//+------------------------------------------------------------------+
void snapshotOpenPositions() {
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (pos.SelectByIndex(i) && pos.Magic() == (int)gMagic)
         count++;
   }
   ArrayResize(openTickets, count);
   count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (pos.SelectByIndex(i) && pos.Magic() == (int)gMagic) {
         openTickets[count] = pos.Ticket();
         count++;
      }
   }
}

void detectClosedPositions() {
   if (closedCount % gLogClosedEvery != 0 && closedCount > 0) return;

   datetime from = TimeCurrent() - 600;
   datetime to = TimeCurrent();
   if (!HistorySelect(from, to)) return;

   for (int j = HistoryDealsTotal() - 1; j >= 0; j--) {
      ulong dealTicket = HistoryDealGetTicket(j);
      if (HistoryDealGetInteger(dealTicket, DEAL_MAGIC) != (int)gMagic) continue;
      if (HistoryDealGetInteger(dealTicket, DEAL_ENTRY) != DEAL_ENTRY_OUT) continue;

      ulong ticket = (ulong)HistoryDealGetInteger(dealTicket, DEAL_TICKET);
      if (ticket == lastClosedTicket) continue;

      string sym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
      ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
      string typeStr = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
      double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
      double comm = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
      double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
      double net = profit + comm + swap;
      datetime closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
      double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);

      if (closedCount >= ArraySize(closedTrades))
         ArrayResize(closedTrades, closedCount + 100);

      closedTrades[closedCount].openTime = closeTime - 3600;
      closedTrades[closedCount].closeTime = closeTime;
      closedTrades[closedCount].symbol = sym;
      closedTrades[closedCount].type = typeStr;
      closedTrades[closedCount].signalName = "";
      closedTrades[closedCount].profit = profit;
      closedTrades[closedCount].commission = comm;
      closedTrades[closedCount].swap = swap;
      closedTrades[closedCount].netProfit = net;
      closedTrades[closedCount].lots = HistoryDealGetDouble(dealTicket, DEAL_VOLUME);
      closedTrades[closedCount].sl = 0;
      closedTrades[closedCount].tp = 0;
      closedTrades[closedCount].ticket = ticket;
      closedTrades[closedCount].closeReason = detectCloseReason(sym, closePrice, dealType);
      closedCount++;

      lastClosedTicket = ticket;

      Print("CLOSED: ", sym, " | ", typeStr,
            " | Profit: ", DoubleToString(profit, 2),
            " | Comm: ", DoubleToString(comm, 2),
            " | Swap: ", DoubleToString(swap, 2),
            " | NET: ", DoubleToString(net, 2),
            " | Reason: ", closedTrades[closedCount-1].closeReason,
            " | Ticket: ", ticket);
   }
}

string detectCloseReason(string sym, double closePrice, ENUM_DEAL_TYPE dealType) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (!pos.SelectByIndex(i)) continue;
      if (pos.Magic() != (int)gMagic) continue;
      if (pos.Symbol() != sym) continue;

      double sl = pos.StopLoss();
      double tp = pos.TakeProfit();
      double open = pos.PriceOpen();
      double pt = SymbolInfoDouble(sym, SYMBOL_POINT);

      if (sl > 0 && MathAbs(closePrice - sl) < 3 * pt) return "SL_HIT";
      if (tp > 0 && MathAbs(closePrice - tp) < 3 * pt) return "TP_HIT";
      if (gBE > 0 && MathAbs(closePrice - open) < 3 * pt) return "BREAKEVEN";
      if (gTimeStop > 0 && (TimeCurrent() - pos.Time()) >= gTimeStop * 60) return "TIME_STOP";
   }
   return "MANUAL_OR_OTHER";
}

double calcTotalNetProfit() {
   double total = 0;
   for (int i = 0; i < closedCount; i++)
      total += closedTrades[i].netProfit;
   return total;
}

//+------------------------------------------------------------------+
//| Timer: main loop every 200ms                                     |
//+------------------------------------------------------------------+
void OnTimer() {
   tickCount++;

   // 1. feed ticks for all symbols
   for (int s = 0; s < symCount; s++)
      feedTick(s);

   // 2. finalize completed seconds
   finalizeSecs();

   // 3. manage open positions (trail, breakeven, time stop)
   managePositions();

   // 4. scan for signals (once per second)
   if (GetTickCount() - lastScanTime >= scanIntervalMs) {
      lastScanTime = GetTickCount();
      scanSymbols();
   }

   // 5. position snapshot + closed trade detection
   snapCounter++;
   if (gTrackBridgeCloses && snapCounter >= gSnapIntervalSec) {
      snapCounter = 0;
      snapshotOpenPositions();
      detectClosedPositions();
   }

   // 6. update chart
   drawComment();
}

//+------------------------------------------------------------------+
//| Feed a tick into the 1s kline builder for symbol s               |
//+------------------------------------------------------------------+
void feedTick(int s) {
   MqlTick tick;
   if (!SymbolInfoTick(syms[s], tick)) return;

   int secStart = (int)(tick.time);

   if (secStart != ts[s].curSec) {
      // finalize previous second if active
      if (ts[s].ticking) {
         int idx = ts[s].head % MAX_SEC_BARS;
         ts[s].bars[idx].time   = (datetime)ts[s].curSec;
         ts[s].bars[idx].open   = ts[s].curOpen;
         ts[s].bars[idx].high   = ts[s].curHigh;
         ts[s].bars[idx].low    = ts[s].curLow;
         ts[s].bars[idx].close  = ts[s].curClose;
         ts[s].bars[idx].volume = ts[s].curVol;
         ts[s].head = (ts[s].head + 1) % MAX_SEC_BARS;
         if (ts[s].count < MAX_SEC_BARS) ts[s].count++;
      }
      // start new second
      ts[s].curSec   = secStart;
      ts[s].curOpen  = (tick.bid != 0 ? tick.bid : tick.ask);
      ts[s].curHigh  = ts[s].curOpen;
      ts[s].curLow   = ts[s].curOpen;
      ts[s].curClose = ts[s].curOpen;
      ts[s].curVol   = 1;
      ts[s].ticking  = true;
   } else {
      // update current second
      double price = (tick.bid != 0 ? tick.bid : tick.ask);
      ts[s].curHigh  = MathMax(ts[s].curHigh, price);
      ts[s].curLow   = MathMin(ts[s].curLow, price);
      ts[s].curClose = price;
      ts[s].curVol++;
   }
}

//+------------------------------------------------------------------+
//| Finalize any bars where the second has elapsed (catch-up)        |
//+------------------------------------------------------------------+
void finalizeSecs() {
   int nowSec = (int)TimeCurrent();
   for (int s = 0; s < symCount; s++) {
      while (ts[s].ticking && ts[s].curSec < nowSec) {
         // finalize the completed second
         int idx = ts[s].head % MAX_SEC_BARS;
         ts[s].bars[idx].time   = (datetime)ts[s].curSec;
         ts[s].bars[idx].open   = ts[s].curOpen;
         ts[s].bars[idx].high   = ts[s].curHigh;
         ts[s].bars[idx].low    = ts[s].curLow;
         ts[s].bars[idx].close  = ts[s].curClose;
         ts[s].bars[idx].volume = ts[s].curVol;
         ts[s].head = (ts[s].head + 1) % MAX_SEC_BARS;
         if (ts[s].count < MAX_SEC_BARS) ts[s].count++;

         // start next second (carry close as open)
         ts[s].curSec++;
         ts[s].curOpen  = ts[s].curClose;
         ts[s].curHigh  = ts[s].curClose;
         ts[s].curLow   = ts[s].curClose;
         ts[s].curVol   = 0;
         ts[s].ticking  = false; // no tick yet in this new second
      }
   }
}

//+------------------------------------------------------------------+
//| Convert 1s kline circular buffer to linear MqlRates[]            |
//+------------------------------------------------------------------+
int get1sRates(int s, MqlRates &out[], int maxCount) {
   int have = MathMin(ts[s].count, maxCount);
   if (have < 2) return 0;
   ArrayResize(out, have);
   int start = (ts[s].head - have + MAX_SEC_BARS) % MAX_SEC_BARS;
   for (int i = 0; i < have; i++) {
      int src = (start + i) % MAX_SEC_BARS;
      out[i].time   = ts[s].bars[src].time;
      out[i].open   = ts[s].bars[src].open;
      out[i].high   = ts[s].bars[src].high;
      out[i].low    = ts[s].bars[src].low;
      out[i].close  = ts[s].bars[src].close;
      out[i].tick_volume = ts[s].bars[src].volume;
      out[i].real_volume = ts[s].bars[src].volume;
   }
   return have;
}

//+------------------------------------------------------------------+
//| Get rates from multiple timeframes                               |
//+------------------------------------------------------------------+
bool getMtfRates(string sym, ENUM_TIMEFRAMES tf1, ENUM_TIMEFRAMES tf2, ENUM_TIMEFRAMES tf3,
                 MqlRates &r1[], MqlRates &r2[], MqlRates &r3[], int &got1, int &got2, int &got3) {
   got1 = CopyRates(sym, tf1, 1, 100, r1);
   got2 = CopyRates(sym, tf2, 1, 100, r2);
   got3 = CopyRates(sym, tf3, 1, 100, r3);
   return (got1 >= 20 && got2 >= 20 && got3 >= 20);
}

//+------------------------------------------------------------------+
//| Manage open positions: trail, breakeven, time stop               |
//+------------------------------------------------------------------+
void managePositions() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (!pos.SelectByIndex(i)) continue;
      if (pos.Magic() != (int)gMagic) continue;

      // time stop
      if (gTimeStop > 0) {
         datetime age = TimeCurrent() - pos.Time();
         if (age >= gTimeStop * 60) {
            Print(pos.Symbol(), " | TIME STOP — age=", age / 60, "min, closing ticket=", pos.Ticket());
            trade.PositionClose(pos.Ticket());
            continue;
         }
      }

      // breakeven
      if (gBE > 0) {
         double open  = pos.PriceOpen();
         double curr  = pos.PriceCurrent();
         double sl    = pos.StopLoss();
         double pt    = SymbolInfoDouble(pos.Symbol(), SYMBOL_POINT);
         double bePts = gBE * 10 * pt;

         if (pos.PositionType() == POSITION_TYPE_BUY) {
            if (curr - open >= bePts && (sl == 0 || sl < open)) {
               trade.PositionModify(pos.Ticket(), open, pos.TakeProfit());
               Print(pos.Symbol(), " | BREAKEVEN triggered");
            }
         } else if (pos.PositionType() == POSITION_TYPE_SELL) {
            if (open - curr >= bePts && (sl == 0 || sl > open)) {
               trade.PositionModify(pos.Ticket(), open, pos.TakeProfit());
               Print(pos.Symbol(), " | BREAKEVEN triggered");
            }
         }
      }

      // trailing stop
      if (gTrail) doTrail(i);
   }
}

//+------------------------------------------------------------------+
//| Scan all symbols for trade signals                                |
//+------------------------------------------------------------------+
void scanSymbols() {
   int openCount = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (pos.SelectByIndex(i) && pos.Magic() == (int)gMagic)
         openCount++;
   }

   int placed = 0, skippedPos = 0, skippedCool = 0, skippedData = 0, skippedSpread = 0, noSig = 0;

   for (int s = 0; s < symCount; s++) {
      if (openCount + placed >= gMaxOpen) break;
      if (hasPos(syms[s])) { skippedPos++; continue; }
      if (TimeCurrent() - ts[s].lastSignalTime < gCooldown) { skippedCool++; continue; }

      MqlRates r1[], r3[], r15[];
      int got1, got3, got15;
      if (!getMtfRates(syms[s], PERIOD_M1, PERIOD_M3, PERIOD_M15, r1, r3, r15, got1, got3, got15)) {
         skippedData++; continue;
      }

      double sp = (double)SymbolInfoInteger(syms[s], SYMBOL_SPREAD);
      if (sp > gMaxSpread) { skippedSpread++; continue; }

      double rsiVal = calcRsi(r15, got15, 14);
      Signal sig;
      if (getSignal(r1, r3, r15, got1, got3, got15, sig) && sig.score >= gMinScore) {
         if (tickCount % gLogEvery == 0)
            Print(">>> ", syms[s], " | SIGNAL: ", sig.name, " side=", (sig.side == 1 ? "LONG" : "SHORT"),
                  " score=", sig.score, " rsi=", DoubleToString(rsiVal, 1));
         if (execTrade(syms[s], sig)) {
            ts[s].lastSignalTime = TimeCurrent();
            placed++;
         }
      } else {
         noSig++;
         if (tickCount % gLogEvery == 0)
            Print(">>> ", syms[s], " | no signal (rsi=", DoubleToString(rsiVal, 1),
                  " score=", (sig.score > 0 ? DoubleToString(sig.score, 2) : "0.00"), ")");
      }
   }

   if (tickCount % gLogEvery == 0)
      Print("=== SCAN | open=", openCount, " placed=", placed,
            " hasPos=", skippedPos, " cooldown=", skippedCool,
            " noData=", skippedData, " spread=", skippedSpread, " noSig=", noSig);
}

//+------------------------------------------------------------------+
//| Indicator helpers                                                |
//+------------------------------------------------------------------+
double calcRsi(const MqlRates &r[], int total, int p = 14) {
   if (total <= p + 1) return 50;
   double g = 0, l = 0;
   for (int i = total - p; i < total; i++) {
      double d = r[i].close - r[i-1].close;
      if (d > 0) g += d; else l -= d;
   }
   double ag = g / p, al = l / p;
   for (int i = 1; i <= p; i++) {
      double d = r[i].close - r[i-1].close;
      double dg = (d > 0) ? d : 0, dl = (d < 0) ? -d : 0;
      ag = (ag * (p - 1) + dg) / p;
      al = (al * (p - 1) + dl) / p;
   }
   for (int i = p + 1; i < total; i++) {
      double d = r[i].close - r[i-1].close;
      ag = (ag * (p - 1) + ((d > 0) ? d : 0)) / p;
      al = (al * (p - 1) + ((d < 0) ? -d : 0)) / p;
   }
   if (al == 0) return 100;
   return 100 - 100 / (1 + ag / al);
}

double calcMa(const MqlRates &r[], int total, int p) {
   if (total < p) return 0;
   double s = 0;
   for (int i = total - p; i < total; i++) s += r[i].close;
   return s / p;
}

double calcEma(const MqlRates &r[], int total, int p) {
   if (total < p) return 0;
   double k = 2.0 / (p + 1);
   double ema = 0;
   for (int i = 0; i < p; i++) ema += r[i].close;
   ema /= p;
   for (int i = p; i < total; i++)
      ema = (r[i].close - ema) * k + ema;
   return ema;
}

double calcAtr(const MqlRates &r[], int total, int p = 14) {
   if (total < p) return 0;
   double sum = 0;
   for (int i = total - p; i < total; i++) {
      double tr = MathMax(r[i].high - r[i].low,
                  MathMax(MathAbs(r[i].high - r[i-1].close),
                          MathAbs(r[i].low - r[i-1].close)));
      sum += tr;
   }
   return sum / p;
}

void calcBb(const MqlRates &r[], int total, double &up, double &dn, double &sma, int p = 20, double sd = 2.0) {
   up = 0; dn = 0; sma = 0;
   if (total < p) return;
   sma = calcMa(r, total, p);
   double var = 0;
   for (int i = total - p; i < total; i++)
      var += MathPow(r[i].close - sma, 2);
   var /= p;
   double std = MathSqrt(var);
   up = sma + sd * std;
   dn = sma - sd * std;
}

double calcVolRatio(const MqlRates &r[], int total, int p = 20) {
   if (total < p + 1) return 1;
   double cur = (double)r[total - 1].tick_volume;
   double avg = 0;
   for (int i = total - p - 1; i < total - 1; i++) avg += (double)r[i].tick_volume;
   avg /= p;
   return (avg == 0) ? 1 : cur / avg;
}

double calcMacd(const MqlRates &r[], int total, int fast, int slow, int signal, double &macdLine, double &signalLine) {
   if (total < slow + signal) return 0;
   double emaFast = calcEma(r, total, fast);
   double emaSlow = calcEma(r, total, slow);
   macdLine = emaFast - emaSlow;
   signalLine = calcEma(r, total, signal);
   return macdLine - signalLine;
}

double calcStoch(const MqlRates &r[], int total, int kPeriod, int dPeriod, double &kVal, double &dVal) {
   if (total < kPeriod + dPeriod) return 0;
   double highest = 0, lowest = 999999;
   for (int i = total - kPeriod; i < total; i++) {
      if (r[i].high > highest) highest = r[i].high;
      if (r[i].low < lowest) lowest = r[i].low;
   }
   if (highest == lowest) { kVal = 50; dVal = 50; return 0; }
   kVal = 100.0 * (r[total-1].close - lowest) / (highest - lowest);
   dVal = kVal;
   for (int i = total - kPeriod - 1; i < total - 1; i++)
      dVal = (dVal * 2.0 + kVal) / 3.0;
   return kVal - dVal;
}

double calcAdx(const MqlRates &r[], int total, int p = 14) {
   if (total < p + 1) return 0;
   double plusDM = 0, minusDM = 0, tr = 0;
   for (int i = total - p; i < total; i++) {
      double upMove = r[i].high - r[i-1].high;
      double downMove = r[i-1].low - r[i].low;
      if (upMove > downMove && upMove > 0) plusDM += upMove;
      if (downMove > upMove && downMove > 0) minusDM += downMove;
      tr += MathMax(r[i].high - r[i].low,
             MathMax(MathAbs(r[i].high - r[i-1].close),
                     MathAbs(r[i].low - r[i-1].close)));
   }
   if (tr == 0) return 0;
   plusDM = 100.0 * plusDM / tr;
   minusDM = 100.0 * minusDM / tr;
   double dx = MathAbs(plusDM - minusDM) / (plusDM + minusDM) * 100;
   return dx;
}

//+------------------------------------------------------------------+
//| Signal structure                                                 |
//+------------------------------------------------------------------+
struct Signal {
   string name;
   double score;
   double avgMove;
   int    side;
   double tp;
   double sl;
};

//+------------------------------------------------------------------+
//| Multi-timeframe signal detection                                 |
//+------------------------------------------------------------------+
bool getSignal(const MqlRates &r1[], const MqlRates &r3[], const MqlRates &r15[], int got1, int got3, int got15, Signal &out) {
   if (got1 < 20 || got3 < 20 || got15 < 20) return false;

   double rsi   = calcRsi(r15, got15, 14);
   double rsi1  = calcRsi(r1, got1, 14);
   double rsi3  = calcRsi(r3, got3, 14);
   double ma10  = calcMa(r15, got15, 10);
   double ma20  = calcMa(r15, got15, 20);
   double ema9  = calcEma(r15, got15, 9);
   double ema21 = calcEma(r15, got15, 21);
   double ema50 = calcEma(r15, got15, 50);
   double vr    = calcVolRatio(r15, got15, 20);
   double atr   = calcAtr(r15, got15, 14);
   double p     = r15[got15 - 1].close;
   double dev   = ((p - ma10) / ma10) * 100;

   bool tf1Bull = r1[got1-1].close > calcEma(r1, got1, 20);
   bool tf3Bull = r3[got3-1].close > calcEma(r3, got3, 20);
   bool tf15Bull = r15[got15-1].close > calcEma(r15, got15, 20);
   bool trendUp = (tf1Bull && tf3Bull) || (tf1Bull && tf15Bull);
   bool trendDn = (!tf1Bull && !tf3Bull) || (!tf1Bull && !tf15Bull);

   double bbUp, bbDn, bbSma;
   calcBb(r15, got15, bbUp, bbDn, bbSma, 20, 2);

   double macdLine, signalLine, macdHist;
   macdHist = calcMacd(r15, got15, 12, 26, 9, macdLine, signalLine);

   double stochK, stochD, stochDiff;
   stochDiff = calcStoch(r15, got15, 14, 3, stochK, stochD);

   double adx = calcAdx(r15, got15, 14);

   string names[25];
   double scores[25];
   int    sides[25];
   double tpVals[25];
   double slVals[25];
   double avgMoves[25];
   int sigN = 0;

   double rsiPrev = calcRsi(r15, got15 - 1, 14);
   double lastO = r15[got15 - 1].open, lastC = r15[got15 - 1].close;
   bool green = lastC > lastO;

   if (rsiPrev >= 30 && rsi < 30 && green && rsi3 < 40) {
      names[sigN] = "RSI_OVERSOLD"; scores[sigN] = 0.88; sides[sigN] = 1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }
   if (rsiPrev <= 70 && rsi > 70 && !green && rsi3 > 60) {
      names[sigN] = "RSI_OVERBOUGHT"; scores[sigN] = 0.88; sides[sigN] = -1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }

   if (dev < -2.5 && rsi < 40 && trendUp) {
      names[sigN] = "MA10_BOUNCE"; scores[sigN] = 0.86; sides[sigN] = 1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }
   if (dev > 2.5 && rsi > 60 && trendDn) {
      names[sigN] = "MA10_REJECT"; scores[sigN] = 0.86; sides[sigN] = -1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }

   double ema9Prev  = calcEma(r15, got15 - 1, 9);
   double ema21Prev = calcEma(r15, got15 - 1, 21);
   bool crossUp  = ema9Prev <= ema21Prev && ema9 > ema21;
   bool crossDn  = ema9Prev >= ema21Prev && ema9 < ema21;
   double ema21Slope = (ema21Prev > 0) ? (ema21 - ema21Prev) / ema21Prev : 0;

   if (crossUp && vr > 2.0 && rsi < 65 && green && ema21Slope > -0.0005 && adx > 20) {
      names[sigN] = "EMA_CROSS_UP"; scores[sigN] = 0.85; sides[sigN] = 1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }
   if (crossDn && vr > 2.0 && rsi > 35 && adx > 20) {
      names[sigN] = "EMA_CROSS_DN"; scores[sigN] = 0.85; sides[sigN] = -1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }

   if (bbDn > 0 && p < bbDn * 1.002 && rsi < 35 && vr > 1.3 && ema50 > 0 && p > ema50 * 0.995 && macdHist > 0) {
      names[sigN] = "BB_REV_LONG"; scores[sigN] = 0.87; sides[sigN] = 1;
      avgMoves[sigN] = atr; tpVals[sigN] = bbSma; slVals[sigN] = bbDn * 0.997; sigN++;
   }
   if (bbUp > 0 && p > bbUp * 0.998 && rsi > 65 && vr > 1.3 && ema50 > 0 && p < ema50 * 1.005 && macdHist < 0) {
      names[sigN] = "BB_REV_SHORT"; scores[sigN] = 0.87; sides[sigN] = -1;
      avgMoves[sigN] = atr; tpVals[sigN] = bbSma; slVals[sigN] = bbUp * 1.003; sigN++;
   }

   if (ma10 > ma20 && dev < -1.5 && rsi < 50 && stochK < 30 && trendUp) {
      names[sigN] = "TREND_LONG"; scores[sigN] = 0.84; sides[sigN] = 1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }
   if (ma10 < ma20 && dev > 1.5 && rsi > 50 && stochK > 70 && trendDn) {
      names[sigN] = "TREND_SHORT"; scores[sigN] = 0.84; sides[sigN] = -1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }

   if (vr > 2.5 && p > ma10 && rsi < 60 && rsi1 < 65 && tf1Bull) {
      names[sigN] = "VOL_BREAKUP"; scores[sigN] = 0.82; sides[sigN] = 1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }
   if (vr > 2.5 && p < ma10 && rsi > 40 && rsi1 > 35 && !tf1Bull) {
      names[sigN] = "VOL_BREAKDN"; scores[sigN] = 0.82; sides[sigN] = -1;
      avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
   }

   if (vr > 2.0 && got15 >= 3) {
      int d1 = (r15[got15 - 3].close > r15[got15 - 3].open) ? 1 : -1;
      int d2 = (r15[got15 - 2].close > r15[got15 - 2].open) ? 1 : -1;
      int d3 = (r15[got15 - 1].close > r15[got15 - 1].open) ? 1 : -1;
      if (d1 == d2 && d2 == d3) {
         bool bull = (d3 == 1);
         if (bull && p > ema50 && rsi < 60 && tf3Bull) {
            names[sigN] = "MOMENTUM_LONG"; scores[sigN] = 0.83; sides[sigN] = 1;
            avgMoves[sigN] = atr; tpVals[sigN] = p + atr * 1.5; slVals[sigN] = p - atr * 0.7; sigN++;
         }
         if (!bull && p < ema50 && rsi > 40 && !tf3Bull) {
            names[sigN] = "MOMENTUM_SHORT"; scores[sigN] = 0.83; sides[sigN] = -1;
            avgMoves[sigN] = atr; tpVals[sigN] = p - atr * 1.5; slVals[sigN] = p + atr * 0.7; sigN++;
         }
      }
   }

   if (vr < 0.5 && adx < 20) {
      if (rsi < 35 && stochK < 20) {
         names[sigN] = "SQUEEZE_LONG"; scores[sigN] = 0.80; sides[sigN] = 1;
         avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
      }
      if (rsi > 65 && stochK > 80) {
         names[sigN] = "SQUEEZE_SHORT"; scores[sigN] = 0.80; sides[sigN] = -1;
         avgMoves[sigN] = atr; tpVals[sigN] = 0; slVals[sigN] = 0; sigN++;
      }
   }

   int best = -1;
   double bestSc = 0;
   for (int i = 0; i < sigN; i++) {
      if (scores[i] >= 0.80 && scores[i] > bestSc) {
         best = i;
         bestSc = scores[i];
      }
   }

   if (best < 0) return false;

   out.name    = names[best];
   out.score   = scores[best];
   out.side    = sides[best];
   out.avgMove = avgMoves[best];
   out.tp      = tpVals[best];
   out.sl      = slVals[best];
   return true;
}

//+------------------------------------------------------------------+
//| Trade execution with tracking                                    |
//+------------------------------------------------------------------+
bool execTrade(string sym, Signal &sig) {
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double price = (sig.side == 1) ? ask : bid;
   double pt   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minSL = gMinSL * 10 * pt;

   double slDist = (sig.sl > 0) ? MathAbs(price - sig.sl) : MathMax(sig.avgMove, MathMax(minSL, pt * 200));
   double lots = calcLotByRisk(sym, price, slDist, sig.side);
   if (lots < SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN)) return false;

   double sl = (sig.sl > 0) ? sig.sl : (sig.side == 1) ? price - slDist : price + slDist;
   double tp = (sig.tp > 0) ? sig.tp : (sig.side == 1) ? price + slDist * 1.5 : price - slDist * 1.5;

   double minProfitDist = (gTargetProfit + 5.0) / (lots * 100000.0 / SymbolInfoDouble(sym, SYMBOL_POINT));
   if (sig.side == 1) {
      tp = MathMax(tp, price + MathMax(slDist * 1.5, minProfitDist));
   } else {
      tp = MathMin(tp, price - MathMax(slDist * 1.5, minProfitDist));
   }

   ENUM_ORDER_TYPE type = (sig.side == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string typeStr = (sig.side == 1) ? "BUY" : "SELL";

   trade.PositionOpen(sym, type, lots, price, sl, tp, "v9-" + sig.name);
   bool ok = trade.ResultRetcode() == TRADE_RETCODE_DONE;

   if (ok) {
      double fillPrice = trade.ResultPrice();
      double slippage = MathAbs(fillPrice - price);

      Print(sym, " | ", typeStr, " ", sig.name, " score=", sig.score, " lots=", lots,
            " req=", price, " fill=", fillPrice, " slip=", DoubleToString(slippage, 5),
            " sl=", sl, " tp=", tp, " ticket=", trade.ResultOrder());

      if (gTrackExecution) {
         if (execCount >= ArraySize(execHistory))
            ArrayResize(execHistory, execCount + 100);

         execHistory[execCount].time = TimeCurrent();
         execHistory[execCount].symbol = sym;
         execHistory[execCount].type = typeStr;
         execHistory[execCount].signalName = sig.name;
         execHistory[execCount].requestedPrice = price;
         execHistory[execCount].filledPrice = fillPrice;
         execHistory[execCount].sl = sl;
         execHistory[execCount].tp = tp;
         execHistory[execCount].lots = lots;
         execHistory[execCount].commission = 0;
         execHistory[execCount].swap = 0;
         execHistory[execCount].slippage = slippage;
         execCount++;
      }
   } else {
      Print(sym, " | FAILED ", typeStr, " ", sig.name, " retcode=", trade.ResultRetcode(),
            " comment=", trade.ResultComment());
   }

   return ok;
}

//+------------------------------------------------------------------+
//| Calculate lot size using MT5's built-in profit calculator        |
//+------------------------------------------------------------------+
double calcLotByRisk(string sym, double entry, double slDist, int side) {
   double maxRisk = acc.Balance() * (gRiskPct / 100.0);
   double minV = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);

   double slPrice = (side == 1) ? entry - slDist : entry + slDist;
   int type = (side == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;

   double profit1 = 0;
   if (!OrderCalcProfit((ENUM_ORDER_TYPE)type, sym, 1.0, entry, slPrice, profit1))
      return minV;
   if (profit1 >= 0) return minV;

   double raw = maxRisk / MathAbs(profit1);
   double lots = MathFloor(raw / step) * step;
   lots = MathMax(minV, MathMin(lots, maxV));
   return lots;
}

//+------------------------------------------------------------------+
//| Position helpers                                                 |
//+------------------------------------------------------------------+
bool hasPos(string sym) {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (pos.SelectByIndex(i) && pos.Magic() == (int)gMagic && pos.Symbol() == sym)
         return true;
   }
   return false;
}

void doTrail(int idx) {
   if (!pos.SelectByIndex(idx)) return;
   if (pos.Magic() != (int)gMagic) return;

   double sl = pos.StopLoss();
   double open = pos.PriceOpen();
   double curr = pos.PriceCurrent();
   double pt   = SymbolInfoDouble(pos.Symbol(), SYMBOL_POINT);
   double trailPts = gTrailPips * 10 * pt;
   double slNew = sl;

   if (pos.PositionType() == POSITION_TYPE_BUY) {
      double trailFrom = open + trailPts * 1.5;
      if (curr > trailFrom) {
         double proposed = curr - trailPts;
         if (proposed > sl && proposed > open)
            slNew = proposed;
      }
   } else if (pos.PositionType() == POSITION_TYPE_SELL) {
      double trailFrom = open - trailPts * 1.5;
      if (curr < trailFrom) {
         double proposed = curr + trailPts;
         if ((sl == 0 || proposed < sl) && proposed < open)
            slNew = proposed;
      }
   }

   if (slNew != sl)
      trade.PositionModify(pos.Ticket(), slNew, pos.TakeProfit());
}

//+------------------------------------------------------------------+
//| Chart comment with execution stats                               |
//+------------------------------------------------------------------+
void drawComment() {
   int open = 0;
   double totalPnL = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (pos.SelectByIndex(i) && pos.Magic() == (int)gMagic) {
         open++;
         totalPnL += pos.Profit();
      }
   }

   double avgSlippage = 0;
   if (execCount > 0) {
      double totalSlip = 0;
      for (int i = 0; i < execCount; i++)
         totalSlip += execHistory[i].slippage;
      avgSlippage = totalSlip / execCount;
   }

   string txt = StringFormat(
      "v9-mt5-bot v2.10 | Open: %d/%d | PnL: %.2f | Bal: %.2f\nNet Closed: %.2f | Avg Slip: %.5f\nTarget: $%d/trade | Track: %s",
      open, gMaxOpen, totalPnL, acc.Balance(), calcTotalNetProfit(), avgSlippage,
      gTargetProfit, (gTrackExecution ? "ON" : "OFF"));
   Comment(txt);
}
//+------------------------------------------------------------------+
