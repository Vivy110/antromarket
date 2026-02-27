//+------------------------------------------------------------------+
//|                                          AntroMarket_Gold_EA.mq5 |
//|                                              AntroMarket EA v1.1 |
//|                                                                  |
//|  Strategy: Multi-Confirmation Scalping for XAUUSD M1             |
//|  Indicators:                                                     |
//|    1. EMA 9/21/50 - Trend Direction Filter                       |
//|    2. RSI(14)     - Momentum & Overbought/Oversold               |
//|    3. Bollinger Bands(20,2) - Volatility & Breakout              |
//|    4. ATR(14)     - Dynamic SL/TP                                |
//|    5. MACD(12,26,9) - Trend Confirmation                         |
//|  Risk Management:                                                |
//|    - ATR-based Stop Loss                                         |
//|    - Risk:Reward minimum 1:1.5                                   |
//|    - Trailing Stop                                               |
//|    - Max 1 position per direction                                |
//|    - Session filter (London & New York only)                     |
//|  v1.1 Fixes:                                                     |
//|    - Relaxed signal scoring (min 3 of 5)                         |
//|    - Fixed lot size calculation                                  |
//|    - Auto-detect order filling type                              |
//|    - Added debug logging for signal scores                       |
//|    - Relaxed RSI signal conditions                               |
//|    - Added MACD histogram trend as alternative confirmation      |
//+------------------------------------------------------------------+

#property copyright   "AntroMarket EA v1.1"
#property version     "1.10"
#property strict

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Input Parameters
input group "=== STRATEGI ==="
input int      EMA_Fast        = 9;          // EMA Cepat
input int      EMA_Mid         = 21;         // EMA Tengah
input int      EMA_Slow        = 50;         // EMA Lambat
input int      RSI_Period      = 14;         // Period RSI
input double   RSI_Overbought  = 70.0;       // RSI Overbought
input double   RSI_Oversold    = 30.0;       // RSI Oversold
input int      BB_Period       = 20;         // Period Bollinger Band
input double   BB_Dev          = 2.0;        // Deviasi Bollinger Band
input int      MACD_Fast       = 12;         // MACD Fast EMA
input int      MACD_Slow       = 26;         // MACD Slow EMA
input int      MACD_Signal     = 9;          // MACD Signal
input int      ATR_Period      = 14;         // Period ATR
input int      MinConfirmations = 3;         // Minimum konfirmasi sinyal (1-5)

input group "=== RISK MANAGEMENT ==="
input double   RiskPercent     = 1.0;        // Risk per trade (% dari balance)
input double   ATR_SL_Multi    = 1.5;        // Multiplier ATR untuk Stop Loss
input double   ATR_TP_Multi    = 2.5;        // Multiplier ATR untuk Take Profit
input bool     UseTrailingStop = true;       // Gunakan Trailing Stop
input double   TrailATR_Multi  = 1.0;        // Multiplier ATR untuk Trailing
input double   BreakEvenATR    = 1.0;        // Pindah ke BE setelah X * ATR profit
input int      MaxOpenTrades   = 2;          // Max posisi terbuka bersamaan
input double   MaxSpread       = 50.0;       // Max spread yang diizinkan (points)
input double   FixedLots       = 0.01;       // Lot tetap jika kalkulasi gagal

input group "=== SESSION FILTER ==="
input bool     UseLondonSession   = true;    // Trading sesi London
input bool     UseNewYorkSession  = true;    // Trading sesi New York
input bool     UseAsiaSession     = false;   // Trading sesi Asia (tambahan)
input int      LondonOpen         = 7;       // Jam buka London (UTC)
input int      LondonClose        = 16;      // Jam tutup London (UTC)
input int      NYOpen             = 12;      // Jam buka New York (UTC)
input int      NYClose            = 21;      // Jam tutup New York (UTC)
input int      AsiaOpen           = 0;       // Jam buka Asia (UTC)
input int      AsiaClose          = 7;       // Jam tutup Asia (UTC)

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

int    handleEMA_Fast, handleEMA_Mid, handleEMA_Slow;
int    handleRSI, handleBB, handleMACD, handleATR;

