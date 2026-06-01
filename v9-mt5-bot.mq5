//+------------------------------------------------------------------+
//|                                          v9-mt5-bot.mq5          |
//+------------------------------------------------------------------+
#property copyright "v9-mt5-bot"
#property version   "3.00"
#property description "Hybrid scalping EA with tick-level execution tracking"
#property description "Tick imbalance + spread compression + quote velocity + micro pullback + cross sync + entropy"
#property description "Kill-zone filter, correlation guard, daily loss limit"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\AccountInfo.mqh>

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
input string InpSymbols     = "EURUSD,GBPUSD,USDJPY,AUDUSD,USDCAD,NZDUSD,USDCHF,EURGBP,EURJPY,GBPJPY,XAUUSD,XAGUSD,US30,UK100";
input double InpRiskPercent = 0.25;
input int    InpMaxOpen     = 6;
input int    InpMagic       = 999001;
input double InpMinScore    = 0.70;
input double InpMaxSpread   = 30.0;
input int    InpCooldownSec = 5;
input int    InpMinSLPips   = 3;
input int    InpMaxSLPips   = 5;
input int    InpTimeStopSec = 45;
input int    InpBreakevenPips = 2;
input bool   InpTrail       = true;
input int    InpTrailPips   = 2;
input int    InpLogEvery    = 10;
input int    InpTargetProfit = 10;
input bool   InpTrackExecution = true;
input int    InpSnapIntervalSec = 5;
input bool   InpTrackBridgeCloses = true;
input int    InpLogClosedEvery = 1;

// === Scalping mode ===
input bool   InpScalpMode   = true;

// === Hybrid detector weights (TICK_IMB + SPREAD_COMP primary) ===
input double InpWTickImb    = 0.40;
input double InpWSpreadComp = 0.30;
input double InpWQuoteVel   = 0.15;
input double InpWMicroPull  = 0.08;
input double InpWCrossSync  = 0.04;
input double InpWEntropy    = 0.03;
input int    InpMinAgreeing = 2;

// === Kill zones (all sessions enabled by default) ===
input bool   InpKillLondon  = true;
input int    InpKillLondonStart = 800;
input int    InpKillLondonEnd   = 1200;
input bool   InpKillNY      = true;
input int    InpKillNYStart     = 1330;
input int    InpKillNYEnd       = 1700;
input bool   InpKillAsian    = true;
input int    InpKillAsianStart  = 2200;
input int    InpKillAsianEnd    = 200;

// === Risk limits ===
input double InpDailyLossPct = 2.0;
input bool   InpCorrelationFilter = true;
input double InpAtrMinPips   = 2.0;

// runtime overrides (config file)
string   gSymbols;
double   gRiskPct;
int      gMaxOpen;
long     gMagic;
double   gMinScore;
double   gMaxSpread;
int      gCooldown;
int      gMinSL;
int      gMaxSL;
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
bool     gScalpMode;
double   gWTickImb;
double   gWSpreadComp;
double   gWQuoteVel;
double   gWMicroPull;
double   gWCrossSync;
double   gWEntropy;
int      gMinAgreeing;
bool     gKillLondon;
int      gKillLondonStart;
int      gKillLondonEnd;
bool     gKillNY;
int      gKillNYStart;
int      gKillNYEnd;
bool     gKillAsian;
int      gKillAsianStart;
int      gKillAsianEnd;
double   gDailyLossPct;
bool     gCorrelationFilter;
double   gAtrMinPips;

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
ulong    processedDealTickets[];
int      processedCount = 0;

//+------------------------------------------------------------------+
//| Tick data structures                                             |
//+------------------------------------------------------------------+
#define MAX_TICK_BUF 100

struct TickSample {
   double bid;
   double ask;
   datetime time;
   long   volume;
};

struct SymbolState {
   TickSample ticks[MAX_TICK_BUF];
   int tickHead;
   int tickCount;
   double spreadHistory[20];
   int spreadHead;
   int spreadCount;
   double lastSpread;
   datetime lastTickTime;
   int ticksPerSecond;
   double lastVelocity;
   datetime lastImpulseTime;
   int impulseDir; // 1=buy, -1=sell, 0=none
};

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
SymbolState symSt[];

datetime lastScanTime;
int      timerMs = 50;
int      scanIntervalMs = 200;
int      tickCount = 0;
int      snapCounter = 0;
double   dailyNetProfit = 0;
datetime lastTradeTime = 0;

