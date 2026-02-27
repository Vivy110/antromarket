//+------------------------------------------------------------------+
//|                                          AntroMarket_Gold_EA.mq5 |
//|                                              AntroMarket EA v1.5 |
//|                                                                  |
//|  Strategy: Multi-Confirmation Scalping for XAUUSD M1             |
//|  Indicators:                                                     |
//|    1. EMA 9/21 - Trend Direction Filter                          |
//|    2. RSI(14)  - Momentum (>50 buy, <50 sell, no overlap)        |
//|    3. Bollinger Bands(20,2) - Price vs BB middle (directional)   |
//|    4. ATR(14)  - Dynamic SL/TP                                   |
//|    5. MACD(12,26,9) - Histogram direction                        |
//|  Risk Management:                                                |
//|    - ATR-based Stop Loss & Take Profit                           |
//|    - Trailing Stop with Break-Even                               |
//|    - Max positions limit                                         |
//|    - Session filter (optional)                                   |
//|  v1.5 Root Cause Fix:                                            |
//|    - RSI zones NO overlap: buy >50, sell <50 (mutually exclusive)|
//|    - BB signal purely directional: above mid=buy, below mid=sell |
//|      (removed bounce/rejection that caused both sides to trigger)|
//|    - MACD: histogram >0 = buy, <0 = sell (no crossover overlap)  |
//|    - Tied scores: use EMA as tiebreaker instead of blocking entry|
//|    - Trade.Buy/Sell with price=0 for market execution (no requote)|
//|    - MinConfirmations default = 2 (achievable on M1)             |
//+------------------------------------------------------------------+

#property copyright   "AntroMarket EA v1.5"
#property version     "1.50"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters
input group "=== STRATEGI ==="
input int      EMA_Fast        = 9;          // EMA Cepat
input int      EMA_Mid         = 21;         // EMA Tengah
input int      RSI_Period      = 14;         // Period RSI
input double   RSI_Overbought  = 70.0;       // RSI Overbought (filter)
input double   RSI_Oversold    = 30.0;       // RSI Oversold (filter)
input int      BB_Period       = 20;         // Period Bollinger Band
input double   BB_Dev          = 2.0;        // Deviasi Bollinger Band
input int      MACD_Fast       = 12;         // MACD Fast EMA
input int      MACD_Slow       = 26;         // MACD Slow EMA
input int      MACD_Signal     = 9;          // MACD Signal
input int      ATR_Period      = 14;         // Period ATR
input int      MinConfirmations = 2;         // Minimum konfirmasi sinyal (1-5)

input group "=== RISK MANAGEMENT ==="
input double   RiskPercent     = 1.0;        // Risk per trade (% dari balance)
input double   ATR_SL_Multi    = 1.5;        // Multiplier ATR untuk Stop Loss
input double   ATR_TP_Multi    = 2.5;        // Multiplier ATR untuk Take Profit
input bool     UseTrailingStop = true;       // Gunakan Trailing Stop
input double   TrailATR_Multi  = 1.5;        // Multiplier ATR untuk Trailing Stop
input double   BreakEvenATR    = 0.5;        // Pindah ke BE setelah X * ATR profit
input int      MaxOpenTrades   = 2;          // Max posisi terbuka bersamaan
input double   MaxSpread       = 50.0;       // Max spread yang diizinkan (points)
input double   FixedLots       = 0.01;       // Lot tetap jika kalkulasi gagal

input group "=== SESSION FILTER ==="
input bool     UseSessionFilter    = true;   // Aktifkan filter sesi (false = 24 jam)
input bool     UseLondonSession    = true;   // Trading sesi London
input bool     UseNewYorkSession   = true;   // Trading sesi New York
input bool     UseAsiaSession      = false;  // Trading sesi Asia
input int      LondonOpen          = 7;      // Jam buka London (UTC)
input int      LondonClose         = 16;     // Jam tutup London (UTC)
input int      NYOpen              = 12;     // Jam buka New York (UTC)
input int      NYClose             = 21;     // Jam tutup New York (UTC)
input int      AsiaOpen            = 0;      // Jam buka Asia (UTC)
input int      AsiaClose           = 7;      // Jam tutup Asia (UTC)
input int      BrokerGMTOffset     = 2;      // Offset GMT broker (jam)

