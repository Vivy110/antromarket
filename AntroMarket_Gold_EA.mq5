//+------------------------------------------------------------------+
//|                                          AntroMarket_Gold_EA.mq5 |
//|                                              AntroMarket EA v1.3 |
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
//|    - Trailing Stop with Break-Even                               |
//|    - Max 1 position per direction                                |
//|    - Session filter (London & New York only)                     |
//|  v1.3 Fixes (comprehensive):                                     |
//|    - Removed unused variable emaMidPrev                          |
//|    - Fixed BB bounce/rejection: use buffer data (bbLowerBuf[2])  |
//|      instead of iClose() for consistency and performance         |
//|    - Fixed RSI flat condition: strictly > for buy, < for sell    |
//|    - Fixed HasOpenPosition: use ENUM_POSITION_TYPE instead of    |
//|      ENUM_ORDER_TYPE (correct enum for positions)                |
//|    - Fixed TP validation: ensure TP > 0 before placing order     |
//|    - Fixed trailing stop: continues after break-even is set      |
//|    - Fixed BreakEvenATR default: 0.5 (triggers before trail)     |
//|    - Fixed lot size: ensure minLot > 0 fallback                  |
//|    - Reduced dashboard overhead: cache open trade count          |
//|    - BB bounce condition relaxed: prev close near lower band     |
//|      (within 0.3 * ATR) instead of requiring close below band    |
//+------------------------------------------------------------------+

#property copyright   "AntroMarket EA v1.3"
#property version     "1.30"
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
input int      MinScoreGap     = 1;          // Selisih minimum skor buy vs sell

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
input bool     UseLondonSession   = true;    // Trading sesi London
input bool     UseNewYorkSession  = true;    // Trading sesi New York
input bool     UseAsiaSession     = false;   // Trading sesi Asia (tambahan)
input int      LondonOpen         = 7;       // Jam buka London (UTC)
input int      LondonClose        = 16;      // Jam tutup London (UTC)
input int      NYOpen             = 12;      // Jam buka New York (UTC)
input int      NYClose            = 21;      // Jam tutup New York (UTC)
input int      AsiaOpen           = 0;       // Jam buka Asia (UTC)
input int      AsiaClose          = 7;       // Jam tutup Asia (UTC)
input int      BrokerGMTOffset    = 2;       // Offset GMT broker server (jam, biasanya 2 atau 3)

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

datetime lastBarTime  = 0;
int      totalWins    = 0;
int      totalLoss    = 0;
double   totalProfit  = 0;
int      cachedTrades = 0;   // cached open trade count (updated per bar)

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

    // Set array sebagai series (index 0 = bar terbaru)
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

    Print("AntroMarket Gold EA v1.3 - Initialized successfully");
    Print("Symbol: ", _Symbol, " | Timeframe: M1");
    Print("Strategy: EMA Trend + RSI + Bollinger Bands + MACD + ATR");
    Print("Min Confirmations: ", MinConfirmations, " | Min Score Gap: ", MinScoreGap,
          " | Max Spread: ", MaxSpread);
    Print("Broker GMT Offset: ", BrokerGMTOffset, " hours");
    Print("SL Multi: ", ATR_SL_Multi, " | TP Multi: ", ATR_TP_Multi,
          " | Trail Multi: ", TrailATR_Multi, " | BE Multi: ", BreakEvenATR);

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
    // Cek hanya pada bar baru untuk logika entry
    datetime currentBar = iTime(_Symbol, PERIOD_M1, 0);
    if(currentBar == lastBarTime)
    {
        // Manage trailing stop setiap tick (tidak perlu bar baru)
        if(UseTrailingStop) ManageTrailingStop();
        if(ShowDashboard)   UpdateDashboard();
        return;
    }
    lastBarTime = currentBar;

    // Ambil data indikator (5 bar terakhir)
    if(!RefreshIndicatorData())
    {
        if(EnableDebugLog) Print("DEBUG: RefreshIndicatorData gagal");
        return;
    }

    // Update cached trade count per bar
    cachedTrades = CountOpenTrades();

    // Cek kondisi trading
    if(!IsSessionActive())
    {
        if(EnableDebugLog)
        {
            datetime serverTime = TimeCurrent();
            MqlDateTime dt;
            TimeToStruct(serverTime, dt);
            int utcHour = (dt.hour - BrokerGMTOffset + 24) % 24;
            Print("DEBUG: Sesi tidak aktif. Jam Server: ", dt.hour, ":", dt.min,
                  " | Jam UTC (calc): ", utcHour);
        }
        return;
    }

    if(!CheckSpread())
    {
        if(EnableDebugLog)
        {
            long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
            Print("DEBUG: Spread terlalu besar: ", spread, " > ", MaxSpread);
        }
        return;
    }

    if(cachedTrades >= MaxOpenTrades)
    {
        if(EnableDebugLog) Print("DEBUG: Max open trades tercapai: ", cachedTrades);
        return;
    }

    // Generate sinyal
    int signal = GetTradingSignal();

    if(signal == 1)  OpenBuy();
    if(signal == -1) OpenSell();
}