double emaFastBuf[], emaMidBuf[], emaSlowBuf[];
double rsiBuf[];
double bbUpperBuf[], bbMidBuf[], bbLowerBuf[];
double macdMainBuf[], macdSignalBuf[];
double atrBuf[];

datetime lastBarTime = 0;
int      totalWins   = 0;
int      totalLoss   = 0;
double   totalProfit = 0;

//+------------------------------------------------------------------+
//| Expert initialization function                                   |
//+------------------------------------------------------------------+
int OnInit()
{
    // Validasi symbol
    if(Symbol() != "XAUUSD" && StringFind(Symbol(), "GOLD") < 0 &&
       StringFind(Symbol(), "XAU") < 0)
    {
        Print("WARNING: EA ini dioptimalkan untuk XAUUSD/GOLD. Symbol saat ini: ", Symbol());
    }

    // Inisialisasi handles indikator
    handleEMA_Fast = iMA(_Symbol, PERIOD_M1, EMA_Fast, 0, MODE_EMA, PRICE_CLOSE);
    handleEMA_Mid  = iMA(_Symbol, PERIOD_M1, EMA_Mid,  0, MODE_EMA, PRICE_CLOSE);
    handleEMA_Slow = iMA(_Symbol, PERIOD_M1, EMA_Slow, 0, MODE_EMA, PRICE_CLOSE);
    handleRSI      = iRSI(_Symbol, PERIOD_M1, RSI_Period, PRICE_CLOSE);
    handleBB       = iBands(_Symbol, PERIOD_M1, BB_Period, 0, BB_Dev, PRICE_CLOSE);
    handleMACD     = iMACD(_Symbol, PERIOD_M1, MACD_Fast, MACD_Slow, MACD_Signal, PRICE_CLOSE);
    handleATR      = iATR(_Symbol, PERIOD_M1, ATR_Period);

    if(handleEMA_Fast == INVALID_HANDLE || handleEMA_Mid == INVALID_HANDLE ||
       handleEMA_Slow == INVALID_HANDLE || handleRSI == INVALID_HANDLE ||
       handleBB == INVALID_HANDLE || handleMACD == INVALID_HANDLE ||
       handleATR == INVALID_HANDLE)
    {
        Print("ERROR: Gagal membuat handle indikator!");
        return INIT_FAILED;
    }

    // Set array sebagai series
    ArraySetAsSeries(emaFastBuf, true);
    ArraySetAsSeries(emaMidBuf,  true);
    ArraySetAsSeries(emaSlowBuf, true);
    ArraySetAsSeries(rsiBuf,     true);
    ArraySetAsSeries(bbUpperBuf, true);
    ArraySetAsSeries(bbMidBuf,   true);
    ArraySetAsSeries(bbLowerBuf, true);
    ArraySetAsSeries(macdMainBuf,   true);
    ArraySetAsSeries(macdSignalBuf, true);
    ArraySetAsSeries(atrBuf,     true);

    // Setup trade object
    Trade.SetExpertMagicNumber(MagicNumber);
    Trade.SetDeviationInPoints(50);

    // Auto-detect order filling type
    ENUM_ORDER_TYPE_FILLING fillingType = GetFillingType();
    Trade.SetTypeFilling(fillingType);
    Print("Order filling type: ", EnumToString(fillingType));

    Print("AntroMarket Gold EA v1.1 - Initialized successfully");
    Print("Symbol: ", _Symbol, " | Timeframe: M1");
    Print("Strategy: EMA Trend + RSI + Bollinger Bands + MACD + ATR");
    Print("Min Confirmations: ", MinConfirmations, " | Max Spread: ", MaxSpread);

    return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| Auto-detect order filling type                                   |
//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingType()
{
    uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

    if((filling & SYMBOL_FILLING_FOK) != 0)
        return ORDER_FILLING_FOK;
    if((filling & SYMBOL_FILLING_IOC) != 0)
        return ORDER_FILLING_IOC;

    return ORDER_FILLING_RETURN;
}

//+------------------------------------------------------------------+
//| Expert deinitialization function                                 |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
    IndicatorRelease(handleEMA_Fast);
    IndicatorRelease(handleEMA_Mid);
    IndicatorRelease(handleEMA_Slow);
    IndicatorRelease(handleRSI);
    IndicatorRelease(handleBB);
    IndicatorRelease(handleMACD);
    IndicatorRelease(handleATR);

    Comment("");
    Print("EA Dihentikan. Total Win: ", totalWins, " | Loss: ", totalLoss,
          " | Net P/L: ", DoubleToString(totalProfit, 2));
}