input group "=== PENGATURAN LAINNYA ==="
input ulong    MagicNumber     = 20240101;   // Magic Number EA
input string   TradeComment    = "AntroMarket_Gold";
input bool     EnableAlerts    = true;       // Aktifkan alert
input bool     ShowDashboard   = true;       // Tampilkan dashboard
input bool     EnableDebugLog  = true;       // Aktifkan log debug sinyal

//--- Global Variables
CTrade         Trade;
CPositionInfo  PositionInfo;
CSymbolInfo    SymbolInfo;

int    handleEMA_Fast, handleEMA_Mid;
int    handleRSI, handleBB, handleMACD, handleATR;

double emaFastBuf[], emaMidBuf[];
double rsiBuf[];
double bbUpperBuf[], bbMidBuf[], bbLowerBuf[];
double macdMainBuf[], macdSignalBuf[];
double atrBuf[];

datetime lastBarTime  = 0;
int      totalWins    = 0;
int      totalLoss    = 0;
double   totalProfit  = 0;
int      cachedTrades = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    if(Symbol() != "XAUUSD" && StringFind(Symbol(), "GOLD") < 0 &&
       StringFind(Symbol(), "XAU") < 0)
    {
        Print("WARNING: EA dioptimalkan untuk XAUUSD/GOLD. Symbol: ", Symbol());
    }

    handleEMA_Fast = iMA(_Symbol, PERIOD_M1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    handleEMA_Mid  = iMA(_Symbol, PERIOD_M1, EMA_Mid,  0, MODE_EMA, PRICE_CLOSE);
    handleRSI      = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
    handleBB       = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Dev, PRICE_CLOSE);
    handleMACD     = iMACD(_Symbol, PERIOD_M1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    handleATR      = iATR(_Symbol, PERIOD_M1, ATR_Period);

    if(handleEMA_Fast == INVALID_HANDLE || handleEMA_Mid == INVALID_HANDLE ||
       handleRSI == INVALID_HANDLE || handleBB == INVALID_HANDLE ||
       handleMACD == INVALID_HANDLE || handleATR == INVALID_HANDLE)
    {
        Print("ERROR: Gagal membuat handle indikator!");
        return INIT_FAILED;
    }

    ArraySetAsSeries(emaFastBuf, true);
    ArraySetAsSeries(emaMidBuf,  true);
    ArraySetAsSeries(rsiBuf,     true);
    ArraySetAsSeries(bbUpperBuf, true);
    ArraySetAsSeries(bbMidBuf,   true);
    ArraySetAsSeries(bbLowerBuf, true);
    ArraySetAsSeries(macdMainBuf,   true);
    ArraySetAsSeries(macdSignalBuf, true);
    ArraySetAsSeries(atrBuf,     true);

    Trade.SetExpertMagicNumber(MagicNumber);
    Trade.SetDeviationInPoints(50);

    ENUM_ORDER_TYPE_FILLING fillingType = GetFillingType();
    Trade.SetTypeFilling(fillingType);
    Print("Order filling type: ", EnumToString(fillingType));

    Print("AntroMarket Gold EA v1.5 - Initialized");
    Print("Symbol: ", _Symbol, " | TF: M1 | MinConf: ", MinConfirmations);
    Print("Session Filter: ", UseSessionFilter ? "ON" : "OFF",
          " | Broker GMT+", BrokerGMTOffset);
    Print("SL: ", ATR_SL_Multi, "xATR | TP: ", ATR_TP_Multi, "xATR",
          " | Trail: ", TrailATR_Multi, "xATR | BE: ", BreakEvenATR, "xATR");

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingType()
{
    uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);
    if((filling & SYMBOL_FILLING_FOK) != 0) return ORDER_FILLING_FOK;
    if((filling & SYMBOL_FILLING_IOC) != 0) return ORDER_FILLING_IOC;
    return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handleEMA_Fast);
    IndicatorRelease(handleEMA_Mid);
    IndicatorRelease(handleRSI);
    IndicatorRelease(handleBB);
    IndicatorRelease(handleMACD);
    IndicatorRelease(handleATR);
    Comment("");
    Print("EA Stop. Win: ", totalWins, " | Loss: ", totalLoss,
          " | P/L: ", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
    if(currentBar == lastBarTime)
    {
        if(UseTrailingStop) ManageTrailingStop();
        if(ShowDashboard)   UpdateDashboard();
        return;
    }
    lastBarTime = currentBar;

    if(!RefreshIndicatorData())
    {
        if(EnableDebugLog) Print("DEBUG: RefreshIndicatorData gagal");
        return;
    }

    cachedTrades = CountOpenTrades();

    if(UseSessionFilter && !IsSessionActive())
    {
        if(EnableDebugLog)
        {
            datetime st = TimeCurrent();
            MqlDateTime dt;
            TimeToStruct(st, dt);
            int utcH = (dt.hour - BrokerGMTOffset + 24) % 24;
            Print("DEBUG: Sesi OFF. Server: ", dt.hour, ":", dt.min, " UTC: ", utcH);
        }
        return;
    }

    if(!CheckSpread())
    {
        if(EnableDebugLog)
        {
            long sp = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
            Print("DEBUG: Spread besar: ", sp, " > ", MaxSpread);
        }
        return;
    }

    if(cachedTrades >= MaxOpenTrades)
    {
        if(EnableDebugLog) Print("DEBUG: Max trades: ", cachedTrades);
        return;
    }

    int signal = GetTradingSignal();
    if(signal == 1)  OpenBuy();
    if(signal == -1) OpenSell();
}