//+------------------------------------------------------------------+
//| Refresh semua data indikator (5 bar)                             |
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
    // --- Nilai indikator dari candle tertutup (index 1 = bar sebelumnya) ---
    double emaFast     = emaFastBuf[1];
    double emaMid      = emaMidBuf[1];
    double emaSlow     = emaSlowBuf[1];
    double emaFastPrev = emaFastBuf[2];   // EMA fast 2 bar lalu

    double rsi     = rsiBuf[1];
    double rsiPrev = rsiBuf[2];

    double bbUpper     = bbUpperBuf[1];
    double bbLower     = bbLowerBuf[1];
    double bbMid       = bbMidBuf[1];
    double bbUpperPrev = bbUpperBuf[2];   // BB upper 2 bar lalu (dari buffer)
    double bbLowerPrev = bbLowerBuf[2];   // BB lower 2 bar lalu (dari buffer)
    double bbWidth     = bbUpper - bbLower;

    double macdMain     = macdMainBuf[1];
    double macdSig      = macdSignalBuf[1];
    double macdMainPrev = macdMainBuf[2];
    double macdSigPrev  = macdSignalBuf[2];
    // MACD histogram = main - signal
    double macdHist     = macdMain - macdSig;
    double macdHistPrev = macdMainPrev - macdSigPrev;

    double atr        = atrBuf[1];
    double closePrice = iClose(_Symbol, PERIOD_M1, 1);
    double closePrev  = iClose(_Symbol, PERIOD_M1, 2);   // close 2 bar lalu
    double openPrice  = iOpen(_Symbol, PERIOD_M1, 1);
    bool   isBullishCandle = (closePrice > openPrice);
    bool   isBearishCandle = (closePrice < openPrice);

    // BB band width threshold: hanya entry jika BB cukup lebar (ada volatilitas)
    // Minimal lebar BB = 0.5 * ATR agar tidak entry di pasar flat
    bool bbHasVolatility = (bbWidth >= atr * 0.5);

    // ================================================================
    // === KONDISI BUY (semua kondisi bersifat BULLISH / directional) ===
    // ================================================================

    // 1. EMA alignment bullish: EMA9 > EMA21 > EMA50 (full alignment)
    //    ATAU minimal EMA9 > EMA21 DAN EMA9 sedang naik
    bool emaFullBullish = (emaFast > emaMid) && (emaMid > emaSlow);
    bool emaPartBullish = (emaFast > emaMid) && (emaFast > emaFastPrev);
    bool emaBullish     = emaFullBullish || emaPartBullish;

    // 2. RSI bullish: RSI > 50 (momentum bullish) dan tidak overbought
    //    RSI HARUS naik (strictly >) dari bar sebelumnya
    bool rsiBuySignal = (rsi > 50.0) && (rsi < RSI_Overbought) && (rsi > rsiPrev);

    // 3. BB buy signal:
    //    a) Harga di atas BB middle (trend bullish dalam BB), ATAU
    //    b) Bounce dari BB lower: close sebelumnya dekat/di bawah lower band
    //       (dalam jarak 0.3 * ATR dari lower band)
    bool bbAboveMid  = (closePrice > bbMid);
    bool bbBounce    = (closePrice > bbLower) &&
                       (closePrev <= bbLowerPrev + atr * 0.3);
    bool bbBuySignal = bbHasVolatility && (bbAboveMid || bbBounce);

    // 4. MACD bullish: histogram positif DAN sedang naik
    bool macdBullish = (macdHist > 0) && (macdHist > macdHistPrev);

    // 5. Candle bullish
    bool candleBuy = isBullishCandle;

    // Hitung skor konfirmasi BUY
    int buyScore = (emaBullish  ? 1 : 0) + (rsiBuySignal ? 1 : 0) +
                   (bbBuySignal ? 1 : 0) + (macdBullish  ? 1 : 0) +
                   (candleBuy   ? 1 : 0);

    // ================================================================
    // === KONDISI SELL (semua kondisi bersifat BEARISH / directional) ===
    // ================================================================

    // 1. EMA alignment bearish: EMA9 < EMA21 < EMA50 (full alignment)
    //    ATAU minimal EMA9 < EMA21 DAN EMA9 sedang turun
    bool emaFullBearish = (emaFast < emaMid) && (emaMid < emaSlow);
    bool emaPartBearish = (emaFast < emaMid) && (emaFast < emaFastPrev);
    bool emaBearish     = emaFullBearish || emaPartBearish;

    // 2. RSI bearish: RSI < 50 (momentum bearish) dan tidak oversold
    //    RSI HARUS turun (strictly <) dari bar sebelumnya
    bool rsiSellSignal = (rsi < 50.0) && (rsi > RSI_Oversold) && (rsi < rsiPrev);

    // 3. BB sell signal:
    //    a) Harga di bawah BB middle (trend bearish dalam BB), ATAU
    //    b) Rejection dari BB upper: close sebelumnya dekat/di atas upper band
    //       (dalam jarak 0.3 * ATR dari upper band)
    bool bbBelowMid   = (closePrice < bbMid);
    bool bbRejection  = (closePrice < bbUpper) &&
                        (closePrev >= bbUpperPrev - atr * 0.3);
    bool bbSellSignal = bbHasVolatility && (bbBelowMid || bbRejection);

    // 4. MACD bearish: histogram negatif DAN sedang turun
    bool macdBearish = (macdHist < 0) && (macdHist < macdHistPrev);

    // 5. Candle bearish
    bool candleSell = isBearishCandle;

    // Hitung skor konfirmasi SELL
    int sellScore = (emaBearish   ? 1 : 0) + (rsiSellSignal ? 1 : 0) +
                    (bbSellSignal ? 1 : 0) + (macdBearish   ? 1 : 0) +
                    (candleSell   ? 1 : 0);

    // Filter: tidak entry jika RSI di zona ekstrem berlawanan arah
    bool buyFilter  = (rsi < RSI_Overbought);
    bool sellFilter = (rsi > RSI_Oversold);

    // Tidak ada posisi berlawanan arah yang sudah terbuka
    // FIX: gunakan ENUM_POSITION_TYPE (bukan ENUM_ORDER_TYPE)
    bool noBuyPos  = !HasOpenPosition(POSITION_TYPE_BUY);
    bool noSellPos = !HasOpenPosition(POSITION_TYPE_SELL);

    if(EnableDebugLog)
    {
        Print("DEBUG SIGNAL | BuyScore: ", buyScore,
              " [EMA:", emaBullish, " RSI:", rsiBuySignal,
              " BB:", bbBuySignal, " MACD:", macdBullish, " Candle:", candleBuy, "]",
              " | SellScore: ", sellScore,
              " [EMA:", emaBearish, " RSI:", rsiSellSignal,
              " BB:", bbSellSignal, " MACD:", macdBearish, " Candle:", candleSell, "]",
              " | RSI=", DoubleToString(rsi, 1),
              " | RSIPrev=", DoubleToString(rsiPrev, 1),
              " | MACDHist=", DoubleToString(macdHist, 5),
              " | MACDHistPrev=", DoubleToString(macdHistPrev, 5),
              " | Close=", DoubleToString(closePrice, 2),
              " | BBMid=", DoubleToString(bbMid, 2),
              " | BBWidth=", DoubleToString(bbWidth, 2),
              " | ATR=", DoubleToString(atr, 2));
    }

    // Entry hanya jika:
    // 1. Skor mencapai minimum
    // 2. Skor lebih tinggi dari arah berlawanan (gap minimum)
    // 3. Filter RSI tidak ekstrem
    // 4. Tidak ada posisi berlawanan
    bool buyCondition  = (buyScore  >= MinConfirmations) &&
                         (buyScore  >= sellScore + MinScoreGap) &&
                         buyFilter  && noBuyPos;
    bool sellCondition = (sellScore >= MinConfirmations) &&
                         (sellScore >= buyScore  + MinScoreGap) &&
                         sellFilter && noSellPos;

    if(buyCondition)  return 1;
    if(sellCondition) return -1;

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
    double minSLDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(ask - sl < minSLDist)
        sl = NormalizeDouble(ask - minSLDist - _Point, digits);

    // Validasi TP harus lebih besar dari ask
    if(tp <= ask)
    {
        Print("ERROR BUY: TP tidak valid (tp=", tp, " <= ask=", ask, "). Batalkan order.");
        return;
    }

    Print("BUY attempt | Ask: ", ask, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);

    if(Trade.Buy(lots, _Symbol, ask, sl, tp, TradeComment))
    {
        if(EnableAlerts)
            Alert("AntroMarket BUY: ", _Symbol, " | Lots: ", lots,
                  " | SL: ", sl, " | TP: ", tp);
        Print("BUY opened | Price: ", ask, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);
        cachedTrades++;
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
    double minSLDist = (double)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL) * _Point;
    if(sl - bid < minSLDist)
        sl = NormalizeDouble(bid + minSLDist + _Point, digits);

    // Validasi TP harus lebih kecil dari bid
    if(tp >= bid)
    {
        Print("ERROR SELL: TP tidak valid (tp=", tp, " >= bid=", bid, "). Batalkan order.");
        return;
    }

    Print("SELL attempt | Bid: ", bid, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);

    if(Trade.Sell(lots, _Symbol, bid, sl, tp, TradeComment))
    {
        if(EnableAlerts)
            Alert("AntroMarket SELL: ", _Symbol, " | Lots: ", lots,
                  " | SL: ", sl, " | TP: ", tp);
        Print("SELL opened | Price: ", bid, " | SL: ", sl, " | TP: ", tp, " | Lots: ", lots);
        cachedTrades++;
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

    // Nilai per lot per tick
    double tickValue  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
    double tickSize   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

    if(tickSize <= 0 || tickValue <= 0) return 0;

    // Nilai SL dalam tick
    double slInTicks     = slDistance / tickSize;
    // Nilai uang per lot untuk SL ini
    double slValuePerLot = slInTicks * tickValue;

    if(slValuePerLot <= 0) return 0;

    double lots = riskAmount / slValuePerLot;

    // Normalisasi lot
    double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
    double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
    double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);

    // Fallback jika nilai tidak valid
    if(minLot  <= 0) minLot  = 0.01;
    if(maxLot  <= 0) maxLot  = 100.0;
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
//| Trailing Stop & Break-Even Management                            |
//| - Break-even: pindah SL ke open price setelah profit >= BE dist  |
//| - Trailing: setelah BE terpasang, trailing stop terus berjalan   |
//+------------------------------------------------------------------+
void ManageTrailingStop()
{
    // Refresh ATR buffer untuk trailing
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
        int    digits    = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

        if(posType == POSITION_TYPE_BUY)
        {
            double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
            double profit = bid - openPrice;

            // 1. Break-Even: pindah SL ke open price + 1 point
            if(profit >= beDist && currentSL < openPrice)
            {
                double newSL = NormalizeDouble(openPrice + _Point, digits);
                if(newSL > currentSL)
                {
                    Trade.PositionModify(ticket, newSL, currentTP);
                    if(EnableDebugLog)
                        Print("BE BUY | Ticket: ", ticket, " | NewSL: ", newSL);
                }
            }

            // 2. Trailing Stop: jalankan setelah profit > trailing distance
            //    (berjalan independen dari break-even)
            if(profit > trailDist)
            {
                double newSL = NormalizeDouble(bid - trailDist, digits);
                if(newSL > currentSL)
                {
                    Trade.PositionModify(ticket, newSL, currentTP);
                    if(EnableDebugLog)
                        Print("TRAIL BUY | Ticket: ", ticket, " | NewSL: ", newSL);
                }
            }
        }
        else if(posType == POSITION_TYPE_SELL)
        {
            double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
            double profit = openPrice - ask;

            // 1. Break-Even: pindah SL ke open price - 1 point
            if(profit >= beDist && currentSL > openPrice)
            {
                double newSL = NormalizeDouble(openPrice - _Point, digits);
                if(newSL < currentSL)
                {
                    Trade.PositionModify(ticket, newSL, currentTP);
                    if(EnableDebugLog)
                        Print("BE SELL | Ticket: ", ticket, " | NewSL: ", newSL);
                }
            }

            // 2. Trailing Stop: jalankan setelah profit > trailing distance
            if(profit > trailDist)
            {
                double newSL = NormalizeDouble(ask + trailDist, digits);
                if(newSL < currentSL)
                {
                    Trade.PositionModify(ticket, newSL, currentTP);
                    if(EnableDebugLog)
                        Print("TRAIL SELL | Ticket: ", ticket, " | NewSL: ", newSL);
                }
            }
        }
    }
}