//+------------------------------------------------------------------+
//| Correlation groups                                               |
//+------------------------------------------------------------------+
string corrGroups[][3] = {
   {"EURUSD","GBPUSD","USDCHF"},
   {"EURUSD","EURGBP","EURJPY"},
   {"GBPUSD","EURGBP","GBPJPY"},
   {"USDJPY","AUDUSD","NZDUSD"},
   {"XAUUSD","XAGUSD","US30"}
};

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
    gCooldown = InpCooldownSec; gMinSL = InpMinSLPips; gMaxSL = InpMaxSLPips;
    gTimeStop = InpTimeStopSec; gBE = InpBreakevenPips; gTrail = InpTrail; gTrailPips = InpTrailPips;
    gLogEvery = InpLogEvery; gTargetProfit = InpTargetProfit; gTrackExecution = InpTrackExecution;
    gSnapIntervalSec = InpSnapIntervalSec; gTrackBridgeCloses = InpTrackBridgeCloses;
    gLogClosedEvery = InpLogClosedEvery;
    gScalpMode = InpScalpMode;
    gWTickImb = InpWTickImb; gWSpreadComp = InpWSpreadComp; gWQuoteVel = InpWQuoteVel;
    gWMicroPull = InpWMicroPull; gWCrossSync = InpWCrossSync; gWEntropy = InpWEntropy;
    gMinAgreeing = InpMinAgreeing;
    gKillLondon = InpKillLondon; gKillLondonStart = (InpKillLondonStart/100)*60 + (InpKillLondonStart%100); gKillLondonEnd = (InpKillLondonEnd/100)*60 + (InpKillLondonEnd%100);
    gKillNY = InpKillNY; gKillNYStart = (InpKillNYStart/100)*60 + (InpKillNYStart%100); gKillNYEnd = (InpKillNYEnd/100)*60 + (InpKillNYEnd%100);
    gKillAsian = InpKillAsian; gKillAsianStart = (InpKillAsianStart/100)*60 + (InpKillAsianStart%100); gKillAsianEnd = (InpKillAsianEnd/100)*60 + (InpKillAsianEnd%100);
    gDailyLossPct = InpDailyLossPct; gCorrelationFilter = InpCorrelationFilter; gAtrMinPips = InpAtrMinPips;

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
      else if (key == "MAX_SL_PIPS") gMaxSL = (int)StringToInteger(val);
      else if (key == "TIME_STOP_SEC") gTimeStop = (int)StringToInteger(val);
      else if (key == "BREAKEVEN_PIPS") gBE = (int)StringToInteger(val);
      else if (key == "TRAIL") gTrail = (StringToInteger(val) != 0);
      else if (key == "TRAIL_PIPS") gTrailPips = (int)StringToInteger(val);
      else if (key == "LOG_EVERY") gLogEvery = (int)StringToInteger(val);
      else if (key == "TARGET_PROFIT") gTargetProfit = (int)StringToInteger(val);
      else if (key == "TRACK_EXECUTION") gTrackExecution = (StringToInteger(val) != 0);
      else if (key == "SNAP_INTERVAL_SEC") gSnapIntervalSec = (int)StringToInteger(val);
      else if (key == "TRACK_BRIDGE_CLOSES") gTrackBridgeCloses = (StringToInteger(val) != 0);
      else if (key == "LOG_CLOSED_EVERY") gLogClosedEvery = (int)StringToInteger(val);
      else if (key == "SCALP_MODE") gScalpMode = (StringToInteger(val) != 0);
      else if (key == "W_TICK_IMB") gWTickImb = StringToDouble(val);
      else if (key == "W_SPREAD_COMP") gWSpreadComp = StringToDouble(val);
      else if (key == "W_QUOTE_VEL") gWQuoteVel = StringToDouble(val);
      else if (key == "W_MICRO_PULL") gWMicroPull = StringToDouble(val);
      else if (key == "W_CROSS_SYNC") gWCrossSync = StringToDouble(val);
      else if (key == "W_ENTROPY") gWEntropy = StringToDouble(val);
      else if (key == "MIN_AGREEING") gMinAgreeing = (int)StringToInteger(val);
       else if (key == "KILL_LONDON") gKillLondon = (StringToInteger(val) != 0);
       else if (key == "KILL_LONDON_START") gKillLondonStart = (StringToInteger(val)/100)*60 + (StringToInteger(val)%100);
       else if (key == "KILL_LONDON_END") gKillLondonEnd = (StringToInteger(val)/100)*60 + (StringToInteger(val)%100);
       else if (key == "KILL_NY") gKillNY = (StringToInteger(val) != 0);
       else if (key == "KILL_NY_START") gKillNYStart = (StringToInteger(val)/100)*60 + (StringToInteger(val)%100);
       else if (key == "KILL_NY_END") gKillNYEnd = (StringToInteger(val)/100)*60 + (StringToInteger(val)%100);
       else if (key == "KILL_ASIAN") gKillAsian = (StringToInteger(val) != 0);
       else if (key == "KILL_ASIAN_START") gKillAsianStart = (StringToInteger(val)/100)*60 + (StringToInteger(val)%100);
       else if (key == "KILL_ASIAN_END") gKillAsianEnd = (StringToInteger(val)/100)*60 + (StringToInteger(val)%100);
      else if (key == "DAILY_LOSS_PCT") gDailyLossPct = StringToDouble(val);
      else if (key == "CORRELATION_FILTER") gCorrelationFilter = (StringToInteger(val) != 0);
      else if (key == "ATR_MIN_PIPS") gAtrMinPips = StringToDouble(val);
      else Print("Unknown config key: ", key);
   }
   FileClose(h);
}