//+------------------------------------------------------------------+
//| Expert tick function                                             |
//+------------------------------------------------------------------+
void OnTick()
{
    // Cek hanya pada bar baru
    datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
    if(currentBar == lastBarTime)
    {
        // Manage trailing stop setiap tick
        if(UseTrailingStop) ManageTrailingStop();
        if(ShowDashboard)   UpdateDashboard();
        return;
    }
    lastBarTime = currentBar;

    // Ambil data indikator
    if(!RefreshIndicatorData()) 
    {
        if(EnableDebugLog) Print("DEBUG: RefreshIndicatorData gagal");
        return;
    }

    // Cek kondisi trading
    if(!IsSessionActive())
    {
        if(EnableDebugLog)
        {
            MqlDateTime dt;
            TimeToStruct(TimeGMT(), dt);
            Print("DEBUG: Sesi tidak aktif. Jam UTC: ", dt.hour, ":", dt.min);
        }
        return;
    }

    if(!CheckSpread())
    {
        if(EnableDebugLog)
        {
            double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
            Print("DEBUG: Spread terlalu besar: ", spread, " > ", MaxSpread);
        }
        return;
    }

    int openTrades = CountOpenTrades();
    if(openTrades >= MaxOpenTrades)
    {
        if(EnableDebugLog) Print("DEBUG: Max open trades tercapai: ", openTrades);
        return;
    }

    // Generate sinyal
    int signal = GetTradingSignal();

    if(signal == 1)  OpenBuy();
    if(signal == -1) OpenSell();
}