//+------------------------------------------------------------------+
//| Cek apakah sesi aktif                                            |
//| Menggunakan TimeCurrent() (jam server broker) dikurangi offset   |
//| untuk mendapatkan jam UTC                                        |
//+------------------------------------------------------------------+
bool IsSessionActive()
{
    datetime serverTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(serverTime, dt);

    // Hitung jam UTC dari jam server broker
    int utcHour = (dt.hour - BrokerGMTOffset + 24) % 24;

    bool london = UseLondonSession  && (utcHour >= LondonOpen && utcHour < LondonClose);
    bool ny     = UseNewYorkSession && (utcHour >= NYOpen     && utcHour < NYClose);
    bool asia   = UseAsiaSession    && (utcHour >= AsiaOpen   && utcHour < AsiaClose);

    return (london || ny || asia);
}

//+------------------------------------------------------------------+
//| Cek spread                                                       |
//+------------------------------------------------------------------+
bool CheckSpread()
{
    long spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    return (spread <= (long)MaxSpread);
}

//+------------------------------------------------------------------+
//| Hitung jumlah trade terbuka milik EA                             |
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
//| Cek apakah ada posisi terbuka berdasarkan tipe                   |
//| FIX: gunakan ENUM_POSITION_TYPE (bukan ENUM_ORDER_TYPE)          |
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
//| Update dashboard di chart                                        |
//+------------------------------------------------------------------+
void UpdateDashboard()
{
    int    spread  = (int)SymbolInfoInteger(_Symbol, SYMBOL_SPREAD);
    double atr     = (ArraySize(atrBuf) > 1) ? atrBuf[1] : 0;
    double rsi     = (ArraySize(rsiBuf) > 1) ? rsiBuf[1] : 0;
    int    total   = totalWins + totalLoss;
    double winRate = (total > 0) ? (double)totalWins / total * 100 : 0;

    datetime serverTime = TimeCurrent();
    MqlDateTime dt;
    TimeToStruct(serverTime, dt);
    int utcHour = (dt.hour - BrokerGMTOffset + 24) % 24;
    bool sessionActive = IsSessionActive();

    string dash = "";
    dash += "╔═══════════════════════════════╗\n";
    dash += "║   ANTROMARKET GOLD EA v1.3    ║\n";
    dash += "╠═══════════════════════════════╣\n";
    dash += StringFormat("║  Symbol   : %-18s ║\n", _Symbol);
    dash += StringFormat("║  Spread   : %-18s ║\n", IntegerToString(spread) + " pts");
    dash += StringFormat("║  ATR      : %-18s ║\n", DoubleToString(atr, 2));
    dash += StringFormat("║  RSI      : %-18s ║\n", DoubleToString(rsi, 1));
    dash += StringFormat("║  UTC Hour : %-18s ║\n", IntegerToString(utcHour) + ":xx");
    dash += StringFormat("║  Session  : %-18s ║\n", sessionActive ? "ACTIVE" : "CLOSED");
    dash += StringFormat("║  Trades   : %-18s ║\n", IntegerToString(cachedTrades));
    dash += "╠═══════════════════════════════╣\n";
    dash += StringFormat("║  Win      : %-18s ║\n", IntegerToString(totalWins));
    dash += StringFormat("║  Loss     : %-18s ║\n", IntegerToString(totalLoss));
    dash += StringFormat("║  Win Rate : %-18s ║\n", DoubleToString(winRate, 1) + "%");
    dash += StringFormat("║  Net P/L  : %-18s ║\n", DoubleToString(totalProfit, 2));
    dash += "╚═══════════════════════════════╝";

    Comment(dash);
}

//+------------------------------------------------------------------+