//+------------------------------------------------------------------+
int OnInit() {
    int hLock = FileOpen("v9-bot.lock", FILE_TXT|FILE_WRITE|FILE_ANSI);
    if (hLock == INVALID_HANDLE) {
       Print("=== OnInit FAILED — another instance is already running ===");
       Comment("v9-mt5-bot: ANOTHER INSTANCE RUNNING\nClose other charts with this EA");
       return INIT_FAILED;
    }
    FileWrite(hLock, TimeToString(TimeCurrent()));
    FileClose(hLock);

    Print("=== OnInit START ===");
    ReadConfig();
   trade.SetExpertMagicNumber((int)gMagic);
   string parts[];
   int n = StringSplit(gSymbols, ',', parts);
   symCount = n;
   ArrayResize(syms, n);
   ArrayResize(ts, n);
   ArrayResize(symSt, n);
   for (int i = 0; i < n; i++) {
      syms[i] = parts[i];
      ts[i].symbol = parts[i];
      ts[i].head = 0; ts[i].count = 0; ts[i].curSec = 0;
      ts[i].ticking = false; ts[i].lastSignalTime = 0;
      symSt[i].tickHead = 0; symSt[i].tickCount = 0;
      symSt[i].spreadHead = 0; symSt[i].spreadCount = 0;
      symSt[i].lastSpread = 0; symSt[i].lastTickTime = 0;
      symSt[i].ticksPerSecond = 0; symSt[i].lastVelocity = 0;
      symSt[i].lastImpulseTime = 0; symSt[i].impulseDir = 0;
   }
    Print("BEFORE_TIMER timerMs=", timerMs);
    bool timerOk = EventSetMillisecondTimer(timerMs);
    Print("AFTER_TIMER ok=", timerOk, " timerMs=", timerMs);
    if (!timerOk) {
       Print("TIMER_FAILED — falling back to EventSetTimer(1)");
       EventSetTimer(1);
    }
    Print("v9-mt5-bot v3.00 SCALPING ready — ", n, " symbols, magic=", gMagic, " timer=", timerMs, "ms");
   Print("Mode: ", (gScalpMode ? "SCALP" : "NORMAL"), " | Risk: ", gRiskPct, "% | SL: ", gMinSL, "-", gMaxSL, " pips");
   Print("Hybrid: TICK_IMB=", DoubleToString(gWTickImb,2), " SPREAD_COMP=", DoubleToString(gWSpreadComp,2),
         " QUOTE_VEL=", DoubleToString(gWQuoteVel,2), " MICRO_PULL=", DoubleToString(gWMicroPull,2),
         " CROSS_SYNC=", DoubleToString(gWCrossSync,2), " ENTROPY=", DoubleToString(gWEntropy,2));
    Comment("v9-mt5-bot v3.00 SCALP\n", n, " symbols | risk: ", gRiskPct, "% | SL: ", gMinSL, "-", gMaxSL, "p");
    Print("=== OnInit END ===");
    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
void OnDeinit(const int r) {
    FileDelete("v9-bot.lock");
    Comment("");
    EventKillTimer();
    Print("v9-mt5-bot v3.00 stopped (reason=", r, ")");
    if (closedCount > 0)
       Print("Session summary: ", closedCount, " closed trades, total net profit: ", calcTotalNetProfit());
}

//+------------------------------------------------------------------+
void OnTrade() {
   detectClosedPositions();
}

//+------------------------------------------------------------------+
//| Tick data ingestion                                              |
//+------------------------------------------------------------------+
void feedTickData(int s) {
   MqlTick tick;
   if (!SymbolInfoTick(syms[s], tick)) return;

   int idx = symSt[s].tickHead % MAX_TICK_BUF;
   symSt[s].ticks[idx].bid = tick.bid;
   symSt[s].ticks[idx].ask = tick.ask;
   symSt[s].ticks[idx].time = tick.time;
   symSt[s].ticks[idx].volume = tick.volume;
   symSt[s].tickHead++;
   if (symSt[s].tickCount < MAX_TICK_BUF) symSt[s].tickCount++;

   double spread = (tick.ask - tick.bid) / SymbolInfoDouble(syms[s], SYMBOL_POINT);
   if (spread > 0 && spread < 100) {
      int sidx = symSt[s].spreadHead % 20;
      symSt[s].spreadHistory[sidx] = spread;
      symSt[s].spreadHead++;
      if (symSt[s].spreadCount < 20) symSt[s].spreadCount++;
      symSt[s].lastSpread = spread;
   }

   datetime now = TimeCurrent();
   if (symSt[s].lastTickTime > 0) {
      int delta = (int)(now - symSt[s].lastTickTime);
      if (delta > 0) symSt[s].lastVelocity = 1.0 / delta;
   }
   symSt[s].lastTickTime = now;

   if (symSt[s].tickCount >= 3) {
      int t1 = (symSt[s].tickHead - 3 + MAX_TICK_BUF) % MAX_TICK_BUF;
      int t2 = (symSt[s].tickHead - 2 + MAX_TICK_BUF) % MAX_TICK_BUF;
      int t3 = (symSt[s].tickHead - 1 + MAX_TICK_BUF) % MAX_TICK_BUF;
      bool up1 = symSt[s].ticks[t1].bid < symSt[s].ticks[t2].bid;
      bool up2 = symSt[s].ticks[t2].bid < symSt[s].ticks[t3].bid;
      bool down1 = symSt[s].ticks[t1].bid > symSt[s].ticks[t2].bid;
      bool down2 = symSt[s].ticks[t2].bid > symSt[s].ticks[t3].bid;
      if (up1 && up2) { symSt[s].impulseDir = 1; symSt[s].lastImpulseTime = now; }
      else if (down1 && down2) { symSt[s].impulseDir = -1; symSt[s].lastImpulseTime = now; }
   }
}

//+------------------------------------------------------------------+
//| Tick-based detectors                                             |
//+------------------------------------------------------------------+
double calcTickImbalance(int s) {
   if (symSt[s].tickCount < 20) return 0;
   int up = 0, down = 0;
   for (int i = 0; i < 20; i++) {
      if (i >= symSt[s].tickCount) break;
      int idx = (symSt[s].tickHead - 1 - i + MAX_TICK_BUF) % MAX_TICK_BUF;
      if (i == 0) continue;
      int prev = (symSt[s].tickHead - 1 - (i-1) + MAX_TICK_BUF) % MAX_TICK_BUF;
      if (symSt[s].ticks[idx].bid > symSt[s].ticks[prev].bid) up++;
      else if (symSt[s].ticks[idx].bid < symSt[s].ticks[prev].bid) down++;
   }
    int total = up + down;
    if (total < 10) return 0;
    double ratio = (double)MathMax(up, down) / total;
    if (ratio >= 0.55) return ratio;
    return 0;
}

double calcSpreadCompression(int s) {
   if (symSt[s].spreadCount < 5) return 0;
   double cur = symSt[s].spreadHistory[(symSt[s].spreadHead - 1 + 20) % 20];
   double old = symSt[s].spreadHistory[(symSt[s].spreadHead - 4 + 20) % 20];
   if (old <= 0) return 0;
   double compression = (old - cur) / old;
    if (compression >= 0.20 && cur < 3.0) return compression;
   return 0;
}

double calcQuoteVelocity(int s) {
   if (symSt[s].tickCount < 30) return 0;
   if (symSt[s].lastVelocity > 0 && symSt[s].lastVelocity > 2.0) return 1.0;
   return 0;
}

double calcMicroPullback(int s) {
   if (symSt[s].impulseDir == 0) return 0;
   datetime now = TimeCurrent();
   if (now - symSt[s].lastImpulseTime > 5) return 0;
   if (symSt[s].tickCount < 3) return 0;
   int last = (symSt[s].tickHead - 1 + MAX_TICK_BUF) % MAX_TICK_BUF;
   int prev = (symSt[s].tickHead - 2 + MAX_TICK_BUF) % MAX_TICK_BUF;
   bool reverse = (symSt[s].impulseDir == 1 && symSt[s].ticks[last].bid < symSt[s].ticks[prev].bid) ||
                  (symSt[s].impulseDir == -1 && symSt[s].ticks[last].bid > symSt[s].ticks[prev].bid);
   if (reverse) return 0.8;
   return 0;
}

double calcCrossSync(int s) {
    string sym = syms[s];
    int agrees = 0;
    int total = 0;
    for (int g = 0; g < 5; g++) {
       bool found = false;
       for (int m = 0; m < 3; m++) {
          if (corrGroups[g][m] == sym) { found = true; break; }
       }
       if (!found) continue;
       for (int m = 0; m < 3; m++) {
          if (corrGroups[g][m] == sym) continue;
          int otherIdx = -1;
          for (int k = 0; k < symCount; k++) {
             if (syms[k] == corrGroups[g][m]) { otherIdx = k; break; }
          }
          if (otherIdx < 0) continue;
          total++;
          if (symSt[s].impulseDir != 0 && symSt[otherIdx].impulseDir != 0 &&
              symSt[s].impulseDir == symSt[otherIdx].impulseDir) {
             agrees++;
          }
       }
    }
    if (total >= 2 && agrees >= 2) return 1.0;
    return 0;
}

double calcTickEntropy(int s) {
   if (symSt[s].tickCount < 20) return 0;
   int up = 0, down = 0, flat = 0;
   for (int i = 0; i < 20; i++) {
      if (i >= symSt[s].tickCount) break;
      int idx = (symSt[s].tickHead - 1 - i + MAX_TICK_BUF) % MAX_TICK_BUF;
      if (i == 0) continue;
      int prev = (symSt[s].tickHead - 1 - (i-1) + MAX_TICK_BUF) % MAX_TICK_BUF;
      if (symSt[s].ticks[idx].bid > symSt[s].ticks[prev].bid) up++;
      else if (symSt[s].ticks[idx].bid < symSt[s].ticks[prev].bid) down++;
      else flat++;
   }
   int total = up + down + flat;
   if (total < 15) return 0;
   double pUp = (double)up / total;
   double pDown = (double)down / total;
   double pFlat = (double)flat / total;
   double entropy = 0;
   if (pUp > 0) entropy -= pUp * MathLog(pUp) / MathLog(2);
   if (pDown > 0) entropy -= pDown * MathLog(pDown) / MathLog(2);
   if (pFlat > 0) entropy -= pFlat * MathLog(pFlat) / MathLog(2);
   if (entropy < 0.5) return 1.0 - entropy * 2.0;
   return 0;
}

//+------------------------------------------------------------------+
//| Session and risk filters                                         |
//+------------------------------------------------------------------+
bool isKillZoneActive() {
   if (!gScalpMode) return true;
   datetime now = TimeCurrent();
   MqlDateTime dt;
   TimeToStruct(now, dt);
   int gmtMinutes = dt.hour * 60 + dt.min;
   if (gKillLondon && gmtMinutes >= gKillLondonStart && gmtMinutes <= gKillLondonEnd) return true;
   if (gKillNY && gmtMinutes >= gKillNYStart && gmtMinutes <= gKillNYEnd) return true;
   if (gKillAsian) {
      if (gKillAsianStart > gKillAsianEnd) {
         if (gmtMinutes >= gKillAsianStart || gmtMinutes <= gKillAsianEnd) return true;
      } else {
         if (gmtMinutes >= gKillAsianStart && gmtMinutes <= gKillAsianEnd) return true;
      }
   }
   return false;
}

bool isDailyLossLimitHit() {
   if (!gScalpMode) return false;
   double limit = acc.Balance() * gDailyLossPct / 100.0;
   return (dailyNetProfit < -limit);
}

bool hasCorrelatedOpen(string sym) {
    if (!gCorrelationFilter || !gScalpMode) return false;
    for (int g = 0; g < 5; g++) {
       bool symInGroup = false;
       int otherCount = 0;
       for (int m = 0; m < 3; m++) {
          if (corrGroups[g][m] == sym) symInGroup = true;
          else {
             for (int k = 0; k < symCount; k++) {
                if (syms[k] == corrGroups[g][m] && hasPos(syms[k])) otherCount++;
             }
          }
       }
       if (symInGroup && otherCount > 0) return true;
    }
    return false;
}

//+------------------------------------------------------------------+
//| Hybrid signal scoring                                            |
//+------------------------------------------------------------------+
struct HybridSignal {
   string name;
   double score;
   int    side;
};

bool getHybridSignal(int s, HybridSignal &out) {
   if (!gScalpMode) return false;
   double imb = calcTickImbalance(s);
   double spreadComp = calcSpreadCompression(s);
   double vel = calcQuoteVelocity(s);
   double pull = calcMicroPullback(s);
   double sync = calcCrossSync(s);
   double entropy = calcTickEntropy(s);

   int agreeing = 0;
   int side = 0;

   if (imb > 0) {
      agreeing++;
      int lastIdx = (symSt[s].tickHead - 1 + MAX_TICK_BUF) % MAX_TICK_BUF;
      int prevIdx = (symSt[s].tickHead - 2 + MAX_TICK_BUF) % MAX_TICK_BUF;
      side = (symSt[s].ticks[lastIdx].bid > symSt[s].ticks[prevIdx].bid) ? 1 : -1;
   }
   if (spreadComp > 0) {
      agreeing++;
      int scSide = (symSt[s].ticks[(symSt[s].tickHead - 1 + MAX_TICK_BUF) % MAX_TICK_BUF].bid >
                    symSt[s].ticks[(symSt[s].tickHead - 4 + MAX_TICK_BUF) % MAX_TICK_BUF].bid) ? 1 : -1;
      if (side == 0) side = scSide; else if (side != scSide) agreeing--;
   }
   if (vel > 0) {
      agreeing++;
      int vSide = (symSt[s].ticks[(symSt[s].tickHead - 1 + MAX_TICK_BUF) % MAX_TICK_BUF].bid >
                   symSt[s].ticks[(symSt[s].tickHead - 2 + MAX_TICK_BUF) % MAX_TICK_BUF].bid) ? 1 : -1;
      if (side == 0) side = vSide; else if (side != vSide) agreeing--;
   }
   if (pull > 0) {
      agreeing++;
      int pSide = (symSt[s].impulseDir == 1) ? 1 : -1;
      if (side == 0) side = pSide; else if (side != pSide) agreeing--;
   }
   if (sync > 0) {
      agreeing++;
      if (side == 0) side = (symSt[s].impulseDir != 0) ? symSt[s].impulseDir : 1;
   }
   if (entropy > 0) {
      agreeing++;
      int eSide = (symSt[s].impulseDir != 0) ? symSt[s].impulseDir : 1;
      if (side == 0) side = eSide; else if (side != eSide) agreeing--;
   }

    if (agreeing < gMinAgreeing || side == 0) {
       int mtfSide = 0;
       double mtfScore = calcMtfSignal(s, mtfSide);
       if (mtfScore > 0 && mtfSide != 0) {
          out.name = "MTF_SCALP";
          out.score = mtfScore;
          out.side = mtfSide;
          return true;
       }
       return false;
    }

    double composite = gWTickImb * imb + gWSpreadComp * spreadComp + gWQuoteVel * vel + gWMicroPull * pull + gWCrossSync * sync + gWEntropy * entropy;
    if (composite < gMinScore) return false;

    out.name = "HYBRID_SCALP";
    out.score = composite;
    out.side = side;
    return true;
}

//+------------------------------------------------------------------+
//| Position snapshot for detecting server-side closes               |
//+------------------------------------------------------------------+
void snapshotOpenPositions() {
   int count = 0;
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (pos.SelectByIndex(i) && pos.Magic() == (int)gMagic) count++;
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
       bool alreadyProcessed = false;
       for (int p = 0; p < processedCount; p++) {
          if (processedDealTickets[p] == ticket) { alreadyProcessed = true; break; }
       }
       if (alreadyProcessed) continue;
       if (processedCount >= ArraySize(processedDealTickets)) ArrayResize(processedDealTickets, processedCount + 100);
       processedDealTickets[processedCount] = ticket;
       processedCount++;
       string sym = HistoryDealGetString(dealTicket, DEAL_SYMBOL);
       ENUM_DEAL_TYPE dealType = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);
       string typeStr = (dealType == DEAL_TYPE_BUY) ? "BUY" : "SELL";
       double profit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
       double comm = HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
       double swap = HistoryDealGetDouble(dealTicket, DEAL_SWAP);
       double net = profit + comm + swap;
       datetime closeTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);
       double closePrice = HistoryDealGetDouble(dealTicket, DEAL_PRICE);
       if (closedCount >= ArraySize(closedTrades)) ArrayResize(closedTrades, closedCount + 100);
       closedTrades[closedCount].openTime = closeTime - 60;
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
       dailyNetProfit += net;
       Print("CLOSED: ", sym, " | ", typeStr, " | Profit: ", DoubleToString(profit, 2),
             " | Comm: ", DoubleToString(comm, 2), " | Swap: ", DoubleToString(swap, 2),
             " | NET: ", DoubleToString(net, 2), " | Reason: ", closedTrades[closedCount-1].closeReason,
             " | Ticket: ", ticket, " | Daily PnL: ", DoubleToString(dailyNetProfit, 2));
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
      if (gTimeStop > 0 && (TimeCurrent() - pos.Time()) >= gTimeStop) return "TIME_STOP";
   }
   return "MANUAL_OR_OTHER";
}