//+------------------------------------------------------------------+
//| Refresh semua data indikator                                     |
//+------------------------------------------------------------------+
bool RefreshIndicatorData()
{
    int bars = 5;

    if(CopyBuffer(handleEMA_Fast, 0, 0, bars, emaFastBuf) < bars) return false;
    if(CopyBuffer(handleEMA_Mid,  0, 0, bars, emaMidBuf)  < bars) return false;
    if(CopyBuffer(handleEMA_Slow, 0, 0, bars, emaSlowBuf) < bars) return false;
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
//| Logic utama untuk sinyal trading                                 |
//+------------------------------------------------------------------+
int GetTradingSignal()
{
    // --- Nilai indikator candle terakhir (index 1 = closed candle) ---
    double emaFast = emaFastBuf[1];
    double emaMid  = emaMidBuf[1];
    double emaSlow = emaSlowBuf[1];
    double rsi     = rsiBuf[1];
    double rsiPrev = rsiBuf[2];
    double bbUpper = bbUpperBuf[1];
    double bbLower = bbLowerBuf[1];
    double bbMid   = bbMidBuf[1];
    double macdMain    = macdMainBuf[1];
    double macdSig     = macdSignalBuf[1];
    double macdMainPrev= macdMainBuf[2];
    double macdSigPrev = macdSignalBuf[2];
    double atr     = atrBuf[1];

    double closePrice = iClose(_Symbol, PERIOD_M1, 1);
    double openPrice  = iOpen(_Symbol, PERIOD_M1, 1);
    bool   isBullishCandle = (closePrice > openPrice);
    bool   isBearishCandle = (closePrice < openPrice);

    // === KONDISI BUY ===
    // 1. Trend bullish: EMA9 > EMA21 (minimal 2 EMA aligned)
    bool emaBullish = (emaFast > emaMid);
    // 2. RSI tidak overbought dan dalam zona bullish (lebih longgar)
    bool rsiBuySignal = (rsi > 40.0) && (rsi < RSI_Overbought - 5.0);
    // 3. Harga di bawah BB upper (ada ruang naik)
    bool bbBuySignal = (closePrice < bbUpper) && (closePrice > bbLower);
    // 4. MACD bullish: main di atas signal ATAU crossover bullish
    bool macdBullish = (macdMain > macdSig) ||
                       ((macdMainPrev < macdSigPrev) && (macdMain > macdSig));
    // 5. Candle bullish
    bool candleBuy = isBullishCandle;

    // Hitung skor konfirmasi BUY
    int buyScore = (emaBullish ? 1 : 0) + (rsiBuySignal ? 1 : 0) +
                   (bbBuySignal ? 1 : 0) + (macdBullish ? 1 : 0) +
                   (candleBuy ? 1 : 0);

    // === KONDISI SELL ===
    // 1. Trend bearish: EMA9 < EMA21
    bool emaBearish = (emaFast < emaMid);
    // 2. RSI tidak oversold dan dalam zona bearish (lebih longgar)
    bool rsiSellSignal = (rsi < 60.0) && (rsi > RSI_Oversold + 5.0);
    // 3. Harga di atas BB lower (ada ruang turun)
    bool bbSellSignal = (closePrice > bbLower) && (closePrice < bbUpper);
    // 4. MACD bearish: main di bawah signal ATAU crossover bearish
    bool macdBearish = (macdMain < macdSig) ||
                       ((macdMainPrev > macdSigPrev) && (macdMain < macdSig));
    // 5. Candle bearish
    bool candleSell = isBearishCandle;

    // Hitung skor konfirmasi SELL
    int sellScore = (emaBearish ? 1 : 0) + (rsiSellSignal ? 1 : 0) +
                    (bbSellSignal ? 1 : 0) + (macdBearish ? 1 : 0) +
                    (candleSell ? 1 : 0);

    // Filter: tidak entry jika RSI di zona ekstrem berlawanan arah
    bool buyFilter  = (rsi < RSI_Overbought);   // tidak beli saat RSI overbought
    bool sellFilter = (rsi > RSI_Oversold);      // tidak jual saat RSI oversold

    // Tidak ada posisi berlawanan arah yang sudah terbuka
    bool noBuyPos  = !HasOpenPosition(ORDER_TYPE_BUY);
    bool noSellPos = !HasOpenPosition(ORDER_TYPE_SELL);

    if(EnableDebugLog)
    {
        Print("DEBUG SIGNAL | BuyScore: ", buyScore,
              " [EMA:", emaBullish, " RSI:", rsiBuySignal,
              " BB:", bbBuySignal, " MACD:", macdBullish, " Candle:", candleBuy, "]",
              " | SellScore: ", sellScore,
              " [EMA:", emaBearish, " RSI:", rsiSellSignal,
              " BB:", bbSellSignal, " MACD:", macdBearish, " Candle:", candleSell, "]",
              " | RSI=", DoubleToString(rsi, 1),
              " | EMAFast=", DoubleToString(emaFast, 2),
              " | EMAMid=", DoubleToString(emaMid, 2),
              " | Close=", DoubleToString(closePrice, 2));
    }

    if(buyScore >= MinConfirmations && buyFilter && noBuyPos)   return 1;
    if(sellScore >= MinConfirmations && sellFilter && noSellPos) return -1;

    return 0;
}

//+------------------------------------------------------------------+
//| Buka posisi BUY                                                  |
//+------------------------------------------------------------------+
void OpenBuy()
{
    double atr    = atrBuf[1];
    double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
    double sl     = ask - (atr * ATR_SL_Multi);
    double tp     = ask + (atr * ATR_TP_Multi);
    double lots   = CalculateLotSize(atr * ATR_SL_Multi);

    if(lots <= 0)
    {
        Print("WARNING: Kalkulasi lot gagal, menggunakan FixedLots: ", FixedLots);
        lots = FixedLots;
    }

    // Normalisasi harga
    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    // Validasi SL minimum
    double minSLDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(ask - sl < minSLDist)
        sl = NormalizeDouble(ask - minSLDist - _Point, digits);

    Print("BUY attempt | Ask: ", ask, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);

    if(Trade.Buy(lots, _Symbol, ask, sl, tp, TradeComment))
    {
        if(EnableAlerts)
            Alert("AntroMarket BUY: ", _Symbol, " | Lots: ", lots,
                  " | SL: ", sl, " | TP: ", tp);
        Print("BUY opened | Price: ", ask, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);
    }
    else
    {
        Print("ERROR BUY: ", Trade.ResultRetcode(), " - ", Trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Buka posisi SELL                                                 |
//+------------------------------------------------------------------+
void OpenSell()
{
    double atr    = atrBuf[1];
    double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
    double sl     = bid + (atr * ATR_SL_Multi);
    double tp     = bid - (atr * ATR_TP_Multi);
    double lots   = CalculateLotSize(atr * ATR_SL_Multi);

    if(lots <= 0)
    {
        Print("WARNING: Kalkulasi lot gagal, menggunakan FixedLots: ", FixedLots);
        lots = FixedLots;
    }

    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
    sl = NormalizeDouble(sl, digits);
    tp = NormalizeDouble(tp, digits);

    // Validasi SL minimum
    double minSLDist = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(sl - bid < minSLDist)
        sl = NormalizeDouble(bid + minSLDist + _Point, digits);

    Print("SELL attempt | Bid: ", bid, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);

    if(Trade.Sell(lots, _Symbol, bid, sl, tp, TradeComment))
    {
        if(EnableAlerts)
            Alert("AntroMarket SELL: ", _Symbol, " | Lots: ", lots,
                  " | SL: ", sl, " | TP: ", tp);
        Print("SELL opened | Price: ", bid, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);
    }
    else
    {
        Print("ERROR SELL: ", Trade.ResultRetcode(), " - ", Trade.ResultRetcodeDescription());
    }
}

//+------------------------------------------------------------------+
//| Kalkulasi lot berdasarkan % risk                                 |
//+------------------------------------------------------------------+
double CalculateLotSize(double slDistance)
{
    if(slDistance <= 0) return 0;

    double balance    = AccountInfoDouble(ACCOUNT_BALANCE);
    double riskAmount = balance * (RiskPercent / 100.0);

    // Nilai per lot per point
    double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(tickSize <= 0 || tickValue <= 0) return 0;

    // Nilai SL dalam tick
    double slInTicks  = slDistance / tickSize;
    // Nilai uang per lot untuk SL ini
    double slValuePerLot = slInTicks * tickValue;

    if(slValuePerLot <= 0) return 0;

    double lots = riskAmount / slValuePerLot;

    // Normalisasi lot
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    if(stepLot <= 0) stepLot = 0.01;

    lots = MathFloor(lots / stepLot) * stepLot;
    lots = MathMax(minLot, MathMin(maxLot, lots));

    if(EnableDebugLog)
        Print("DEBUG LOT | Balance: ", balance, " | Risk: ", riskAmount,
              " | SL dist: ", slDistance, " | SL ticks: ", slInTicks,
              " | SL val/lot: ", slValuePerLot, " | Lots: ", lots);

    return lots;
}

//+------------------------------------------------------------------+
//| Trailing Stop Management                                         |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    if(CopyBuffer(handleATR, 0, 0, 3, atrBuf) < 3) return;
    double atr = atrBuf[1];
    double trailDist = atr * TrailATR_Multi;
    double beDist    = atr * BreakEvenATR;

    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(!PositionSelectByTicket(PositionGetTicket(i))) continue;
        if(PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;
        if(PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

        double openPrice  = PositionGetDouble(POSITION_PRICE_OPEN);
        double currentSL  = PositionGetDouble(POSITION_SL);
        double currentTP  = PositionGetDouble(POSITION_TP);
        int    posType    = (int)PositionGetInteger(POSITION_TYPE);
        int    digits     = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

        if(posType == POSITION_TYPE_BUY)
        {
            double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double profit = bid - openPrice;

            // Break Even
            if(profit >= beDist && currentSL < openPrice)
            {
                double newSL = NormalizeDouble(openPrice + _Point, digits);
                if(newSL > currentSL)
                    Trade.PositionModify(PositionGetTicket(i), newSL, currentTP);
            }
            // Trailing Stop
            else if(profit > trailDist)
            {
                double newSL = NormalizeDouble(bid - trailDist, digits);
                if(newSL > currentSL)
                    Trade.PositionModify(PositionGetTicket(i), newSL, currentTP);
            }
        }
        else if(posType == POSITION_TYPE_SELL)
        {
            double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profit = openPrice - ask;

            // Break Even
            if(profit >= beDist && currentSL > openPrice)
            {
                double newSL = NormalizeDouble(openPrice - _Point, digits);
                if(newSL < currentSL)
                    Trade.PositionModify(PositionGetTicket(i), newSL, currentTP);
            }
            // Trailing Stop
            else if(profit > trailDist)
            {
                double newSL = NormalizeDouble(ask + trailDist, digits);
                if(newSL < currentSL)
                    Trade.PositionModify(PositionGetTicket(i), newSL, currentTP);
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Cek apakah sesi aktif                                            |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
    MqlDateTime dt;
    TimeToStruct(TimeGMT(), dt);
    int hour = dt.hour;

    bool london = UseLondonSession  && (hour >= LondonOpen && hour < LondonClose);
    bool ny     = UseNewYorkSession && (hour >= NYOpen     && hour < NYClose);
    bool asia   = UseAsiaSession    && (hour >= AsiaOpen   && hour < AsiaClose);

    return (london || ny || asia);
}

//+------------------------------------------------------------------+
//| Cek spread                                                       |
//+------------------------------------------------------------------+
bool CheckSpread()
{
    double spread = (double)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return (spread <= MaxSpread);
}

//+------------------------------------------------------------------+
//| Hitung jumlah trade terbuka milik EA                             |
//+------------------------------------------------------------------+
int CountOpenTrades()
{
    int count = 0;
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol)
                count++;
        }
    }
    return count;
}

//+------------------------------------------------------------------+
//| Cek apakah ada posisi terbuka berdasarkan tipe                   |
//+------------------------------------------------------------------+
bool HasOpenPosition(ENUM_ORDER_TYPE type)
{
    for(int i = PositionsTotal() - 1; i >= 0; i--)
    {
        if(PositionSelectByTicket(PositionGetTicket(i)))
        {
            if(PositionGetInteger(POSITION_MAGIC) == MagicNumber &&
               PositionGetString(POSITION_SYMBOL) == _Symbol &&
               PositionGetInteger(POSITION_TYPE)  == type)
                return true;
        }
    }
    return false;
}

//+------------------------------------------------------------------+
//| Tracking hasil trade                                             |
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
            if(HistoryDealGetInteger(dealTicket, DEAL_MAGIC) == MagicNumber &&
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
//| Update dashboard di chart                                        |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
    int    spread   = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double atr      = (ArraySize(atrBuf) > 1) ? atrBuf[1] : 0;
    double rsi      = (ArraySize(rsiBuf) > 1) ? rsiBuf[1] : 0;
    int    trades   = CountOpenTrades();
    int    total    = totalWins + totalLoss;
    double winRate  = (total > 0) ? (double)totalWins / total * 100 : 0;

    MqlDateTime dt;
    TimeToStruct(TimeGMT(), dt);
    bool sessionActive = IsSessionActive();

    string dash = "";
    dash += "╔═══════════════════════════════╗\n";
    dash += "║   ANTROMARKET GOLD EA v1.1    ║\n";
    dash += "╠═══════════════════════════════╣\n";
    dash += StringFormat("║  Symbol   : %-18s ║\n", _Symbol);
    dash += StringFormat("║  Spread   : %-18s ║\n", IntegerToString(spread) + " pts");
    dash += StringFormat("║  ATR      : %-18s ║\n", DoubleToString(atr, 2));
    dash += StringFormat("║  RSI      : %-18s ║\n", DoubleToString(rsi, 1));
    dash += StringFormat("║  Session  : %-18s ║\n", sessionActive ? "ACTIVE" : "CLOSED");
    dash += StringFormat("║  Trades   : %-18s ║\n", IntegerToString(trades));
    dash += "╠═══════════════════════════════╣\n";
    dash += StringFormat("║  Win      : %-18s ║\n", IntegerToString(totalWins));
    dash += StringFormat("║  Loss     : %-18s ║\n", IntegerToString(totalLoss));
    dash += StringFormat("║  Win Rate : %-18s ║\n", DoubleToString(winRate, 1) + "%");
    dash += StringFormat("║  Net P/L  : %-18s ║\n", DoubleToString(totalProfit, 2));
    dash += "╚═══════════════════════════════╝";

    Comment(dash);
}

//+------------------------------------------------------------------+