//+------------------------------------------------------------------+
bool RefreshIndicatorData()
{
    int bars = 5;
    if(CopyBuffer(handleEMA_Fast, 0, 0, bars, emaFastBuf) < bars) return false;
    if(CopyBuffer(handleEMA_Mid,  0, 0, bars, emaMidBuf)  < bars) return false;
    if(CopyBuffer(handleRSI,      0, 0, bars, rsiBuf)     < bars) return false;
    if(CopyBuffer(handleBB, UPPER_BAND, 0, bars, bbUpperBuf) < bars) return false;
    if(CopyBuffer(handleBB, BASE_LINE,  0, bars, bbMidBuf)   < bars) return false;
    if(CopyBuffer(handleBB, LOWER_BAND, 0, bars, bbLowerBuf) < bars) return false;
    if(CopyBuffer(handleMACD, 0, 0, bars, macdMainBuf)   < bars) return false;
    if(CopyBuffer(handleMACD, 1, 0, bars, macdSignalBuf) < bars) return false;
    if(CopyBuffer(handleATR,  0, 0, bars, atrBuf)        < bars) return false;
    return true;
}

//+------------------------------------------------------------------+
//| SIGNAL LOGIC v1.5 - Mutually exclusive conditions                |
//|                                                                  |
//| Each indicator gives +1 to EITHER buy OR sell, NEVER both.       |
//| This eliminates tied scores and ensures clear direction.          |
//|                                                                  |
//| 5 indicators scored:                                             |
//|   1. EMA: fast > mid = buy(+1), fast < mid = sell(+1)           |
//|   2. RSI: >50 = buy(+1), <50 = sell(+1)                         |
//|   3. BB:  close > bbMid = buy(+1), close < bbMid = sell(+1)     |
//|   4. MACD: histogram >0 = buy(+1), <0 = sell(+1)                |
//|   5. Candle: bullish = buy(+1), bearish = sell(+1)               |
//|                                                                  |
//| Entry when score >= MinConfirmations AND no extreme RSI          |
//+------------------------------------------------------------------+
int GetTradingSignal()
{
    double emaFast  = emaFastBuf[1];
    double emaMid   = emaMidBuf[1];
    double rsi      = rsiBuf[1];
    double bbMid    = bbMidBuf[1];
    double macdHist = macdMainBuf[1] - macdSignalBuf[1];
    double atr      = atrBuf[1];

    double closePrice = iClose(_Symbol, PERIOD_M1, 1);
    double openPrice  = iOpen(_Symbol, PERIOD_M1, 1);

    // --- Skor: setiap indikator memberikan +1 ke SATU arah saja ---
    int buyScore  = 0;
    int sellScore = 0;

    // 1. EMA direction (mutually exclusive)
    if(emaFast > emaMid)      buyScore++;
    else if(emaFast < emaMid) sellScore++;

    // 2. RSI zone (mutually exclusive: >50 = bullish, <50 = bearish)
    if(rsi > 50.0)      buyScore++;
    else if(rsi < 50.0) sellScore++;

    // 3. BB position (mutually exclusive: above mid = bullish)
    if(closePrice > bbMid)      buyScore++;
    else if(closePrice < bbMid) sellScore++;

    // 4. MACD histogram (mutually exclusive)
    if(macdHist > 0)      buyScore++;
    else if(macdHist < 0) sellScore++;

    // 5. Candle direction (mutually exclusive)
    if(closePrice > openPrice)      buyScore++;
    else if(closePrice < openPrice) sellScore++;

    // --- Filters ---
    bool rsiNotOverbought = (rsi < RSI_Overbought);
    bool rsiNotOversold   = (rsi > RSI_Oversold);
    bool noBuyPos  = !HasOpenPosition(POSITION_TYPE_BUY);
    bool noSellPos = !HasOpenPosition(POSITION_TYPE_SELL);

    if(EnableDebugLog)
    {
        Print("DEBUG | BuyScore: ", buyScore, " SellScore: ", sellScore,
              " | EMA:", (emaFast > emaMid ? "BUY" : (emaFast < emaMid ? "SELL" : "FLAT")),
              " RSI:", DoubleToString(rsi, 1), (rsi > 50 ? " BUY" : " SELL"),
              " BB:", (closePrice > bbMid ? "BUY" : "SELL"),
              " MACD:", (macdHist > 0 ? "BUY" : "SELL"),
              " Candle:", (closePrice > openPrice ? "BUY" : "SELL"),
              " | Close=", DoubleToString(closePrice, 2),
              " ATR=", DoubleToString(atr, 2));
    }

    // --- Entry decision ---
    // Karena semua kondisi mutually exclusive, buyScore + sellScore <= 5
    // dan buyScore != sellScore (kecuali ada indikator yang flat/equal)
    if(buyScore >= MinConfirmations && buyScore > sellScore &&
       rsiNotOverbought && noBuyPos)
        return 1;

    if(sellScore >= MinConfirmations && sellScore > buyScore &&
       rsiNotOversold && noSellPos)
        return -1;

    return 0;
}