double calcTotalNetProfit() {
   double total = 0;
   for (int i = 0; i < closedCount; i++) total += closedTrades[i].netProfit;
   return total;
}

//+------------------------------------------------------------------+
//| Timer: main loop every 50ms                                      |
//+------------------------------------------------------------------+
void OnTimer() {
   Print("TIMER tickCount=", tickCount, " symCount=", symCount);
   tickCount++;

    // 1. feed ticks for all symbols
    for (int s = 0; s < symCount; s++)
       feedTickData(s);

   // 2. finalize completed seconds (legacy 1s klines)
   finalizeSecs();

   // 3. manage open positions (trail, breakeven, time stop)
   managePositions();

   // 4. scan for signals (every 200ms)
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
      ts[s].curSec   = secStart;
      ts[s].curOpen  = (tick.bid != 0 ? tick.bid : tick.ask);
      ts[s].curHigh  = ts[s].curOpen;
      ts[s].curLow   = ts[s].curOpen;
      ts[s].curClose = ts[s].curOpen;
      ts[s].curVol   = 1;
      ts[s].ticking  = true;
   } else {
      double price = (tick.bid != 0 ? tick.bid : tick.ask);
      ts[s].curHigh  = MathMax(ts[s].curHigh, price);
      ts[s].curLow   = MathMin(ts[s].curLow, price);
      ts[s].curClose = price;
      ts[s].curVol++;
   }
}

void finalizeSecs() {
   int nowSec = (int)TimeCurrent();
   for (int s = 0; s < symCount; s++) {
      while (ts[s].ticking && ts[s].curSec < nowSec) {
         int idx = ts[s].head % MAX_SEC_BARS;
         ts[s].bars[idx].time   = (datetime)ts[s].curSec;
         ts[s].bars[idx].open   = ts[s].curOpen;
         ts[s].bars[idx].high   = ts[s].curHigh;
         ts[s].bars[idx].low    = ts[s].curLow;
         ts[s].bars[idx].close  = ts[s].curClose;
         ts[s].bars[idx].volume = ts[s].curVol;
         ts[s].head = (ts[s].head + 1) % MAX_SEC_BARS;
         if (ts[s].count < MAX_SEC_BARS) ts[s].count++;
         ts[s].curSec++;
         ts[s].curOpen  = ts[s].curClose;
         ts[s].curHigh  = ts[s].curClose;
         ts[s].curLow   = ts[s].curClose;
         ts[s].curVol   = 0;
         ts[s].ticking  = false;
      }
   }
}

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

bool getMtfRates(string sym, ENUM_TIMEFRAMES tf1, ENUM_TIMEFRAMES tf2, ENUM_TIMEFRAMES tf3,
                 MqlRates &r1[], MqlRates &r2[], MqlRates &r3[], int &got1, int &got2, int &got3) {
   got1 = CopyRates(sym, tf1, 1, 100, r1);
   got2 = CopyRates(sym, tf2, 1, 100, r2);
   got3 = CopyRates(sym, tf3, 1, 100, r3);
   return (got1 >= 20 && got2 >= 20 && got3 >= 20);
}