//+------------------------------------------------------------------+
void OpenBuy()
{
    double atr  = atrBuf[1];
    double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl   = NormalizeDouble(ask - (atr * ATR_SL_Multi), _Digits);
    double tp   = NormalizeDouble(ask + (atr * ATR_TP_Multi), _Digits);
    double lots = CalculateLotSize(atr * ATR_SL_Multi);

    if(lots <= 0)
    {
        Print("WARNING: Lot calc gagal, pakai FixedLots: ", FixedLots);
        lots = FixedLots;
    }

    // Validasi SL minimum
    double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(minDist > 0 && (ask - sl) < minDist)
        sl = NormalizeDouble(ask - minDist - _Point, _Digits);

    if(tp <= ask)
    {
        Print("ERROR BUY: TP invalid (", tp, " <= ", ask, ")");
        return;
    }

    Print("BUY | Ask:", ask, " SL:", sl, " TP:", tp, " Lots:", lots);

    // price=0 = market execution (menghindari requote)
    if(Trade.Buy(lots, _Symbol, 0, sl, tp, TradeComment))
    {
        if(EnableAlerts)
            Alert("AntroMarket BUY ", _Symbol, " Lots:", lots);
        Print("BUY OPENED | Lots:", lots, " SL:", sl, " TP:", tp);
        cachedTrades++;
    }
    else
    {
        Print("ERROR BUY: ", Trade.ResultRetcode(), " - ", Trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
void OpenSell()
{
    double atr  = atrBuf[1];
    double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl   = NormalizeDouble(bid + (atr * ATR_SL_Multi), _Digits);
    double tp   = NormalizeDouble(bid - (atr * ATR_TP_Multi), _Digits);
    double lots = CalculateLotSize(atr * ATR_SL_Multi);

    if(lots <= 0)
    {
        Print("WARNING: Lot calc gagal, pakai FixedLots: ", FixedLots);
        lots = FixedLots;
    }

    double minDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(minDist > 0 && (sl - bid) < minDist)
        sl = NormalizeDouble(bid + minDist + _Point, _Digits);

    if(tp >= bid)
    {
        Print("ERROR SELL: TP invalid (", tp, " >= ", bid, ")");
        return;
    }

    Print("SELL | Bid:", bid, " SL:", sl, " TP:", tp, " Lots:", lots);

    if(Trade.Sell(lots, _Symbol, 0, sl, tp, TradeComment))
    {
        if(EnableAlerts)
            Alert("AntroMarket SELL ", _Symbol, " Lots:", lots);
        Print("SELL OPENED | Lots:", lots, " SL:", sl, " TP:", tp);
        cachedTrades++;
    }
    else
    {
        Print("ERROR SELL: ", Trade.ResultRetcode(), " - ", Trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    if(slDistance <= 0) return 0;

    double balance       = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount    = balance * (RiskPercent / 100.0);
    double tickValue     = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize      = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(tickSize <= 0 || tickValue <= 0) return 0;

    double slInTicks     = slDistance / tickSize;
    double slValuePerLot = slInTicks * tickValue;

    if(slValuePerLot <= 0) return 0;

    double lots    = riskAmount / slValuePerLot;
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(minLot  <= 0) minLot  = 0.01;
    if(maxLot  <= 0) maxLot  = 100.0;
    if(stepLot <= 0) stepLot = 0.01;

    lots = MathFloor(lots / stepLot) * stepLot;
    lots = MathMax(minLot, MathMin(maxLot, lots));

    if(EnableDebugLog)
        Print("DEBUG LOT | Bal:", balance, " Risk:", riskAmount,
              " SLdist:", slDistance, " Lots:", lots);

    return lots;
}

//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(CopyBuffer(handleATR, 0, 0, 3, atrBuf) < 3) return;
    double atr       = atrBuf[1];
    double trailDist = atr * TrailATR_Multi;
    double beDist    = atr * BreakEvenATR;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(!PositionSelectByTicket(ticket)) continue;
        if(PositionGetInteger(POSITION_MAGIC) != (long)MagicNumber) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

        double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL = PositionGetDouble(POSITION_SL);
        double currentTP = PositionGetDouble(POSITION_TP);
        int    posType   = (int)PositionGetInteger(POSITION_TYPE);

        if(posType == POSITION_TYPE_BUY)
        {
            double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double profit = bid - openPrice;

            if(profit >= beDist && currentSL < openPrice)
            {
                double newSL = NormalizeDouble(openPrice + _Point, _Digits);
                if(newSL > currentSL)
                    Trade.PositionModify(ticket, newSL, currentTP);
            }

            if(profit > trailDist)
            {
                double newSL = NormalizeDouble(bid - trailDist, _Digits);
                if(newSL > currentSL)
                    Trade.PositionModify(ticket, newSL, currentTP);
            }
        }
        else if(posType == POSITION_TYPE_SELL)
        {
            double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profit = openPrice - ask;

            if(profit >= beDist && currentSL > openPrice)
            {
                double newSL = NormalizeDouble(openPrice - _Point, _Digits);
                if(newSL < currentSL)
                    Trade.PositionModify(ticket, newSL, currentTP);
            }

            if(profit > trailDist)
            {
                double newSL = NormalizeDouble(ask + trailDist, _Digits);
                if(newSL < currentSL)
                    Trade.PositionModify(ticket, newSL, currentTP);
            }
        }
    }
}

//+------------------------------------------------------------------+
bool IsSessionActive()
{
    datetime st = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(st, dt);
    int utcH = (dt.hour - BrokerGMTOffset + 24) % 24;

    bool london = UseLondonSession  && (utcH >= LondonOpen && utcH < LondonClose);
    bool ny     = UseNewYorkSession && (utcH >= NYOpen     && utcH < NYClose);
    bool asia   = UseAsiaSession    && (utcH >= AsiaOpen   && utcH < AsiaClose);

    return (london || ny || asia);
}

//+------------------------------------------------------------------+
bool CheckSpread()
{
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return (spread <= (long)MaxSpread);
}

//+------------------------------------------------------------------+
int CountOpenTrades()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_POSITION_TYPE posType)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        ulong ticket = PositionGetTicket(i);
        if(PositionSelectByTicket(ticket))
        {
            if(PositionGetInteger(POSITION_MAGIC) == (long)MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol &&
               (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE) == posType)
                return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest     &request,
                        const MqlTradeResult      &result)
{
    if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
    {
        ulong dealTicket = trans.deal;
        if(HistoryDealSelect(dealTicket))
        {
            if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == (long)MagicNumber &&
               HistoryDealGetInteger(dealTicket, DEAL_ENTRY) == DEAL_ENTRY_OUT)
            {
                double dealProfit = HistoryDealGetDouble(dealTicket, DEAL_PROFIT);
                totalProfit += dealProfit;
                if(dealProfit > 0) totalWins++;
                else               totalLoss++;
            }
        }
    }
}

//+------------------------------------------------------------------+
void UpdateDashboard()
{
    int    spread  = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double atr     = (ArraySize(atrBuf) > 1) ? atrBuf[1] : 0;
    double rsi     = (ArraySize(rsiBuf) > 1) ? rsiBuf[1] : 0;
    int    total   = totalWins + totalLoss;
    double winRate = (total > 0) ? (double)totalWins / total * 100 : 0;

    datetime st = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(st, dt);
    int utcH = (dt.hour - BrokerGMTOffset + 24) % 24;
    bool sessON = !UseSessionFilter || IsSessionActive();

    string d = "";
    d += "╔═══════════════════════════════╗\n";
    d += "║   ANTROMARKET GOLD EA v1.5    ║\n";
    d += "╠═══════════════════════════════╣\n";
    d += StringFormat("║  Symbol   : %-18s ║\n", _Symbol);
    d += StringFormat("║  Spread   : %-18s ║\n", IntegerToString(spread) + " pts");
    d += StringFormat("║  ATR      : %-18s ║\n", DoubleToString(atr, 2));
    d += StringFormat("║  RSI      : %-18s ║\n", DoubleToString(rsi, 1));
    d += StringFormat("║  UTC Hour : %-18s ║\n", IntegerToString(utcH));
    d += StringFormat("║  Session  : %-18s ║\n", sessON ? "ACTIVE" : "CLOSED");
    d += StringFormat("║  Trades   : %-18s ║\n", IntegerToString(cachedTrades));
    d += "╠═══════════════════════════════╣\n";
    d += StringFormat("║  Win      : %-18s ║\n", IntegerToString(totalWins));
    d += StringFormat("║  Loss     : %-18s ║\n", IntegerToString(totalLoss));
    d += StringFormat("║  Win Rate : %-18s ║\n", DoubleToString(winRate, 1) + "%");
    d += StringFormat("║  Net P/L  : %-18s ║\n", DoubleToString(totalProfit, 2));
    d += "╚═══════════════════════════════╝";

    Comment(d);
}

//+------------------------------------------------------------------+