//+------------------------------------------------------------------+
//| Manage open positions                                            |
//+------------------------------------------------------------------+
void managePositions() {
   for (int i = PositionsTotal() - 1; i >= 0; i--) {
      if (!pos.SelectByIndex(i)) continue;
      if (pos.Magic() != (int)gMagic) continue;
      if (gTimeStop > 0) {
         datetime age = TimeCurrent() - pos.Time();
         if (age >= gTimeStop) {
            Print(pos.Symbol(), " | TIME STOP — age=", age, "s, closing ticket=", pos.Ticket());
            trade.PositionClose(pos.Ticket());
            continue;
         }
      }
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
      if (gTrail) doTrail(i);
   }
}

//+------------------------------------------------------------------+
//| Scan all symbols for trade signals                                |
//+------------------------------------------------------------------+
void scanSymbols() {
    if (!isKillZoneActive()) return;
    if (isDailyLossLimitHit()) {
       if (tickCount % gLogEvery == 0) Print("=== DAILY LOSS LIMIT HIT — pausing trading ===");
       return;
    }

    int openCount = 0;
    for (int i = PositionsTotal() - 1; i >= 0; i--) {
       if (pos.SelectByIndex(i) && pos.Magic() == (int)gMagic) openCount++;
    }

    int placed = 0, skippedPos = 0, skippedCool = 0, skippedSpread = 0, skippedCorr = 0, noSig = 0;

    for (int s = 0; s < symCount; s++) {
       if (openCount + placed >= gMaxOpen) break;
       if (hasPos(syms[s])) { skippedPos++; continue; }
       if (TimeCurrent() - ts[s].lastSignalTime < gCooldown) { skippedCool++; continue; }
       if (hasCorrelatedOpen(syms[s])) { skippedCorr++; continue; }

       MqlRates r1[], r5[], r15[];
       int got1, got5, got15;
       if (!getMtfRates(syms[s], PERIOD_M1, PERIOD_M5, PERIOD_M15, r1, r5, r15, got1, got5, got15)) {
          noSig++; continue;
       }

       double sp = (double)SymbolInfoInteger(syms[s], SYMBOL_SPREAD);
       double maxSpreadPoints = gMaxSpread * 10.0;
       if (sp > maxSpreadPoints) { skippedSpread++; continue; }

       double atr = calcAtr(r1, got1, 14);
       double minAtr = gAtrMinPips * 10 * SymbolInfoDouble(syms[s], SYMBOL_POINT);
       if (atr < minAtr) { noSig++; continue; }

       HybridSignal sig;
       if (getHybridSignal(s, sig)) {
          if (tickCount % gLogEvery == 0)
             Print(">>> ", syms[s], " | SCALP: ", sig.name, " side=", (sig.side == 1 ? "LONG" : "SHORT"),
                   " score=", DoubleToString(sig.score, 2), " imb=", DoubleToString(calcTickImbalance(s), 2),
                   " spreadComp=", DoubleToString(calcSpreadCompression(s), 2));
          if (execScalpTrade(syms[s], sig)) {
             ts[s].lastSignalTime = TimeCurrent();
             placed++;
          }
       } else {
          noSig++;
          if (tickCount % gLogEvery == 0) {
             double imb2 = calcTickImbalance(s);
             double sc2 = calcSpreadCompression(s);
             double vl2 = calcQuoteVelocity(s);
             double pl2 = calcMicroPullback(s);
             double sy2 = calcCrossSync(s);
             double en2 = calcTickEntropy(s);
             int agree = 0;
             if (imb2 > 0) agree++;
             if (sc2 > 0) agree++;
             if (vl2 > 0) agree++;
             if (pl2 > 0) agree++;
             if (sy2 > 0) agree++;
             if (en2 > 0) agree++;
             Print("NO_SIG: ", syms[s], " agree=", agree, " tickCount=", symSt[s].tickCount,
                   " imb=", DoubleToString(imb2,2), " spreadComp=", DoubleToString(sc2,2),
                   " vel=", DoubleToString(vl2,2), " pull=", DoubleToString(pl2,2),
                   " sync=", DoubleToString(sy2,2), " entropy=", DoubleToString(en2,2));
          }
       }
    }

    if (tickCount % gLogEvery == 0)
       Print("=== SCAN | open=", openCount, " placed=", placed,
             " hasPos=", skippedPos, " cooldown=", skippedCool,
             " spread=", skippedSpread, " corr=", skippedCorr, " noSig=", noSig);
}

//+------------------------------------------------------------------+
//| Scalp trade execution                                            |
//+------------------------------------------------------------------+
bool execScalpTrade(string sym, HybridSignal &sig) {
   double ask = SymbolInfoDouble(sym, SYMBOL_ASK);
   double bid = SymbolInfoDouble(sym, SYMBOL_BID);
   double price = (sig.side == 1) ? ask : bid;
   double pt   = SymbolInfoDouble(sym, SYMBOL_POINT);
   double minSL = gMinSL * 10 * pt;
   double maxSL = gMaxSL * 10 * pt;

   double slDist = MathMax(minSL, maxSL);
   double lots = calcLotByRisk(sym, price, slDist, sig.side);
   if (lots < SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN)) return false;

   double sl = (sig.side == 1) ? price - slDist : price + slDist;
   double tp = (sig.side == 1) ? price + slDist * 1.5 : price - slDist * 1.5;

   ENUM_ORDER_TYPE type = (sig.side == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   string typeStr = (sig.side == 1) ? "BUY" : "SELL";

   trade.PositionOpen(sym, type, lots, price, sl, tp, "v9-" + sig.name);
   bool ok = trade.ResultRetcode() == TRADE_RETCODE_DONE;

   if (ok) {
      double fillPrice = trade.ResultPrice();
      double slippage = MathAbs(fillPrice - price);
      Print(sym, " | SCALP ", typeStr, " ", sig.name, " score=", DoubleToString(sig.score, 2),
            " lots=", lots, " req=", price, " fill=", fillPrice, " slip=", DoubleToString(slippage, 5),
            " sl=", sl, " tp=", tp, " ticket=", trade.ResultOrder());
      if (gTrackExecution) {
         if (execCount >= ArraySize(execHistory)) ArrayResize(execHistory, execCount + 100);
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
      lastTradeTime = TimeCurrent();
   } else {
      Print(sym, " | FAILED SCALP ", typeStr, " retcode=", trade.ResultRetcode(),
            " comment=", trade.ResultComment());
   }
   return ok;
}

//+------------------------------------------------------------------+
//| Calculate lot size                                               |
//+------------------------------------------------------------------+
double calcLotByRisk(string sym, double entry, double slDist, int side) {
   double maxRisk = acc.Balance() * (gRiskPct / 100.0);
   double minV = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   double step = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double slPrice = (side == 1) ? entry - slDist : entry + slDist;
   int type = (side == 1) ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   double profit1 = 0;
   if (!OrderCalcProfit((ENUM_ORDER_TYPE)type, sym, 1.0, entry, slPrice, profit1)) return minV;
   if (profit1 >= 0) return minV;
   double raw = maxRisk / MathAbs(profit1);
   double lots = MathFloor(raw / step) * step;
   lots = MathMax(minV, MathMin(lots, maxV));
   return lots;
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

double calcMtfSignal(int s, int &side) {
    MqlRates r1[], r5[], r15[];
    int got1, got5, got15;
    if (!getMtfRates(syms[s], PERIOD_M1, PERIOD_M5, PERIOD_M15, r1, r5, r15, got1, got5, got15)) return 0;
    if (got1 < 20 || got5 < 20 || got15 < 20) return 0;

    double macd1, sig1, macd5, sig5, macd15, sig15;
    calcMacd(r1, got1, 12, 26, 9, macd1, sig1);
    calcMacd(r5, got5, 12, 26, 9, macd5, sig5);
    calcMacd(r15, got15, 12, 26, 9, macd15, sig15);

    double k1, d1, k5, d5, k15, d15;
    calcStoch(r1, got1, 14, 3, k1, d1);
    calcStoch(r5, got5, 14, 3, k5, d5);
    calcStoch(r15, got15, 14, 3, k15, d15);

    double adx1 = calcAdx(r1, got1, 14);
    double adx5 = calcAdx(r5, got5, 14);
    double adx15 = calcAdx(r15, got15, 14);

    int bull = 0;
    if (macd1 > sig1) bull++;
    if (macd5 > sig5) bull++;
    if (macd15 > sig15) bull++;
    if (k1 > d1 && k1 < 80) bull++;
    if (k5 > d5 && k5 < 80) bull++;
    if (k15 > d15 && k15 < 80) bull++;
    if (adx1 > 20) bull++;
    if (adx5 > 20) bull++;

    int bear = 0;
    if (macd1 < sig1) bear++;
    if (macd5 < sig5) bear++;
    if (macd15 < sig15) bear++;
    if (k1 < d1 && k1 > 20) bear++;
    if (k5 < d5 && k5 > 20) bear++;
    if (k15 < d15 && k15 > 20) bear++;
    if (adx1 > 20) bear++;
    if (adx5 > 20) bear++;

    if (bull >= 5 && bull > bear) { side = 1; return 0.65; }
    if (bear >= 5 && bear > bull) { side = -1; return 0.65; }
    return 0;
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
         if (proposed > sl && proposed > open) slNew = proposed;
      }
   } else if (pos.PositionType() == POSITION_TYPE_SELL) {
      double trailFrom = open - trailPts * 1.5;
      if (curr < trailFrom) {
         double proposed = curr + trailPts;
         if ((sl == 0 || proposed < sl) && proposed < open) slNew = proposed;
      }
   }
   if (slNew != sl)
      trade.PositionModify(pos.Ticket(), slNew, pos.TakeProfit());
}

//+------------------------------------------------------------------+
//| Chart comment                                                    |
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
      for (int i = 0; i < execCount; i++) totalSlip += execHistory[i].slippage;
      avgSlippage = totalSlip / execCount;
   }
   string txt = StringFormat(
      "v9-mt5-bot v3.00 SCALP | Open: %d/%d | PnL: %.2f | Bal: %.2f\nNet Closed: %.2f | Avg Slip: %.5f\nDaily: %.2f | KillZone: %s | Risk: %.2f%%",
      open, gMaxOpen, totalPnL, acc.Balance(), calcTotalNetProfit(), avgSlippage,
      dailyNetProfit, (isKillZoneActive() ? "ON" : "OFF"), gRiskPct);
   Comment(txt);
}
//+------------------------------------------------------------------+
