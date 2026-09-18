//+------------------------------------------------------------------+

//| XAUUSD Session Martingale Basket EA                              |

//| Version 5.00                                                     |

//+------------------------------------------------------------------+

#property strict

#property version "5.00"



#include <Trade/Trade.mqh>



CTrade trade;



//====================================================================

// GENERAL

//====================================================================



input group "===== GENERAL =====";

input ulong  MagicNumber          = 600001050;

input double DailyDeposit         = 50000.0; // Daily Deposit / Base Balance (USD) for daily backtesting & DD calculations

input bool   EnableChartDisplay   = false;   // Enable On-Chart HUD Display (Disable/false for ultra-fast backtesting)



string EAComment = "XAU_MARTINGALE";



bool CycleWasActive = false;



//====================================================================

// ADX HEDGE (OPPOSITE POSITION ON ADX TREND SPIKE)

//====================================================================



input group "===== ADX HEDGE =====";

input bool            EnableADXHedge          = true;        // Enable ADX-Triggered Hedge

input int             ADXHedgeMinGrids        = 15;          // Minimum Open Grids required to trigger ADX Hedge (default 15)

input double          ADXHedgeThreshold       = 30.0;        // Trigger Hedge when ADX > this value (e.g. 30.0)

input int             ADXHedgePeriod          = 14;          // ADX Indicator Period (default 14)

input ENUM_TIMEFRAMES ADXHedgeTimeframe       = PERIOD_M1;   // ADX Timeframe (e.g. PERIOD_M1, PERIOD_M5)

input double          ADXHedgeLotMultiplier   = 0.25;        // Hedge Lot = Sum of Grid Lots x Multiplier (e.g. 0.25x)

input ulong           ADXHedgeMagicNumber     = 600001051;   // ADX Hedge Magic Number

input bool            ADXHedgeAffectsBasketTP = false;       // Include Live Hedge in Basket TP (default false: pure grid calculation)



CTrade hedgeTrade;



// ATR volatility-scaled distance state

int    ATRHandle   = INVALID_HANDLE;

double BaselineATR = 0.0; // ATR captured at the start of the current cycle



// ADX Hedge Handle & Tracking

int    hADX_Hedge              = INVALID_HANDLE;

bool   ADXHedgeOpenedThisCycle = false;



// Friday Rollover Protection State Tracking

bool   FridayHedgeLockedThisCycle = false;

int    g_FridayBasketActionMin    = -1;

int    g_MondayHedgeUnfreezeMin   = -1;





datetime DDResumeTime = 0; // Timestamp until which trading is paused after DD Control hit

datetime MaxPosCloseResumeTime = 0; // Timestamp until which trading is paused for the day after Max Pos close



// Drawdown Logging State Tracking

struct SDREvent {

  string   ddDate;

  datetime gridStartTime;

  datetime ddHitTime;

  datetime closeTime;

  double   hitDD;

  double   maxDD;

  double   maxDDPct;

  string   direction;

  int      positions;

  int      maxPositions;

  double   lots;

  double   maxLots;

  double   avgPrice;

  double   currentPrice;

  string   exitReason;

};



SDREvent DDHistory[];

bool     DDThresholdLoggedThisCycle = false;

double   CurrentCycleMaxDD          = 0.0;

double   OverallMaxDDObserved       = 0.0;



// Virtual Basket TP: the basket exit is monitored and executed entirely by

// the EA (instead of a real broker-side TP order on each grid position).

// This guarantees the EA can always close the hedge FIRST and the grid

// SECOND, in that exact order, the instant the target is reached.

double VirtualBasketTP = 0.0;



//====================================================================

// DIRECTIONAL PREDICTION / SR / TREND FILTER STATE

//====================================================================



enum ENUM_PREDICTED_DIRECTION { PRED_SIDEWAYS = 0, PRED_BUY = 1, PRED_SELL = 2 };

enum ENUM_TREND_STATE         { TREND_NONE = 0, TREND_UP = 1, TREND_DOWN = 2 };



int hPredFastMA = INVALID_HANDLE;

int hPredSlowMA = INVALID_HANDLE;

int hPredRSI    = INVALID_HANDLE;

int hPredADX    = INVALID_HANDLE;



int hTrendMA  = INVALID_HANDLE;

int hTrendADX = INVALID_HANDLE;

int hMacroMA  = INVALID_HANDLE;



// One record per cycle, filled at StartNewCycle() and finalized/written

// the moment the cycle closes (whichever exit path fires).

struct SPredictionRecord {

  bool     active;           // true while a cycle opened by this record is still running

  datetime cycleStartTime;

  string   predictedDirection;

  bool     allowBuy;

  bool     allowSell;

  bool     rangeBlockedBuy;

  bool     rangeBlockedSell;

  bool     srBlockedBuy;

  bool     srBlockedSell;

  bool     trendBlockedBuy;

  bool     trendBlockedSell;

  double   initialAsk;

  double   initialBid;

  string   sideOpened;       // "BUY", "SELL", "BOTH", "NONE"

};



SPredictionRecord CurrentPrediction;

int    CycleMaxGridLevel = 0; // Highest CountPositions() seen this cycle - used for "first time win" detection

double CycleSessionMultiplier = 0.0; // Distance multiplier captured when the current cycle was initiated

double CycleBaseLot = 0.0;           // Effective base lot for current active cycle (anchors martingale scaling)

bool   Level1PartialClosedThisCycle = false; // Flag to track if Level 1 partial TP occurred



// Pending order reference price tracking (for market movement reset)

double   PendingOrderRefAsk    = 0.0;

double   PendingOrderRefBid    = 0.0;

datetime PendingOrderPlaceTime = 0;



// Post-close delay state tracking

datetime LastPositionCloseTime      = 0;

ulong    LastPositionCloseTickCount = 0;



// In-memory log of completed prediction records, rewritten to CSV on each close

struct SPredictionLogEntry {

  string   dateStr;

  datetime cycleStartTime;

  datetime cycleCloseTime;

  string   predictedDirection;

  string   srBlocked;

  string   trendBlocked;

  string   sideOpened;

  string   actualSide;

  double   netProfit;

  int      maxGridLevel;

  string   firstTimeWin;

  string   predictionCorrect;

  string   finalResult;

  string   exitReason;

};



SPredictionLogEntry PredictionLog[];



//====================================================================

// INITIAL TRADE

//====================================================================



input group "===== INITIAL TRADE =====";

input double InitialLot          = 0.01;

input double InitialDistance     = 0.6;

input double InitialTPPips       = 100.0;   // Initial Profit Target in Pips

input int    PostCloseDelaySec   = 3;       // Delay to Open New Position/Cycle After Close (seconds, default 3)



//====================================================================

// DYNAMIC EQUITY-COMPOUNDING LOT SIZING (OPTION 2)

//

// Automatically scales base InitialLot proportionally with account balance growth.

// As the account compounds from profits, lot sizes expand geometrically

// while maintaining the same percentage margin risk.

// Formula: CompoundedLot = InitialLot * (AccountBalance / CompoundingBaseBalance)

//====================================================================



input group "===== DYNAMIC EQUITY COMPOUNDING =====";

input bool   EnableAutoLotCompounding = false;    // Enable Auto-Compounding Lot Sizing based on Account Equity

input double CompoundingBaseBalance   = 50000.0;  // Reference Base Balance (USD) for InitialLot scaling (e.g. 50000)



//====================================================================

// LEVEL 1 TREND-RUNNER (OPTION 3)

//

// When a cycle opens at Level 1 and reaches InitialTPPips in profit:

// - If lot >= 0.02: Closes 50% partial volume to lock in profit, moves SL

//   to Breakeven (+buffer), and trails the remaining volume for trend windfalls.

// - If lot == 0.01: Either takes full profit at Initial TP (default), or

//   moves SL to Breakeven and trails the full 0.01 single lot.

// If market pulls back and adds a grid level (Level 2+), the trailing stop

// is disengaged and standard martingale basket TP takes full control.

//====================================================================



input group "===== LEVEL 1 TREND-RUNNER =====";

input bool   EnableLevel1TrendRunner     = true;   // Enable Level 1 Trend-Runner Partial TP & Trailing Stop

input double Level1PartialClosePct       = 50.0;   // Partial Close % at Initial TP (for lots >= 0.02, default 50%)

input double Level1BreakevenBufferPips   = 5.0;    // Breakeven Lock Buffer in Pips (e.g. +5 pips)

input double Level1TrailingDistancePips  = 50.0;   // Trailing Stop Distance in Pips behind price

input bool   Level1TrailFullSingleLot    = false;  // Trail full 0.01 single lot after breakeven lock (false = close at TP)



//====================================================================

// PENDING ORDER RESET (MARKET MOVES AWAY FROM PENDING ORDER PRICE)

//

// After placing initial pending stop orders, if the market moves away

// from the pending order price by PendingResetDistancePips (e.g. 30

// pips), the EA deletes all pending orders and re-evaluates all filters

// and prediction conditions to start a fresh cycle.

//====================================================================



input group "===== PENDING ORDER RESET (MARKET MOVES AWAY) =====";

input bool   EnablePendingOrderReset  = true;  // Enable Reset Pending Orders if Market Moves Away

input double PendingResetDistancePips = 30.0;  // Reset Distance in Pips from Pending Order Price (e.g. 30 Pips)



//====================================================================

// MARTINGALE

//====================================================================



input group "===== MARTINGALE =====";

input double Multiplier         = 1.68;



input int    MaximumTrades      = 20;

input double MaximumLot         = 5.0;



//====================================================================

// GRID LIMIT CONTROL (prevent runaway grid additions)

//====================================================================



input group "===== GRID LIMIT CONTROL =====";

input bool   EnableHardGridCap           = true;  // Hard ceiling on grid additions, independent/lower than MaximumTrades

input int    MaxGridLevelsHardCap        = 20;    // No more grid levels will be added once this many positions are open

input bool   EnableMaxPositionsClose     = true;  // Enable Auto-Close Grid when Max Positions reached

input int    MaxPositionsToClose         = 20;    // Close Entire Grid Basket if open positions reach this count (e.g. 20)

input bool   PauseRestOfDayOnMaxPosClose = true;  // Pause Trading for Rest of the Day if Max Positions Auto-Close is hit (true/false)



//====================================================================

// DIRECTIONAL PREDICTION MODEL (Buy / Sell / Sideways)

//

// Before a new cycle opens, this model looks at trend (MA cross),

// momentum (RSI) and trend strength (ADX + DI) on PredictionTimeframe

// to decide whether conditions favor BUY only, SELL only, or are

// SIDEWAYS/unclear. On a directional call, only that side's stop

// order is placed (no opposite-side order this cycle). On SIDEWAYS,

// behavior falls back to the original both-sides straddle.

//

// NOTE: this is a simple technical-indicator heuristic, not a

// statistically validated predictive model. Its real effect on win

// rate can only be confirmed by backtesting/forward-testing with the

// prediction log this EA now writes - treat the "improve win rate"

// goal as something to verify empirically, not a guarantee.

//====================================================================



input group "===== DIRECTIONAL PREDICTION (WIN-RATE FILTER) =====";

input bool             EnableDirectionalPrediction = true;        // Master switch

input ENUM_TIMEFRAMES  PredictionTimeframe         = PERIOD_M15;  // Timeframe for prediction indicators

input int              PredictionFastMAPeriod      = 20;

input int              PredictionSlowMAPeriod      = 50;

input int              PredictionRSIPeriod         = 14;

input int              PredictionADXPeriod         = 14;

input double           PredictionADXTrendThreshold = 22.0;        // ADX >= this => market is trending (directional call allowed)

input double           PredictionRSIOverbought     = 60.0;        // Don't call BUY if RSI already this high (prevents top-buying)

input double           PredictionRSIOversold       = 40.0;        // Don't call SELL if RSI already this low (prevents bottom-selling)

input bool             OnlyTradeBothWhenSideways   = true;        // If false, a SIDEWAYS read skips the cycle entirely instead of opening both sides



//====================================================================

// 24-HOUR RANGE BOUNDARY GUARD (FOR SIDEWAYS STRADDLES)

//

// Blocks placing a BUY stop when price is in the upper boundary (e.g. top 20%)

// of the 24-hour range, and blocks placing a SELL stop when price is in

// the lower boundary (e.g. bottom 20%). Prevents buying at the 24h ceiling

// or selling at the 24h floor during sideways market conditions.

//====================================================================



input group "===== 24-HOUR RANGE BOUNDARY GUARD =====";

input bool             EnableRangeBoundaryFilter   = true;  // Block buying near 24H High or selling near 24H Low in Sideways

input double           RangeBoundaryThresholdPct   = 20.0;  // Range Boundary Guard Zone % (e.g. top/bottom 20%)

input int              RangeLookbackHours          = 24;    // Lookback period in hours for 24H Range (e.g. 24h)

input bool             RangeBoundarySidewaysOnly   = true;  // Apply boundary guard only to Sideways/Both-side cycles (true) or All cycles (false)



//====================================================================

// SUPPORT / RESISTANCE ZONE FILTER

//

// Scans PredictionTimeframe-independent higher timeframe (SRTimeframe)

// swing highs/lows over SRLookbackBars, clusters nearby swing points

// into zones, and treats a zone as "strong" once it has been touched

// SRMinTouches times or more. No BUY is placed within SRZoneBufferPips

// of a strong resistance zone; no SELL is placed within

// SRZoneBufferPips of a strong support zone.

//====================================================================



input group "===== SUPPORT / RESISTANCE ZONE FILTER =====";

input bool             EnableSRFilter      = true;

input ENUM_TIMEFRAMES  SRTimeframe         = PERIOD_H1;

input int              SRLookbackBars      = 150;

input int              SRSwingStrength     = 3;     // Bars required on each side to confirm a swing high/low

input double           SRZoneBufferPips    = 50.0;  // "Near the zone" tolerance, in pips

input int              SRMinTouches        = 2;      // Minimum touches for a zone to count as "strong"



//====================================================================

// TREND FILTER (no counter-trend entries or grid additions)

//

// Uses a moving average slope plus ADX/DI on TrendFilterTimeframe.

// A confirmed strong DOWNtrend blocks new BUY entries and BUY grid

// additions; a confirmed strong UPtrend blocks new SELL entries and

// SELL grid additions.

//====================================================================



input group "===== TREND FILTER (NO COUNTER-TREND ENTRIES) =====";

input bool             EnableTrendFilter        = true;

input ENUM_TIMEFRAMES  TrendFilterTimeframe     = PERIOD_H1;

input int              TrendFilterMAPeriod      = 100;

input double           TrendFilterADXThreshold  = 18.0;



//====================================================================

// MACRO H4 TREND FILTER (PROTECT AGAINST RUNAWAY SECULAR TRENDS)

//

// Uses the Macro H4 200 EMA to classify the secular market regime.

// When Bid > H4 200 EMA (Macro Uptrend):

//   - With-trend BUY cycles are permitted up to MacroWithTrendMaxGrid (default 15).

//   - Counter-trend SELL cycles are either capped at MacroCounterTrendMaxGrid (default 6)

//     or completely disabled (if MacroCounterTrendMode = COUNTER_TREND_DISABLE).

// When Bid < H4 200 EMA (Macro Downtrend), symmetric protection applies to BUY cycles.

//====================================================================



enum ENUM_COUNTER_TREND_MODE {

  COUNTER_TREND_CAP_GRID = 0, // Cap counter-trend grid at Level 6 (or custom), allow with-trend up to Level 15

  COUNTER_TREND_DISABLE  = 1  // Disable counter-trend cycles completely (trade ONLY with macro trend)

};



input group "===== MACRO H4 TREND FILTER =====";

input bool                    EnableMacroTrendFilter   = true;                   // Enable Macro H4 200 EMA Trend Filter

input ENUM_TIMEFRAMES         MacroTrendTimeframe      = PERIOD_H4;              // Macro Trend Timeframe

input int                     MacroTrendMAPeriod       = 200;                    // Macro Trend EMA Period

input ENUM_COUNTER_TREND_MODE MacroCounterTrendMode    = COUNTER_TREND_CAP_GRID; // Counter-Trend Mode (Cap Grid or Disable)

input int                     MacroCounterTrendMaxGrid = 6;                      // Max Grid Levels allowed for Counter-Trend cycles (e.g. 6)

input int                     MacroWithTrendMaxGrid    = 15;                     // Max Grid Levels allowed for With-Trend cycles (e.g. 15)

input bool                    EnableMacroSkew          = true;                   // Enable Macro Trend Volume & Distance Skew (Option 6)

input double                  MacroWithTrendLotMult    = 1.5;                    // With-Trend Lot Multiplier (e.g. 1.5x on BUY in bull market)

input double                  MacroWithTrendDistMult   = 0.90;                   // With-Trend Distance Multiplier (e.g. 0.90x tighter spacing)

input double                  MacroCounterTrendLotMult = 1.0;                    // Counter-Trend Lot Multiplier (default 1.0x)

input double                  MacroCounterTrendDistMult= 1.20;                   // Counter-Trend Distance Multiplier (e.g. 1.20x wider spacing)



//====================================================================

// PREDICTION / OUTCOME LOG

//

// Every cycle (including cycles skipped entirely due to filters)

// writes one row containing what was predicted, which filters fired,

// which side was actually opened, how it closed, and whether it was

// a "first time win" (closed profitably at the initial grid level,

// with no martingale averaging needed).

//====================================================================



input group "===== PREDICTION LOGGING =====";

input bool   EnablePredictionLog   = false;

input string PredictionLogFileName = "GT_Prediction_Log.csv";



//====================================================================

// ATR VOLATILITY-SCALED DISTANCE

//

// The base grid spacing formula stays geometric:

//   distance = InitialDistance * SessionDistanceMultiplier^(level-1)

//

// On top of that, the whole distance is multiplied by a volatility

// ratio = CurrentATR / BaselineATR, where BaselineATR is the ATR

// value captured the moment a new cycle starts (StartNewCycle()).

// So if volatility rises during the cycle, every subsequent grid

// level's spacing widens proportionally; if it falls, spacing

// narrows. The ratio is clamped between ATR_MinRatio and

// ATR_MaxRatio so a volatility spike/crush can't produce absurd

// spacing. When UseATRDistanceScaling = false, the ratio is

// forced to 1.0 and behavior is identical to the original EA.

//====================================================================



input group "===== ATR DISTANCE SCALING =====";

input bool             UseATRDistanceScaling = true;

input int              ATR_Period            = 14;

input ENUM_TIMEFRAMES  ATR_Timeframe         = PERIOD_CURRENT;

input double           ATR_MinRatio          = 1.0;  // Floor for CurrentATR / BaselineATR

input double           ATR_MaxRatio          = 2.00; // Ceiling for CurrentATR / BaselineATR







//====================================================================

// BASKET TP

//

// This is PRICE DISTANCE.

//

// BUY:

// Average + BasketTP

//

// SELL:

// Average - BasketTP

//

// Dynamic Step Basket TP:

// When open grid positions reach or cross StepBasketTPGridLevel (e.g. 15),

// the basket profit target distance automatically switches to StepBasketTP

// (e.g. 0.10) for faster recovery and reduced exposure.

//====================================================================



input group "===== BASKET TAKE PROFIT =====";

input double BasketTP                 = 0.60;  // Standard Basket Take Profit distance (price units, e.g. 0.6)

input bool   EnableStepBasketTP       = true;  // Enable Dynamic/Reduced Basket TP at High Grid Levels

input int    StepBasketTPGridLevel    = 15;    // Grid Level threshold to trigger Reduced Basket TP (e.g. >= 15 positions)

input double StepBasketTP             = 0.10;  // Reduced Basket Take Profit distance once trigger level is reached (e.g. 0.1)

input bool   UseATRBasketTPScaling    = true;  // Scale Basket TP with ATR Volatility Expansion (Option 4)

input double ATR_TP_MaxRatio          = 2.00;  // Maximum Basket TP ATR Expansion Ratio (e.g. 2.0x ceiling)

input bool   EnableTimeDecayTP        = true;  // Enable Time-Decay TP for Stale Baskets (> 24h)

input double TimeDecayHours           = 24.0;  // Basket Age (hours) to trigger Time-Decay TP reduction (e.g. 24.0h)

input double DecayBasketTP            = 0.05;  // Reduced Basket TP distance after time decay (Breakeven + 0.05)

input bool   InpCompensateSwapAndCommission = true;  // Compensate Swap & Commission in Basket TP (Eliminates negative rollover exits)

input bool   InpEnsureNetProfitOnTP         = true;  // Ensure Net Dollar Profit > 0 before closing at TP

input double InpMinNetProfitOnTP            = 1.0;   // Minimum Net Dollar Profit ($) required when TP is hit





//====================================================================

//====================================================================

// SESSIONS: AUTO GMT ADAPTATION & SCHEDULE

//====================================================================



input group "===== SESSIONS: AUTO GMT & TIMING =====";

input bool   AutoAdaptSessionGMT = true;  // Auto-adapt session times to universal GMT across all brokers

input int    SessionsBaseGMT     = 3;     // Reference GMT offset for the session times below (3 = GMT+3)



input group "===== SESSION 1 (Asian Morning Calm) =====";

input bool   EnableSession1             = true;

input string Session1Start              = "05:00";

input string Session1End                = "07:00";

input double Session1DistanceMultiplier = 1.10; // Session 1 Distance Multiplier

input double Session1LotMultiplier      = 1.0;  // Session 1 Lot Multiplier (e.g. 2.0x for Asian Calm edge)



//====================================================================

// SESSION 2

//====================================================================



input group "===== SESSION 2 (Post-NY Night Consolidation) =====";

input bool   EnableSession2             = true;

input string Session2Start              = "21:30";

input string Session2End                = "23:30";

input double Session2DistanceMultiplier = 1.10; // Session 2 Distance Multiplier

input double Session2LotMultiplier      = 1.0;  // Session 2 Lot Multiplier (e.g. 2.0x for Post-NY edge)



//====================================================================

// SESSION 3

//====================================================================



input group "===== SESSION 3 (European Lunch Range) =====";

input bool   EnableSession3             = true;

input string Session3Start              = "12:00";

input string Session3End                = "13:00";

input double Session3DistanceMultiplier = 1.10; // Session 3 Distance Multiplier

input double Session3LotMultiplier      = 1.0;  // Session 3 Lot Multiplier



//====================================================================

// SESSION 4

//====================================================================



input group "===== SESSION 4 (Post-London Morning Reversion) =====";

input bool   EnableSession4             = true;

input string Session4Start              = "08:30";

input string Session4End                = "09:30";

input double Session4DistanceMultiplier = 1.10; // Session 4 Distance Multiplier

input double Session4LotMultiplier      = 1.0;  // Session 4 Lot Multiplier



//====================================================================

// SESSION 5

//====================================================================



input group "===== SESSION 5 (Overnight Asian / Disabled) =====";

input bool   EnableSession5             = false;

input string Session5Start              = "02:00";

input string Session5End                = "05:00";

input double Session5DistanceMultiplier = 1.10; // Session 5 Distance Multiplier

input double Session5LotMultiplier      = 1.0;  // Session 5 Lot Multiplier



//====================================================================

// FRIDAY TRADING FILTER (NO NEW CYCLES AFTER CUTOFF)

//====================================================================



input group "===== FRIDAY TRADING FILTER =====";

input bool   EnableFridayFilter   = true;    // Enable Friday trading cutoff filter (true/false)

input string FridayCutoffTime     = "14:00"; // Friday Cutoff Time (HH:MM) - No new cycles after this time on Fridays



//====================================================================

// FRIDAY ROLLOVER BASKET PROTECTION (LEVEL 8+ RULE)

//====================================================================



enum ENUM_FRIDAY_BASKET_ACTION {

  FRIDAY_ACTION_CLOSE_MARKET   = 0, // Option 1: Close Basket at Current Market Price

  FRIDAY_ACTION_LOCK_100_HEDGE = 1  // Option 2: Lock with 100% Hedge (Delta Neutral)

};



input group "===== FRIDAY ROLLOVER PROTECTION (LEVEL 8+) =====";

input bool                     EnableFridayBasketRule   = true;                       // Enable Friday Rollover Basket Rule (Level 8+)

input string                   FridayBasketActionTime   = "20:00";                    // Friday Trigger Server Time (HH:MM)

input int                      FridayBasketMinLevel     = 8;                          // Minimum Grid Positions to trigger (default 8)

input ENUM_FRIDAY_BASKET_ACTION FridayBasketAction      = FRIDAY_ACTION_CLOSE_MARKET; // Rollover Action: Close at Market or Lock 100% Hedge

input bool                     FridayHedgeCloseOnMonday = true;                       // (For 100% Hedge) Auto-close hedge on Monday

input string                   MondayHedgeUnfreezeTime  = "08:00";                    // (For 100% Hedge) Monday Server Time to unfreeze hedge (HH:MM)





//====================================================================

// DRAWDOWN CONTROL & BASKET STOP LOSS

//====================================================================



enum ENUM_DD_CONTROL_MODE {

  DD_CONTROL_PERCENT  = 0, // Option 1: % of Account Balance (e.g. 10.0%)

  DD_CONTROL_MONEY    = 1, // Option 2: Fixed Money in Account Currency (e.g. 500.0 USD)

  DD_CONTROL_DISTANCE = 2  // Option 3: Price Distance from Weighted Average Price

};



input group "===== DRAWDOWN CONTROL (BASKET SL) =====";

input bool                 EnableDDControl            = false;              // Enable Drawdown Control / Basket SL

input ENUM_DD_CONTROL_MODE DDControlMode              = DD_CONTROL_PERCENT; // Drawdown calculation mode

input double               MaxDrawdownPct             = 10.0;               // Option 1: Max Drawdown % of Balance (e.g. 10.0%)

input double               MaxDrawdownMoney           = 500.0;              // Option 2: Max Drawdown in Money/USD (e.g. 500.0)

input double               BasketStopLoss             = 5.00;               // Option 3: Price Distance SL from Avg Price

input double               DDPauseHours               = 2.0;                // Pause trading after DD hit (hours, default 2.0 hrs)

input bool                 PauseRestOfDayOnDDControl  = true;               // Pause trading for rest of the day if Drawdown Control SL is hit (true/false)



//====================================================================

// DRAWDOWN MONITOR & LOGGING

//====================================================================



input group "===== DRAWDOWN MONITOR & LOGGING =====";

input bool   EnableDDLogging      = false;                 // Enable logging when Drawdown threshold is reached

input double DDLogThreshold       = 50000.0;               // Drawdown threshold to trigger logging (USD / Money)

input bool   WriteDDLogToFile     = false;                 // Write drawdown events to CSV file in MQL5/Files

input string DDLogFileName        = "DD_50000_Log.csv";    // Log CSV file name (saved in MQL5/Files)



//====================================================================

// BASKET MAX DURATION (TIME-OUT EXIT)

//====================================================================



input group "===== BASKET MAX DURATION =====";

input bool   EnableMaxGridDuration = true;  // Enable Auto-Close Basket after Max Hours

input double MaxGridDurationHours  = 12.0;  // Close Basket if active for longer than (hours, default 12.0 hrs)



//====================================================================

// HIGH-IMPACT NEWS FILTER

//

// Uses MT5's LIVE built-in Economic Calendar (CalendarValueHistory /

// CalendarEventById) rather than a hardcoded date table. Future

// FOMC/NFP/CPI/etc dates are not reliably known years in advance

// (the Fed itself only confirms meeting dates roughly a year or so

// ahead), so hardcoding them risks the filter silently failing to

// catch a real event. The live calendar is checked every tick

// (throttled) and stays correct automatically as dates change.

//

// Per MQL5 docs, calendar event times are already returned in the

// TRADE SERVER timezone (same as TimeCurrent()), so no GMT

// conversion is normally required. InpNewsGmtMode/InpNewsGmtOffset

// are kept as a manual override for the rare case your broker's

// calendar feed does NOT match server time - leave GmtMode=0

// (default / recommended) unless you have a specific reason.

//====================================================================



input group "===== NEWS FILTER: GENERAL =====";

input bool InpEnableNewsFilter = true;

input int  InpNewsGmtMode      = 0; // 0 = trust calendar server time (recommended), 1 = apply manual offset below

input int  InpNewsGmtOffset    = 2; // only used when InpNewsGmtMode = 1 (hours)

input int  InpNewsBeforeMinutes = 60;

input int  InpNewsAfterMinutes  = 60;

input bool InpBlockGridDuringNews = true; // also pause NEW martingale grid additions during blackout



input group "===== NEWS FILTER: OFFLINE CSV (BACKTEST & LIVE) =====";

input bool   InpUseOfflineNewsCSV      = true;        // Use Offline News CSV (Enables news filtering in Strategy Tester)

input string InpNewsCSVFileName        = "news.csv";  // News CSV filename in MQL5/Files (or Common/Files)

input bool   InpNewsCSVCommonDir       = false;       // Read CSV from Common Files directory (FILE_COMMON)

input string InpNewsCurrencies         = "USD,XAU";   // Currencies to filter (comma-separated, e.g. USD,XAU)

input bool   InpNewsFilterHighOnly     = true;        // Filter High Impact Only (if false, includes Medium)



input group "===== NEWS FILTER: EVENTS =====";

input bool InpFilterFOMC_Rate      = true;

input bool InpFilterFOMC_DotPlot   = true;

input bool InpFilterFOMC_PressConf = true;

input bool InpFilterNFP            = true;

input bool InpFilterCPI            = true;

input bool InpFilterCorePCE        = true;

input bool InpFilterGDP            = true;

input bool InpFilterRetailSales    = true;

input bool InpFilterPPI            = true;

input bool InpFilterISM_PMI        = true;

input bool InpFilterJacksonHole    = true;

input bool InpFilterFedChairSpeech = true;



bool NewsBlackoutActive = false;

datetime NewsLastCheckTime = 0;

string NewsActiveEventName = "";



struct SOfflineNewsEvent {

  datetime eventTime;

  string   currency;

  string   impact;

  string   title;

};



SOfflineNewsEvent OfflineNewsList[];

int OfflineNewsCount = 0;



//====================================================================

// SPECIFIC TRADING DATES ONLY (RUN STRATEGY ONLY ON SPECIFIED DATES)

//

// When EnableAllowedDatesOnly = true, the strategy will ONLY trade on

// dates specified in AllowedTradingDates (e.g. "10-Jan-2026, 12-Jan-2026").

// On all other dates, no new orders or cycles will be opened.

//

// Supported Date Formats:

//   - "10-Jan-2026" / "10-JAN-2026" (DD-Mon-YYYY)

//   - "2026.01.10" (YYYY.MM.DD)

//   - "10.01.2026" or "10-01-2026" (DD.MM.YYYY / DD-MM-YYYY)

//====================================================================



input group "===== SPECIFIC TRADING DATES ONLY =====";

input bool   EnableAllowedDatesOnly = false;         // Enable Specific Trading Dates Only filter (true/false)

input string AllowedTradingDates    = "10-Jan-2026"; // Comma-separated allowed dates (Format: "10-Jan-2026")



//+------------------------------------------------------------------+

//| ROBUST DATE MATCHING HELPER                                      |

//+------------------------------------------------------------------+



bool MatchSingleDate(datetime time, string target) {

  StringTrimLeft(target);

  StringTrimRight(target);

  if (target == "") return false;



  MqlDateTime dt;

  TimeToStruct(time, dt);



  string monthsShort[12] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", 

                            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

  string monthsFull[12]  = {"January", "February", "March", "April", "May", "June",

                            "July", "August", "September", "October", "November", "December"};



  string dShort2 = StringFormat("%02d-%s-%04d", dt.day, monthsShort[dt.mon - 1], dt.year); // "29-Jan-2026"

  string dShort1 = StringFormat("%d-%s-%04d", dt.day, monthsShort[dt.mon - 1], dt.year);   // "29-Jan-2026" or "5-Jan-2026"

  string dSpace2 = StringFormat("%02d %s %04d", dt.day, monthsShort[dt.mon - 1], dt.year); // "29 Jan 2026"

  string dSpace1 = StringFormat("%d %s %04d", dt.day, monthsShort[dt.mon - 1], dt.year);   // "5 Jan 2026"



  string dFull2  = StringFormat("%02d-%s-%04d", dt.day, monthsFull[dt.mon - 1], dt.year);  // "29-January-2026"

  string dFull1  = StringFormat("%d-%s-%04d", dt.day, monthsFull[dt.mon - 1], dt.year);   // "5-January-2026"

  string dFullSp2 = StringFormat("%02d %s %04d", dt.day, monthsFull[dt.mon - 1], dt.year); // "29 January 2026"

  string dFullSp1 = StringFormat("%d %s %04d", dt.day, monthsFull[dt.mon - 1], dt.year);   // "5 January 2026"



  string dMT5_dot   = StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day); // "2026.01.29"

  string dMT5_dash  = StringFormat("%04d-%02d-%02d", dt.year, dt.mon, dt.day); // "2026-01-29"

  string dMT5_slash = StringFormat("%04d/%02d/%02d", dt.year, dt.mon, dt.day); // "2026/01/29"



  string dDMY_dot   = StringFormat("%02d.%02d.%04d", dt.day, dt.mon, dt.year); // "29.01.2026"

  string dDMY_dash  = StringFormat("%02d-%02d-%04d", dt.day, dt.mon, dt.year); // "29-01-2026"

  string dDMY_slash = StringFormat("%02d/%02d/%04d", dt.day, dt.mon, dt.year); // "29/01/2026"

  string dDMY_dot1  = StringFormat("%d.%d.%04d", dt.day, dt.mon, dt.year);     // "5.1.2026"

  string dDMY_dash1 = StringFormat("%d-%d-%04d", dt.day, dt.mon, dt.year);     // "5-1-2026"

  string dDMY_slash1= StringFormat("%d/%d/%04d", dt.day, dt.mon, dt.year);     // "5/1/2026"



  StringToUpper(dShort2);

  StringToUpper(dShort1);

  StringToUpper(dSpace2);

  StringToUpper(dSpace1);

  StringToUpper(dFull2);

  StringToUpper(dFull1);

  StringToUpper(dFullSp2);

  StringToUpper(dFullSp1);



  string targetUpper = target;

  StringToUpper(targetUpper);



  return (targetUpper == dShort2 || targetUpper == dShort1 || 

          targetUpper == dSpace2 || targetUpper == dSpace1 ||

          targetUpper == dFull2  || targetUpper == dFull1  ||

          targetUpper == dFullSp2|| targetUpper == dFullSp1||

          target == dMT5_dot     || target == dMT5_dash    || target == dMT5_slash ||

          target == dDMY_dot     || target == dDMY_dash    || target == dDMY_slash ||

          target == dDMY_dot1    || target == dDMY_dash1   || target == dDMY_slash1);

}



bool MatchDateList(datetime time, const string &list[], int count) {

  for (int i = 0; i < count; i++) {

    if (MatchSingleDate(time, list[i])) return true;

  }

  return false;

}



bool MatchDateString(datetime time, string rawInput) {

  if (rawInput == "") return false;

  StringReplace(rawInput, ";", ",");

  StringReplace(rawInput, "|", ",");

  

  string tokens[];

  ushort u_sep = StringGetCharacter(",", 0);

  int count = StringSplit(rawInput, u_sep, tokens);

  if (count <= 0) {

    return MatchSingleDate(time, rawInput);

  }

  for (int i = 0; i < count; i++) {

    if (MatchSingleDate(time, tokens[i])) return true;

  }

  return false;

}



//+------------------------------------------------------------------+

//| CHECK IF CURRENT DATE IS IN THE ALLOWED TRADING DATES LIST       |

//+------------------------------------------------------------------+



datetime g_LastDateAllowedCheckTime = 0;

bool     g_LastDateAllowedResult    = true;

datetime g_LastDateSkippedCheckTime = 0;

bool     g_LastDateSkippedResult    = false;



bool IsDateAllowed(datetime time = 0) {

  if (!EnableAllowedDatesOnly)

    return true; // Filter disabled -> All trading days allowed



  datetime t1 = (time == 0 ? TimeCurrent() : time);

  if (time == 0 && g_LastDateAllowedCheckTime > 0 && (t1 / 86400) == (g_LastDateAllowedCheckTime / 86400))

    return g_LastDateAllowedResult;



  datetime t2 = (time == 0 ? GetSessionCurrentTime() : time);

  bool res = false;



  // 1. Check AllowedTradingDates input property

  if (MatchDateString(t1, AllowedTradingDates) || MatchDateString(t2, AllowedTradingDates))

    res = true;

  else {

    // 2. Check optional hardcoded allowed dates array

    string allowedDatesList[] = {

          "20-Jan-2026","07-Jan-2026","26-Jan-2026","28-Jan-2026", "27-Jan-2029","29-Jan-2026","30-Jan-2026","02-Feb-2026","03-Feb-2023", "23-Mar-2026","30-Mar-2026","31-Mar-2026", "05-June-2026","18-June-2026", "18-Jun-2026","05-Aug-2026"

    };



    if (MatchDateList(t1, allowedDatesList, ArraySize(allowedDatesList)) || MatchDateList(t2, allowedDatesList, ArraySize(allowedDatesList)))

      res = true;

  }



  if (time == 0) {

    g_LastDateAllowedCheckTime = t1;

    g_LastDateAllowedResult = res;

  }



  return res;

}



//====================================================================

// SKIP TRADING DATES FILTER

//

// Hardcode dates where trading and backtesting should be skipped.

// On these dates, no initial orders or new cycles will be opened.

//

// Supported Date Formats:

//   - "12-Jan-2026" / "12-JAN-2026" / "12-jan-2026" (DD-Mon-YYYY)

//   - "2026.01.12" (YYYY.MM.DD)

//   - "12.01.2026" or "12-01-2026" (DD.MM.YYYY / DD-MM-YYYY)

//====================================================================



input group "===== SKIP TRADING DATES =====";

input bool   EnableSkipDatesFilter = true;          // Enable Skip Trading Dates filter (true/false)

input string SkipTradingDates      = "";            // Optional: Comma-separated skip dates from inputs dialog



bool IsDateSkipped(datetime time = 0) {

  if (!EnableSkipDatesFilter)

    return false; // Filter disabled -> Do not skip any dates



  datetime t1 = (time == 0 ? TimeCurrent() : time);

  if (time == 0 && g_LastDateSkippedCheckTime > 0 && (t1 / 86400) == (g_LastDateSkippedCheckTime / 86400))

    return g_LastDateSkippedResult;



  datetime t2 = (time == 0 ? GetSessionCurrentTime() : time);

  bool res = false;



  // Hardcoded skip dates array

  string skipDates[] = {

   };



  if (MatchDateList(t1, skipDates, ArraySize(skipDates)) || MatchDateList(t2, skipDates, ArraySize(skipDates)))

    res = true;

  else if (MatchDateString(t1, SkipTradingDates) || MatchDateString(t2, SkipTradingDates))

    res = true;



  if (time == 0) {

    g_LastDateSkippedCheckTime = t1;

    g_LastDateSkippedResult = res;

  }



  return res;

}



string GetCurrentFormattedDate(datetime time = 0) {

  if (time == 0)

    time = TimeCurrent();



  MqlDateTime dt;

  TimeToStruct(time, dt);



  string monthsShort[12] = {"Jan", "Feb", "Mar", "Apr", "May", "Jun", 

                            "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"};

  return StringFormat("%02d-%s-%04d", dt.day, monthsShort[dt.mon - 1], dt.year);

}



bool IsFridayTradingBlocked();

bool IsFridayRolloverActive();

bool CheckFridayBasketProtection(ENUM_POSITION_TYPE direction, int positions);

double GetHedgeLots();

double GetPipValueInPrice();

double PipsToPriceDistance(double pips);

bool ShouldResetPendingOrders();

void InitSessionTimeCaches();

void RecordPositionClose();

bool IsPostCloseDelayActive();

double GetActiveBasketTP(int positions = -1, ENUM_POSITION_TYPE direction = (ENUM_POSITION_TYPE)-1);

bool CheckMaxPositionsClose(ENUM_POSITION_TYPE direction, int positions);

datetime GetStartOfNextDay(datetime time = 0);

bool IsMaxPosCloseDayBlocked();

bool IsMarketTradeable();

bool CloseBasket();

bool CloseAllHedgePositions();

double GetGridFloatingProfit();

bool IsPriceNear24HHigh(double price, double thresholdPct, int lookbackHours);

bool IsPriceNear24HLow(double price, double thresholdPct, int lookbackHours);

double GetCompoundedInitialLot();

double GetActiveSessionLotMultiplier();

double GetMacroLotMultiplier(ENUM_POSITION_TYPE direction);

double GetMacroDistanceMultiplier(ENUM_POSITION_TYPE direction);

double GetEffectiveInitialLot(ENUM_POSITION_TYPE direction);

void ManageLevel1TrendRunner(ENUM_POSITION_TYPE direction, int positions = -1);

void UpdateBasketTP(ENUM_POSITION_TYPE direction, int positions = -1);

void ManageMartingale(ENUM_POSITION_TYPE direction, int tradeCount = -1);

void CheckAndLogDrawdown(ENUM_POSITION_TYPE direction, int openPositions = -1);



//+------------------------------------------------------------------+

//| POST-CLOSE DELAY HELPER FUNCTIONS                                |

//+------------------------------------------------------------------+



void RecordPositionClose() {

  LastPositionCloseTime      = TimeCurrent();

  LastPositionCloseTickCount = GetTickCount64();

}



bool IsPostCloseDelayActive() {

  if (PostCloseDelaySec <= 0)

    return false;



  if (LastPositionCloseTime <= 0)

    return false;



  if (MQLInfoInteger(MQL_TESTER)) {

    if (TimeCurrent() < LastPositionCloseTime + PostCloseDelaySec)

      return true;

  } else {

    if (TimeCurrent() < LastPositionCloseTime + PostCloseDelaySec)

      return true;

    if (LastPositionCloseTickCount > 0 && (GetTickCount64() - LastPositionCloseTickCount < (ulong)(PostCloseDelaySec * 1000)))

      return true;

  }



  return false;

}



//+------------------------------------------------------------------+

//| MAX POSITIONS DAY PAUSE HELPER FUNCTIONS                         |

//+------------------------------------------------------------------+



datetime GetStartOfNextDay(datetime time = 0) {

  if (time == 0)

    time = TimeCurrent();

  MqlDateTime dt;

  TimeToStruct(time, dt);

  dt.hour = 0;

  dt.min  = 0;

  dt.sec  = 0;

  datetime midnightToday = StructToTime(dt);

  return midnightToday + 86400; // 00:00:00 of tomorrow

}



bool IsMaxPosCloseDayBlocked() {

  if (!PauseRestOfDayOnMaxPosClose)

    return false;

  return (TimeCurrent() < MaxPosCloseResumeTime);

}





bool IsMarketTradeable() {

  ENUM_SYMBOL_TRADE_MODE tradeMode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(_Symbol, SYMBOL_TRADE_MODE);

  if (tradeMode != SYMBOL_TRADE_MODE_FULL)

    return false;



  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  if (bid <= 0.0 || ask <= 0.0 || bid >= ask)

    return false;



  return true;

}



//+------------------------------------------------------------------+

//| ON INIT                                                          |

//+------------------------------------------------------------------+



//+------------------------------------------------------------------+

//| DETECT & APPLY BROKER-SUPPORTED FILLING MODE                     |

//+------------------------------------------------------------------+



void SetBestFillingMode(CTrade &tr) {

  uint filling = (uint)SymbolInfoInteger(_Symbol, SYMBOL_FILLING_MODE);

  if ((filling & SYMBOL_FILLING_FOK) != 0) {

    tr.SetTypeFilling(ORDER_FILLING_FOK);

  } else if ((filling & SYMBOL_FILLING_IOC) != 0) {

    tr.SetTypeFilling(ORDER_FILLING_IOC);

  } else {

    tr.SetTypeFilling(ORDER_FILLING_RETURN);

  }

}



//+------------------------------------------------------------------+

//| INITIALIZATION                                                   |

//+------------------------------------------------------------------+



int OnInit() {

  InitSessionTimeCaches();

  LoadOfflineNewsCSV();



  trade.SetExpertMagicNumber(MagicNumber);

  SetBestFillingMode(trade);

  trade.SetDeviationInPoints(50);



  hedgeTrade.SetExpertMagicNumber(ADXHedgeMagicNumber);

  SetBestFillingMode(hedgeTrade);

  hedgeTrade.SetDeviationInPoints(50);



  if (UseATRDistanceScaling) {

    ATRHandle = iATR(_Symbol, ATR_Timeframe, ATR_Period);



    if (ATRHandle == INVALID_HANDLE) {

      Print("[ATR ERROR] Failed to create ATR indicator handle. Distance "

            "scaling will fall back to ratio 1.0 until it recovers.");

    }

  }



  BaselineATR = 0.0; // (re)captured on the next StartNewCycle()





  //==================================================================

  // DIRECTIONAL PREDICTION / TREND FILTER INDICATOR HANDLES

  //==================================================================



  if (EnableDirectionalPrediction) {

    hPredFastMA = iMA(_Symbol, PredictionTimeframe, PredictionFastMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

    hPredSlowMA = iMA(_Symbol, PredictionTimeframe, PredictionSlowMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

    hPredRSI    = iRSI(_Symbol, PredictionTimeframe, PredictionRSIPeriod, PRICE_CLOSE);

    hPredADX    = iADX(_Symbol, PredictionTimeframe, PredictionADXPeriod);



    if (hPredFastMA == INVALID_HANDLE || hPredSlowMA == INVALID_HANDLE ||

        hPredRSI == INVALID_HANDLE || hPredADX == INVALID_HANDLE) {

      Print("[PREDICTION ERROR] Failed to create one or more prediction indicator handles. Prediction will default to SIDEWAYS until they recover.");

    }

  }



  if (EnableTrendFilter) {

    hTrendMA  = iMA(_Symbol, TrendFilterTimeframe, TrendFilterMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

    hTrendADX = iADX(_Symbol, TrendFilterTimeframe, PredictionADXPeriod);



    if (hTrendMA == INVALID_HANDLE || hTrendADX == INVALID_HANDLE) {

      Print("[TREND FILTER ERROR] Failed to create trend filter indicator handles. Trend filter will default to NONE until they recover.");

    }

  }



  if (EnableMacroTrendFilter) {

    hMacroMA = iMA(_Symbol, MacroTrendTimeframe, MacroTrendMAPeriod, 0, MODE_EMA, PRICE_CLOSE);

    if (hMacroMA == INVALID_HANDLE) {

      Print("[MACRO TREND ERROR] Failed to create Macro H4 MA indicator handle. Filter will default to NONE.");

    }

  }



  Print("==========================================");

  Print("XAUUSD MARTINGALE EA STARTED");

  Print("==========================================");



  Print("Symbol            : ", _Symbol);

  Print("Daily Deposit     : $", DoubleToString(DailyDeposit, 2));

  Print("Initial Lot       : ", InitialLot);

  Print("Initial Distance  : ", InitialDistance);

  Print("Initial TP (Pips) : ", InitialTPPips, " (", DoubleToString(PipsToPriceDistance(InitialTPPips), 2), " price units)");

  Print("Post-Close Delay  : ", PostCloseDelaySec, " seconds");

  Print("Multiplier        : ", Multiplier);

  Print("Session Dist Mult : ");

  Print("  Session 1 Mult  : ", Session1DistanceMultiplier, " (", EnableSession1 ? "Active" : "Disabled", ")");

  Print("  Session 2 Mult  : ", Session2DistanceMultiplier, " (", EnableSession2 ? "Active" : "Disabled", ")");

  Print("  Session 3 Mult  : ", Session3DistanceMultiplier, " (", EnableSession3 ? "Active" : "Disabled", ")");

  Print("  Session 4 Mult  : ", Session4DistanceMultiplier, " (", EnableSession4 ? "Active" : "Disabled", ")");

  Print("  Session 5 Mult  : ", Session5DistanceMultiplier, " (", EnableSession5 ? "Active" : "Disabled", ")");

  Print("Basket TP         : ", BasketTP);

  if (EnableStepBasketTP) {

    Print("Step Basket TP    : Enabled (Grid Level >= ", StepBasketTPGridLevel, " -> TP: ", StepBasketTP, ")");

  } else {

    Print("Step Basket TP    : Disabled");

  }

  Print("Swap/Comm TP Comp : ", InpCompensateSwapAndCommission ? "Enabled" : "Disabled");

  Print("Ensure Net Profit : ", InpEnsureNetProfitOnTP ? ("Enabled (Min: $" + DoubleToString(InpMinNetProfitOnTP, 2) + ")") : "Disabled");

  Print("Maximum Trades    : ", MaximumTrades);

  Print("Maximum Lot       : ", MaximumLot);



  Print("------------------------------------------");

  Print("ATR DISTANCE SCALING");

  Print("Enabled           : ", UseATRDistanceScaling);

  Print("ATR Period        : ", ATR_Period);

  Print("ATR Timeframe     : ", EnumToString(ATR_Timeframe));

  Print("Ratio Clamp       : [", ATR_MinRatio, ", ", ATR_MaxRatio, "]");



  Print("------------------------------------------");

  Print("ADX HEDGE SETTINGS");

  Print("Enabled           : ", EnableADXHedge);

  if (EnableADXHedge) {

    hADX_Hedge = iADX(_Symbol, ADXHedgeTimeframe, ADXHedgePeriod);

    if (hADX_Hedge == INVALID_HANDLE) {

      Print("[ADX HEDGE ERROR] Failed to create ADX Hedge indicator handle.");

    }

    Print("ADX Threshold     : ", ADXHedgeThreshold);

    Print("ADX Period        : ", ADXHedgePeriod);

    Print("ADX Timeframe     : ", EnumToString(ADXHedgeTimeframe));

    Print("Lot Multiplier    : ", DoubleToString(ADXHedgeLotMultiplier, 2), "x");

    Print("Hedge Magic       : ", ADXHedgeMagicNumber);

    Print("Affects Basket TP : ", ADXHedgeAffectsBasketTP);

  }



  Print("------------------------------------------");

  Print("SESSION TIME FILTERS (AUTO GMT)");

  Print("Auto Adapt GMT    : ", AutoAdaptSessionGMT);

  Print("Base GMT Offset   : GMT+", SessionsBaseGMT);

  int detectedBrokerGmt = (int)MathRound((double)(TimeCurrent() - TimeGMT()) / 3600.0);

  Print("Broker Server GMT : GMT+", detectedBrokerGmt);

  Print("Session Clock     : ", TimeToString(GetSessionCurrentTime(), TIME_DATE | TIME_MINUTES));



  Print("------------------------------------------");

  Print("DRAWDOWN CONTROL (BASKET SL)");

  Print("Enabled           : ", EnableDDControl);

  if (EnableDDControl) {

    Print("Daily Deposit     : $", DoubleToString(DailyDeposit, 2));

    if (DDControlMode == DD_CONTROL_PERCENT)

      Print("Mode              : Option 1 (% Drawdown: ", MaxDrawdownPct, "% of $", DoubleToString(DailyDeposit > 0 ? DailyDeposit : AccountInfoDouble(ACCOUNT_BALANCE), 2), ")");

    else if (DDControlMode == DD_CONTROL_MONEY)

      Print("Mode              : Option 2 (Max Money: $", MaxDrawdownMoney, ")");

    else if (DDControlMode == DD_CONTROL_DISTANCE)

      Print("Mode              : Option 3 (Price Distance: ", BasketStopLoss, ")");

    Print("Pause Duration    : ", DDPauseHours, " hours");

  }



  Print("------------------------------------------");

  Print("DRAWDOWN LOGGING (THRESHOLD MONITOR)");

  Print("Enabled           : ", EnableDDLogging);

  if (EnableDDLogging) {

    Print("Threshold         : $", DoubleToString(DDLogThreshold, 2));

    Print("Log to CSV File   : ", WriteDDLogToFile ? ("YES (" + DDLogFileName + ")") : "NO");

    if (WriteDDLogToFile) {

      SaveFullDDLogToCSV();

      Print("Log Path (Common) : C:\\Users\\bJaya\\AppData\\Roaming\\MetaQuotes\\Terminal\\Common\\Files\\", (DDLogFileName != "" ? DDLogFileName : "DD_50000_Log.csv"));

    }

  }



  Print("------------------------------------------");

  Print("BASKET MAX DURATION (TIME-OUT)");

  Print("Enabled           : ", EnableMaxGridDuration);

  if (EnableMaxGridDuration) {

    Print("Max Duration      : ", DoubleToString(MaxGridDurationHours, 2), " hours");

  }



  Print("------------------------------------------");

  Print("SPECIFIC TRADING DATES FILTER");

  Print("Enabled           : ", EnableAllowedDatesOnly);

  if (EnableAllowedDatesOnly) {

    Print("Allowed Dates     : ", AllowedTradingDates);

    if (IsDateAllowed()) {

      Print("Today's Status    : ALLOWED (Trading enabled today: ", GetCurrentFormattedDate(), ")");

    } else {

      Print("Today's Status    : BLOCKED (Today is NOT in the allowed list: ", GetCurrentFormattedDate(), ")");

    }

  }



  Print("------------------------------------------");

  Print("SKIP TRADING DATES FILTER");

  Print("Enabled           : ", EnableSkipDatesFilter);

  if (EnableSkipDatesFilter) {

    if (IsDateSkipped()) {

      Print("Status            : ACTIVE (Today is configured as a SKIPPED TRADING DATE: ", GetCurrentFormattedDate(), ")");

    } else {

      Print("Status            : Clear (Trading allowed today: ", GetCurrentFormattedDate(), ")");

    }

  } else {

    Print("Status            : DISABLED (Skip dates filter is turned off)");

  }



  Print("------------------------------------------");

  Print("FRIDAY TRADING FILTER");

  Print("Enabled           : ", EnableFridayFilter);

  if (EnableFridayFilter) {

    Print("Friday Cutoff     : ", FridayCutoffTime, " (No new cycles opened after this time on Fridays)");

    if (IsFridayTradingBlocked()) {

      Print("Today's Status    : BLOCKED (Friday after ", FridayCutoffTime, ")");

    } else {

      Print("Today's Status    : Clear");

    }

  }



  Print("------------------------------------------");

  Print("FRIDAY ROLLOVER BASKET PROTECTION (LEVEL 8+)");

  Print("Enabled           : ", EnableFridayBasketRule);

  if (EnableFridayBasketRule) {

    Print("Trigger Time      : Friday at ", FridayBasketActionTime, " server time");

    Print("Min Grid Level    : ", FridayBasketMinLevel);

    Print("Action            : ", (FridayBasketAction == FRIDAY_ACTION_CLOSE_MARKET ? "CLOSE BASKET AT CURRENT MARKET PRICE" : "LOCK 100% HEDGE (DELTA NEUTRAL)"));

    if (FridayBasketAction == FRIDAY_ACTION_LOCK_100_HEDGE) {

      Print("Monday Unfreeze   : ", FridayHedgeCloseOnMonday ? ("YES (at " + MondayHedgeUnfreezeTime + " server time)") : "NO");

    }

  }





  Print("------------------------------------------");

  Print("NEWS FILTER SETTINGS");

  Print("Enabled           : ", InpEnableNewsFilter);

  Print("Offline CSV Mode  : ", InpUseOfflineNewsCSV ? ("Enabled ('" + InpNewsCSVFileName + "', " + IntegerToString(OfflineNewsCount) + " events loaded)") : "Disabled");

  Print("Currencies        : ", InpNewsCurrencies);

  Print("High Impact Only  : ", InpNewsFilterHighOnly);

  Print("GMT Mode          : ",

        InpNewsGmtMode == 0 ? "Trust calendar server time" : "Manual offset");

  Print("GMT Offset (hrs)  : ", InpNewsGmtOffset);

  Print("Before (min)      : ", InpNewsBeforeMinutes);

  Print("After (min)       : ", InpNewsAfterMinutes);

  Print("Block Grid Adds   : ", InpBlockGridDuringNews);

  Print("Source            : ", (InpUseOfflineNewsCSV && OfflineNewsCount > 0) ? "Offline CSV File" : "LIVE MT5 Economic Calendar");



  Print("------------------------------------------");

  Print("INITIAL PROFIT TARGET");

  Print("Initial TP (pips) : ", InitialTPPips, " (", DoubleToString(PipsToPriceDistance(InitialTPPips), 2), " price units)");



  Print("------------------------------------------");

  Print("PENDING ORDER RESET");

  Print("Enabled           : ", EnablePendingOrderReset);

  if (EnablePendingOrderReset) {

    Print("Reset Distance    : ", PendingResetDistancePips, " pips (", DoubleToString(PipsToPriceDistance(PendingResetDistancePips), 2), " price units)");

  }



  Print("------------------------------------------");

  Print("GRID LIMIT CONTROL");

  Print("Hard Grid Cap     : ", EnableHardGridCap, (EnableHardGridCap ? (" (" + IntegerToString(MaxGridLevelsHardCap) + " levels)") : ""));

  Print("Max Pos Auto-Close: ", EnableMaxPositionsClose, (EnableMaxPositionsClose ? (" (Close basket at " + IntegerToString(MaxPositionsToClose) + " positions)") : ""));

  Print("Pause Rest of Day : ", PauseRestOfDayOnMaxPosClose, (PauseRestOfDayOnMaxPosClose ? " (No new trades for the rest of the day after Max Pos close)" : ""));



  Print("------------------------------------------");

  Print("DIRECTIONAL PREDICTION MODEL");

  Print("Enabled           : ", EnableDirectionalPrediction);

  if (EnableDirectionalPrediction) {

    Print("Timeframe         : ", EnumToString(PredictionTimeframe));

    Print("MA Fast/Slow      : ", PredictionFastMAPeriod, " / ", PredictionSlowMAPeriod);

    Print("RSI Period        : ", PredictionRSIPeriod, " (OB ", PredictionRSIOverbought, " / OS ", PredictionRSIOversold, ")");

    Print("ADX Trend Thresh  : ", PredictionADXTrendThreshold);

    Print("Both On Sideways  : ", OnlyTradeBothWhenSideways);

  }



  Print("------------------------------------------");

  Print("SUPPORT / RESISTANCE ZONE FILTER");

  Print("Enabled           : ", EnableSRFilter);

  if (EnableSRFilter) {

    Print("Timeframe         : ", EnumToString(SRTimeframe));

    Print("Lookback Bars     : ", SRLookbackBars);

    Print("Zone Buffer (pips): ", SRZoneBufferPips);

    Print("Min Touches       : ", SRMinTouches);

  }



  Print("------------------------------------------");

  Print("TREND FILTER");

  Print("Enabled           : ", EnableTrendFilter);

  if (EnableTrendFilter) {

    Print("Timeframe         : ", EnumToString(TrendFilterTimeframe));

    Print("MA Period         : ", TrendFilterMAPeriod);

    Print("ADX Threshold     : ", TrendFilterADXThreshold);

  }



  Print("------------------------------------------");

  Print("MACRO H4 TREND FILTER");

  Print("Enabled           : ", EnableMacroTrendFilter);

  if (EnableMacroTrendFilter) {

    Print("Timeframe         : ", EnumToString(MacroTrendTimeframe));

    Print("MA Period         : ", MacroTrendMAPeriod, " EMA");

    Print("Mode              : ", MacroCounterTrendMode == COUNTER_TREND_CAP_GRID ? ("Cap Counter-Trend Grid @ L" + IntegerToString(MacroCounterTrendMaxGrid)) : "Disable Counter-Trend completely");

    Print("With-Trend Max    : ", MacroWithTrendMaxGrid, " levels");

    Print("Counter-Trend Max : ", MacroCounterTrendMaxGrid, " levels");

  }



  Print("------------------------------------------");

  Print("PREDICTION / OUTCOME LOG");

  Print("Enabled           : ", EnablePredictionLog);

  if (EnablePredictionLog) {

    Print("Log File          : ", PredictionLogFileName);

  }



  PrintBrokerStops();



  return (INIT_SUCCEEDED);

}



//+------------------------------------------------------------------+

//| ON DEINIT                                                        |

//+------------------------------------------------------------------+



void OnDeinit(const int reason) {

  if (ATRHandle != INVALID_HANDLE) {

    IndicatorRelease(ATRHandle);

    ATRHandle = INVALID_HANDLE;

  }



  if (hADX_Hedge != INVALID_HANDLE) {

    IndicatorRelease(hADX_Hedge);

    hADX_Hedge = INVALID_HANDLE;

  }



  if (hPredFastMA != INVALID_HANDLE) { IndicatorRelease(hPredFastMA); hPredFastMA = INVALID_HANDLE; }

  if (hPredSlowMA != INVALID_HANDLE) { IndicatorRelease(hPredSlowMA); hPredSlowMA = INVALID_HANDLE; }

  if (hPredRSI    != INVALID_HANDLE) { IndicatorRelease(hPredRSI);    hPredRSI    = INVALID_HANDLE; }

  if (hPredADX    != INVALID_HANDLE) { IndicatorRelease(hPredADX);    hPredADX    = INVALID_HANDLE; }

  if (hTrendMA    != INVALID_HANDLE) { IndicatorRelease(hTrendMA);    hTrendMA    = INVALID_HANDLE; }

  if (hTrendADX   != INVALID_HANDLE) { IndicatorRelease(hTrendADX);   hTrendADX   = INVALID_HANDLE; }

  if (hMacroMA    != INVALID_HANDLE) { IndicatorRelease(hMacroMA);    hMacroMA    = INVALID_HANDLE; }



  if (EnablePredictionLog) {

    SavePredictionLogToCSV();

  }



  if (EnableDDLogging) {

    PrintDDSummaryReport();

  }



  if (!MQLInfoInteger(MQL_TESTER)) {

    Comment("");

  }

}



//+------------------------------------------------------------------+

//| ON TICK                                                          |

//+------------------------------------------------------------------+



void OnTick() {

  // On-chart HUD display: disabled during backtests for maximum testing speed

  if (EnableChartDisplay && !MQLInfoInteger(MQL_TESTER)) {

    UpdateChartDisplay();

  }



  int positions = CountPositions();

  int pending = CountPendingOrders();



  // Track overall maximum drawdown observed across the entire backtest / session (only when positions exist)

  if (EnableDDLogging && positions > 0) {

    double basketFloating = GetTotalFloatingProfit();

    double equityDD = MathMax(0.0, AccountInfoDouble(ACCOUNT_BALANCE) - AccountInfoDouble(ACCOUNT_EQUITY));

    double currentDD = MathMax(equityDD, (basketFloating < 0 ? MathAbs(basketFloating) : 0.0));

    if (currentDD > OverallMaxDDObserved) {

      OverallMaxDDObserved = currentDD;

    }

  }



  //================================================================

  // ACTIVE BASKET

  //================================================================



  if (positions > 0) {

    if (!CycleWasActive) {

      DDThresholdLoggedThisCycle = false;

      CurrentCycleMaxDD = 0.0;

    }

    CycleWasActive = true;



    // Track the highest grid level reached this cycle (used for the

    // "first time win" metric in the prediction log), independent of

    // whether ManageMartingale gets called this tick.

    if (positions > CycleMaxGridLevel) {

      CycleMaxGridLevel = positions;

    }



    ENUM_POSITION_TYPE direction = GetBasketDirection();



    // Level 1 Trend-Runner & CycleBaseLot capture

    if (positions == 1) {

      if (CycleBaseLot <= 0.0) {

        for (int pIdx = PositionsTotal() - 1; pIdx >= 0; pIdx--) {

          if (PositionGetTicket(pIdx) > 0 && PositionGetString(POSITION_SYMBOL) == _Symbol &&

              (ulong)PositionGetInteger(POSITION_MAGIC) == MagicNumber) {

            CycleBaseLot = PositionGetDouble(POSITION_VOLUME);

            break;

          }

        }

      }

      ManageLevel1TrendRunner(direction, positions);

    }



    // Check & Log Drawdown if threshold (e.g. $50,000) is reached

    if (EnableDDLogging) {

      CheckAndLogDrawdown(direction, positions);

    }



    // Cancel opposite pending orders immediately (only if pending orders exist)

    if (pending > 0) {

      DeleteOppositePendingOrders(direction);

    }



    // ADX Hedge: open opposite positions on strong trend moves.

    // Runs BEFORE UpdateBasketTP so the TP reflects the latest hedge state.

    ManageADXHedge(direction);



    // Update basket TP (virtual - EA managed, see CheckBasketTP)

    UpdateBasketTP(direction, positions);



    // Check if the virtual basket TP has been reached. If so, the hedge

    // is closed FIRST and the grid basket SECOND, and we stop processing

    // this tick since the basket no longer exists.

    if (CheckBasketTP(direction)) {

      return;

    }



    // Drawdown Control / Basket SL

    if (EnableDDControl) {

      if (CheckDrawdownControl(direction)) {

        return;

      }

    }



    // Basket Max Duration Timeout Exit

    if (EnableMaxGridDuration) {

      if (CheckBasketMaxDuration(direction)) {

        return;

      }

    }



    // Auto-Close Grid when Max Positions Reached

    if (EnableMaxPositionsClose) {

      if (CheckMaxPositionsClose(direction, positions)) {

        return;

      }

    }



    // Friday Rollover Basket Protection (Level 8+ Rule: Close or 100% Hedge before weekend)

    if (EnableFridayBasketRule) {

      if (CheckFridayBasketProtection(direction, positions)) {

        return;

      }

    }





    //=============================================================

    // IMPORTANT

    //

    // NO SESSION CHECK HERE.

    //

    // Existing martingale continues after session expiry.

    //=============================================================



    // Only attempt to place new grid orders if no pending order is already resting

    if (pending == 0) {

      ManageMartingale(direction, positions);

    }



    return;

  }



  //================================================================

  // BASKET JUST CLOSED

  //================================================================



  if (CycleWasActive && positions == 0) {

    Print("==========================================");

    Print("BASKET CLOSED");

    Print("Waiting for next valid session...");

    Print("==========================================");



    DeleteAllPendingOrders();



    // Safety net: close any ADX hedge left open and reset tracking.

    CloseAllHedgePositions();

    ADXHedgeOpenedThisCycle = false;

    FridayHedgeLockedThisCycle = false;



    VirtualBasketTP = 0.0;

    CycleSessionMultiplier = 0.0;

    CycleBaseLot = 0.0;

    Level1PartialClosedThisCycle = false;

    CycleWasActive = false;

    RecordPositionClose();

    LogPredictionOutcome("Closed / Expired");

    if (EnableDDLogging) {

      OnBasketCycleClosed("Closed / Expired");

    } else {

      DDThresholdLoggedThisCycle = false;

      CurrentCycleMaxDD = 0.0;

    }



    // New cycle only inside session AND outside a news blackout AND outside DD pause AND outside Max Pos Day Pause AND not on skipped dates AND on allowed dates AND not blocked on Friday AND after post-close delay

    if (TimeCurrent() >= DDResumeTime && !IsMaxPosCloseDayBlocked() && IsInsideAnySession() && !IsHighImpactNewsWindow() && !IsDateSkipped() && !IsFridayTradingBlocked() && IsDateAllowed() && !IsPostCloseDelayActive()) {

      StartNewCycle();

    }



    return;

  }



  //================================================================

  // NO ACTIVE BASKET (POSITIONS == 0)

  //================================================================



  if (positions == 0) {

    // Safety check: ensure any leftover hedge positions are completely closed before starting a new cycle

    if (CountHedgePositions() > 0) {

      CloseAllHedgePositions();

      return;

    }



    // If outside session or news blackout or friday cutoff or skipped date or max pos day pause, purge any leftover pending orders

    if (!IsInsideAnySession() || IsHighImpactNewsWindow() || IsFridayTradingBlocked() || IsDateSkipped() || !IsDateAllowed() || IsMaxPosCloseDayBlocked()) {

      if (pending > 0) {

        DeleteAllPendingOrders();

      }

    } else {

      // Inside active trading session

      if (TimeCurrent() >= DDResumeTime && !IsMaxPosCloseDayBlocked() && !IsPostCloseDelayActive()) {

        if (pending == 0) {

          StartNewCycle();

        } else {

          // Pending orders exist: check if market moved in other direction by configured pips

          if (ShouldResetPendingOrders()) {

            Print("==========================================");

            Print("PENDING ORDER RESET TRIGGERED: Market moved in other direction by >= ", DoubleToString(PendingResetDistancePips, 1), " pips");

            Print("Closing pending orders and resetting reference prices for new cycle...");

            Print("==========================================");

            DeleteAllPendingOrders();

            PendingOrderRefAsk = 0.0;

            PendingOrderRefBid = 0.0;

            // Allow deletion to complete cleanly; next tick will start a fresh cycle at new market prices

            return;

          }

        }

      }

    }

  }

}



//+------------------------------------------------------------------+

//| PRINT BROKER STOP INFORMATION                                    |

//+------------------------------------------------------------------+



void PrintBrokerStops() {

  long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);



  long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);



  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);



  double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);



  Print("------------------------------------------");

  Print("BROKER SYMBOL SETTINGS");

  Print("Stops Level       : ", stopsLevel);

  Print("Freeze Level      : ", freezeLevel);

  Print("Point             : ", DoubleToString(point, 8));

  Print("Tick Size         : ", DoubleToString(tickSize, 8));

  Print("Minimum Distance  : ", DoubleToString(GetMinimumStopDistance(), 8));

  Print("------------------------------------------");

}



//+------------------------------------------------------------------+

//| GET MINIMUM STOP DISTANCE                                        |

//+------------------------------------------------------------------+



double GetMinimumStopDistance() {

  long stopsLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);



  long freezeLevel = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_FREEZE_LEVEL);



  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);



  double minimum = MathMax((double)stopsLevel, (double)freezeLevel) * point;



  // Small safety buffer

  double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);



  if (tickSize <= 0)

    tickSize = point;



  minimum += tickSize;



  return minimum;

}



//+------------------------------------------------------------------+

//| GET CURRENT ATR                                                  |

//+------------------------------------------------------------------+



double GetCurrentATR() {

  if (ATRHandle == INVALID_HANDLE)

    return 0.0;



  static datetime s_lastATRBarTime = 0;

  static double   s_cachedATR = 0.0;



  datetime curBarTime = iTime(_Symbol, ATR_Timeframe, 0);

  if (curBarTime != s_lastATRBarTime || s_cachedATR <= 0.0) {

    double buffer[];

    ArraySetAsSeries(buffer, true);



    // Use the most recently completed bar's ATR (index 1) rather than

    // index 0, which is still forming and can be noisy intrabar.

    if (CopyBuffer(ATRHandle, 0, 1, 1, buffer) > 0) {

      s_cachedATR = buffer[0];

      s_lastATRBarTime = curBarTime;

    }

  }



  return s_cachedATR;

}



//+------------------------------------------------------------------+

//| GET ATR VOLATILITY RATIO (CurrentATR / BaselineATR, clamped)     |

//+------------------------------------------------------------------+



double GetATRVolatilityRatio() {

  if (!UseATRDistanceScaling)

    return 1.0;



  double currentATR = GetCurrentATR();



  // If either value is unavailable, don't distort spacing - behave

  // as if scaling were off rather than risk a divide-by-zero or a

  // wild ratio from a bad reading.

  if (currentATR <= 0 || BaselineATR <= 0)

    return 1.0;



  double ratio = currentATR / BaselineATR;



  ratio = MathMax(ATR_MinRatio, MathMin(ATR_MaxRatio, ratio));



  return ratio;

}



//+------------------------------------------------------------------+

//| NORMALIZE TO TICK SIZE                                           |

//+------------------------------------------------------------------+



double NormalizeToTickSize(double price) {

  double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);



  if (tickSize <= 0) {

    tickSize = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

  }



  if (tickSize <= 0)

    return NormalizePrice(price);



  price = MathRound(price / tickSize) * tickSize;



  return NormalizePrice(price);

}



//+------------------------------------------------------------------+

//| PREDICT DIRECTION (Buy / Sell / Sideways)                        |

//+------------------------------------------------------------------+

// Simple technical heuristic combining trend (EMA cross), momentum

// (RSI) and trend strength (ADX + DI). This is NOT a statistically

// validated model - its real-world accuracy must be checked against

// the prediction log this EA writes.



ENUM_PREDICTED_DIRECTION PredictDirection() {

  if (!EnableDirectionalPrediction)

    return PRED_SIDEWAYS;



  if (hPredFastMA == INVALID_HANDLE || hPredSlowMA == INVALID_HANDLE ||

      hPredRSI == INVALID_HANDLE || hPredADX == INVALID_HANDLE)

    return PRED_SIDEWAYS;



  static datetime s_lastPredBarTime = 0;

  static double   s_cFastMA1 = 0.0, s_cSlowMA1 = 0.0, s_cRSI1 = 0.0;

  static double   s_cADXMain1 = 0.0, s_cADXPlus1 = 0.0, s_cADXMinus1 = 0.0;

  static bool     s_predCacheValid = false;



  datetime curBarTime = iTime(_Symbol, PredictionTimeframe, 0);

  if (curBarTime != s_lastPredBarTime || !s_predCacheValid) {

    double fastMA[], slowMA[], rsi[], adxMain[], adxPlus[], adxMinus[];

    ArraySetAsSeries(fastMA, true);

    ArraySetAsSeries(slowMA, true);

    ArraySetAsSeries(rsi, true);

    ArraySetAsSeries(adxMain, true);

    ArraySetAsSeries(adxPlus, true);

    ArraySetAsSeries(adxMinus, true);



    // Copy index 1 (closed bar)

    if (CopyBuffer(hPredFastMA, 0, 1, 1, fastMA) <= 0 ||

        CopyBuffer(hPredSlowMA, 0, 1, 1, slowMA) <= 0 ||

        CopyBuffer(hPredRSI,    0, 1, 1, rsi) <= 0 ||

        CopyBuffer(hPredADX,    0, 1, 1, adxMain) <= 0 ||

        CopyBuffer(hPredADX,    1, 1, 1, adxPlus) <= 0 ||

        CopyBuffer(hPredADX,    2, 1, 1, adxMinus) <= 0) {

      s_predCacheValid = false;

      return PRED_SIDEWAYS;

    }



    s_cFastMA1   = fastMA[0];

    s_cSlowMA1   = slowMA[0];

    s_cRSI1      = rsi[0];

    s_cADXMain1  = adxMain[0];

    s_cADXPlus1  = adxPlus[0];

    s_cADXMinus1 = adxMinus[0];

    s_lastPredBarTime = curBarTime;

    s_predCacheValid  = true;

  }



  MqlTick currentTick;

  double livePrice = 0.0;

  if (SymbolInfoTick(_Symbol, currentTick) && currentTick.bid > 0) {

    livePrice = currentTick.bid;

  } else {

    livePrice = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  }



  // 1. Bar 0 Noise Fix: Evaluate trend strength on confirmed closed bar [1]

  bool trending = s_cADXMain1 >= PredictionADXTrendThreshold;



  // 2. Strict Moving Average Hierarchy: fast MA must be cleanly above/below slow MA on closed bar

  //    AND live price must confirm above/below both MAs

  bool bullishMA = (s_cFastMA1 > s_cSlowMA1) && (livePrice >= s_cFastMA1 && livePrice > s_cSlowMA1);

  bool bearishMA = (s_cFastMA1 < s_cSlowMA1) && (livePrice <= s_cFastMA1 && livePrice < s_cSlowMA1);



  // 3. Directional Movement confirmed on closed bar

  bool bullishDI = s_cADXPlus1 > s_cADXMinus1;

  bool bearishDI = s_cADXMinus1 > s_cADXPlus1;



  // 4. Exhaustion & Falling Knife Prevention: RSI must be in safe acceleration window

  bool rsiBullishSafe = (s_cRSI1 < PredictionRSIOverbought && s_cRSI1 > 35.0);

  bool rsiBearishSafe = (s_cRSI1 > PredictionRSIOversold && s_cRSI1 < 65.0);



  if (trending && bullishMA && bullishDI && rsiBullishSafe)

    return PRED_BUY;



  if (trending && bearishMA && bearishDI && rsiBearishSafe)

    return PRED_SELL;



  return PRED_SIDEWAYS;

}



//+------------------------------------------------------------------+

//| TREND FILTER: GET CURRENT TREND STATE                            |

//+------------------------------------------------------------------+



ENUM_TREND_STATE GetTrendFilterDirection() {

  if (!EnableTrendFilter)

    return TREND_NONE;



  if (hTrendMA == INVALID_HANDLE || hTrendADX == INVALID_HANDLE)

    return TREND_NONE;



  static datetime s_lastTrendBarTime = 0;

  static bool     s_cStrong = false;

  static bool     s_cBullishDI = false;

  static bool     s_cBearishDI = false;

  static double   s_cMA1 = 0.0;

  static double   s_cMA2 = 0.0;

  static bool     s_trendCacheValid = false;



  datetime curH1Time = iTime(_Symbol, TrendFilterTimeframe, 0);

  if (curH1Time != s_lastTrendBarTime || !s_trendCacheValid) {

    double maClose[], adxMain[], adxPlus[], adxMinus[];

    ArraySetAsSeries(maClose, true);

    ArraySetAsSeries(adxMain, true);

    ArraySetAsSeries(adxPlus, true);

    ArraySetAsSeries(adxMinus, true);



    if (CopyBuffer(hTrendMA,  0, 1, 2, maClose)  <= 0 ||

        CopyBuffer(hTrendADX, 0, 1, 1, adxMain)  <= 0 ||

        CopyBuffer(hTrendADX, 1, 1, 1, adxPlus)  <= 0 ||

        CopyBuffer(hTrendADX, 2, 1, 1, adxMinus) <= 0) {

      s_trendCacheValid = false;

      return TREND_NONE;

    }



    s_cStrong    = (adxMain[0] >= TrendFilterADXThreshold);

    s_cBullishDI = (adxPlus[0] > adxMinus[0]);

    s_cBearishDI = (adxMinus[0] > adxPlus[0]);

    s_cMA1       = maClose[0];

    s_cMA2       = maClose[1];

    s_lastTrendBarTime = curH1Time;

    s_trendCacheValid  = true;

  }



  // If closed bar [1] is not strong, trend is unconditionally TREND_NONE for the entire bar

  if (!s_cStrong)

    return TREND_NONE;



  double ma0[1];

  if (CopyBuffer(hTrendMA, 0, 0, 1, ma0) <= 0)

    return TREND_NONE;



  bool maRising  = (ma0[0] > s_cMA1 && s_cMA1 >= s_cMA2);

  bool maFalling = (ma0[0] < s_cMA1 && s_cMA1 <= s_cMA2);



  MqlTick currentTick;

  double price = 0.0;

  if (SymbolInfoTick(_Symbol, currentTick) && currentTick.bid > 0) {

    price = currentTick.bid;

  } else {

    price = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  }



  if (price <= 0)

    return TREND_NONE;



  if (s_cStrong && maRising && s_cBullishDI && price > ma0[0])

    return TREND_UP;



  if (s_cStrong && maFalling && s_cBearishDI && price < ma0[0])

    return TREND_DOWN;



  return TREND_NONE;

}



//+------------------------------------------------------------------+

//| MACRO TREND: GET CURRENT MACRO H4 EMA VALUE & STATE              |

//+------------------------------------------------------------------+



double GetMacroEMAValue() {

  if (hMacroMA == INVALID_HANDLE)

    return 0.0;



  static datetime s_lastMacroTime = 0;

  static double   s_cachedMacroEMA = 0.0;



  datetime curTime = TimeCurrent();

  if (curTime != s_lastMacroTime || s_cachedMacroEMA <= 0.0) {

    double maVal[];

    ArraySetAsSeries(maVal, true);

    if (CopyBuffer(hMacroMA, 0, 0, 1, maVal) > 0) {

      s_cachedMacroEMA = maVal[0];

      s_lastMacroTime  = curTime;

    }

  }



  return s_cachedMacroEMA;

}



ENUM_TREND_STATE GetMacroTrendState() {

  if (!EnableMacroTrendFilter)

    return TREND_NONE;



  double ma = GetMacroEMAValue();

  if (ma <= 0)

    return TREND_NONE;



  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  if (bid <= 0)

    return TREND_NONE;



  if (bid > ma)

    return TREND_UP;

  else if (bid < ma)

    return TREND_DOWN;



  return TREND_NONE;

}



int GetMacroAllowedGridLevels(ENUM_POSITION_TYPE direction) {

  if (!EnableMacroTrendFilter)

    return MaximumTrades;



  ENUM_TREND_STATE mTrend = GetMacroTrendState();



  if (mTrend == TREND_UP) {

    if (direction == POSITION_TYPE_BUY)

      return MacroWithTrendMaxGrid;

    else

      return MacroCounterTrendMaxGrid;

  } else if (mTrend == TREND_DOWN) {

    if (direction == POSITION_TYPE_SELL)

      return MacroWithTrendMaxGrid;

    else

      return MacroCounterTrendMaxGrid;

  }



  return MaximumTrades;

}



//+------------------------------------------------------------------+

//| SUPPORT / RESISTANCE: FIND STRONGEST ZONE NEAR A GIVEN PRICE     |

//+------------------------------------------------------------------+

// Scans SRLookbackBars bars on SRTimeframe for fractal-style swing

// highs/lows (SRSwingStrength bars confirmed on each side), clusters

// swing points within SRZoneBufferPips of each other into zones, and

// returns true if a zone touched >= SRMinTouches times sits within

// SRZoneBufferPips of refPrice. isResistance=true scans swing highs,

// false scans swing lows.



datetime g_SRLastCalcBarTime = 0;

double   g_CachedResistancePrices[];

double   g_CachedSupportPrices[];



void UpdateCachedSRZones() {

  datetime currentBarTime = iTime(_Symbol, SRTimeframe, 0);

  if (currentBarTime <= 0)

    currentBarTime = TimeCurrent();



  if (currentBarTime == g_SRLastCalcBarTime && g_SRLastCalcBarTime > 0)

    return;



  int strength = MathMax(1, SRSwingStrength);

  int barsNeeded = SRLookbackBars + (2 * strength) + 2;



  double highs[], lows[];

  ArraySetAsSeries(highs, true);

  ArraySetAsSeries(lows, true);



  int copiedH = CopyHigh(_Symbol, SRTimeframe, 0, barsNeeded, highs);

  int copiedL = CopyLow(_Symbol, SRTimeframe, 0, barsNeeded, lows);

  if (copiedH <= (2 * strength) || copiedL <= (2 * strength))

    return;



  g_SRLastCalcBarTime = currentBarTime;

  ArrayResize(g_CachedResistancePrices, 0);

  ArrayResize(g_CachedSupportPrices, 0);



  double zoneTolerance = PipsToPriceDistance(SRZoneBufferPips);

  if (zoneTolerance <= 0)

    return;



  // 1. Process Resistance (Highs)

  double resPrices[];

  int    resTouches[];

  int totalH = ArraySize(highs);

  for (int i = strength + 1; i < totalH - strength; i++) {

    bool isSwing = true;

    double pivot = highs[i];

    for (int k = 1; k <= strength; k++) {

      if (highs[i - k] > pivot || highs[i + k] > pivot) {

        isSwing = false;

        break;

      }

    }

    if (!isSwing) continue;



    int matchIdx = -1;

    for (int z = 0; z < ArraySize(resPrices); z++) {

      if (MathAbs(resPrices[z] - pivot) <= zoneTolerance) {

        matchIdx = z;

        break;

      }

    }

    if (matchIdx >= 0) {

      int t = resTouches[matchIdx];

      resPrices[matchIdx] = ((resPrices[matchIdx] * t) + pivot) / (t + 1);

      resTouches[matchIdx] = t + 1;

    } else {

      int newIdx = ArraySize(resPrices);

      ArrayResize(resPrices, newIdx + 1);

      ArrayResize(resTouches, newIdx + 1);

      resPrices[newIdx] = pivot;

      resTouches[newIdx] = 1;

    }

  }

  for (int z = 0; z < ArraySize(resPrices); z++) {

    if (resTouches[z] >= SRMinTouches) {

      int sz = ArraySize(g_CachedResistancePrices);

      ArrayResize(g_CachedResistancePrices, sz + 1);

      g_CachedResistancePrices[sz] = resPrices[z];

    }

  }



  // 2. Process Support (Lows)

  double supPrices[];

  int    supTouches[];

  int totalL = ArraySize(lows);

  for (int i = strength + 1; i < totalL - strength; i++) {

    bool isSwing = true;

    double pivot = lows[i];

    for (int k = 1; k <= strength; k++) {

      if (lows[i - k] < pivot || lows[i + k] < pivot) {

        isSwing = false;

        break;

      }

    }

    if (!isSwing) continue;



    int matchIdx = -1;

    for (int z = 0; z < ArraySize(supPrices); z++) {

      if (MathAbs(supPrices[z] - pivot) <= zoneTolerance) {

        matchIdx = z;

        break;

      }

    }

    if (matchIdx >= 0) {

      int t = supTouches[matchIdx];

      supPrices[matchIdx] = ((supPrices[matchIdx] * t) + pivot) / (t + 1);

      supTouches[matchIdx] = t + 1;

    } else {

      int newIdx = ArraySize(supPrices);

      ArrayResize(supPrices, newIdx + 1);

      ArrayResize(supTouches, newIdx + 1);

      supPrices[newIdx] = pivot;

      supTouches[newIdx] = 1;

    }

  }

  for (int z = 0; z < ArraySize(supPrices); z++) {

    if (supTouches[z] >= SRMinTouches) {

      int sz = ArraySize(g_CachedSupportPrices);

      ArrayResize(g_CachedSupportPrices, sz + 1);

      g_CachedSupportPrices[sz] = supPrices[z];

    }

  }

}



bool IsNearStrongSRZone(double refPrice, bool isResistance) {

  if (!EnableSRFilter || refPrice <= 0)

    return false;



  UpdateCachedSRZones();



  double zoneTolerance = PipsToPriceDistance(SRZoneBufferPips);

  if (zoneTolerance <= 0)

    return false;



  if (isResistance) {

    for (int z = 0; z < ArraySize(g_CachedResistancePrices); z++) {

      if (MathAbs(g_CachedResistancePrices[z] - refPrice) <= zoneTolerance)

        return true;

    }

  } else {

    for (int z = 0; z < ArraySize(g_CachedSupportPrices); z++) {

      if (MathAbs(g_CachedSupportPrices[z] - refPrice) <= zoneTolerance)

        return true;

    }

  }



  return false;

}



bool IsNearStrongResistance(double refPrice) { return IsNearStrongSRZone(refPrice, true); }

bool IsNearStrongSupport(double refPrice)    { return IsNearStrongSRZone(refPrice, false); }



//+------------------------------------------------------------------+

//| 24-HOUR RANGE BOUNDARY GUARD HELPER FUNCTIONS                    |

//+------------------------------------------------------------------+



static datetime s_last24HBarTime   = 0;

static double   s_cached24HHighest = 0.0;

static double   s_cached24HLowest  = 0.0;

static bool     s_24HCacheValid    = false;



void Update24HRangeCache(int lookbackHours) {

  if (lookbackHours <= 0)

    return;



  datetime curH1Time = iTime(_Symbol, PERIOD_H1, 0);

  if (curH1Time != s_last24HBarTime || !s_24HCacheValid) {

    double highs[];

    double lows[];

    ArraySetAsSeries(highs, true);

    ArraySetAsSeries(lows, true);



    int copiedH = CopyHigh(_Symbol, PERIOD_H1, 0, lookbackHours, highs);

    int copiedL = CopyLow(_Symbol, PERIOD_H1, 0, lookbackHours, lows);

    if (copiedH >= lookbackHours && copiedL >= lookbackHours) {

      int maxIdx = ArrayMaximum(highs, 0, lookbackHours);

      int minIdx = ArrayMinimum(lows, 0, lookbackHours);

      if (maxIdx >= 0 && minIdx >= 0) {

        s_cached24HHighest = highs[maxIdx];

        s_cached24HLowest  = lows[minIdx];

        s_last24HBarTime   = curH1Time;

        s_24HCacheValid    = true;

      }

    }

  }

}



bool IsPriceNear24HHigh(double price, double thresholdPct, int lookbackHours) {

  if (lookbackHours <= 0 || thresholdPct <= 0 || price <= 0)

    return false;



  Update24HRangeCache(lookbackHours);

  if (!s_24HCacheValid)

    return false;



  double highest = MathMax(s_cached24HHighest, price);

  double lowest  = MathMin(s_cached24HLowest, price);

  double range   = highest - lowest;

  if (range <= 0)

    return false;



  double upperBoundary = highest - (range * (thresholdPct / 100.0));

  return (price >= upperBoundary);

}



bool IsPriceNear24HLow(double price, double thresholdPct, int lookbackHours) {

  if (lookbackHours <= 0 || thresholdPct <= 0 || price <= 0)

    return false;



  Update24HRangeCache(lookbackHours);

  if (!s_24HCacheValid)

    return false;



  double highest = MathMax(s_cached24HHighest, price);

  double lowest  = MathMin(s_cached24HLowest, price);

  double range   = highest - lowest;

  if (range <= 0)

    return false;



  double lowerBoundary = lowest + (range * (thresholdPct / 100.0));

  return (price <= lowerBoundary);

}



//+------------------------------------------------------------------+

//| CHECK IF PENDING ORDERS SHOULD BE RESET DUE TO MARKET MOVEMENT   |

//+------------------------------------------------------------------+



bool ShouldResetPendingOrders() {

  if (!EnablePendingOrderReset || PendingResetDistancePips <= 0)

    return false;



  // When both BUY STOP and SELL STOP are active (straddle),

  // price is bracketed in both directions - don't reset until one triggers.

  if (CountPendingOrders() > 1)

    return false;



  double resetPriceDist = PipsToPriceDistance(PendingResetDistancePips);

  if (resetPriceDist <= 0)

    return false;



  MqlTick currentTick;

  double currentAsk = 0.0;

  double currentBid = 0.0;

  if (SymbolInfoTick(_Symbol, currentTick) && currentTick.ask > 0 && currentTick.bid > 0) {

    currentAsk = currentTick.ask;

    currentBid = currentTick.bid;

  } else {

    currentAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    currentBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  }



  if (currentAsk <= 0 || currentBid <= 0)

    return false;



  for (int i = OrdersTotal() - 1; i >= 0; i--) {

    ulong ticket = OrderGetTicket(i);

    if (ticket == 0)

      continue;

    if (!OrderSelect(ticket))

      continue;

    if (OrderGetString(ORDER_SYMBOL) != _Symbol)

      continue;

    if ((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)

      continue;



    ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

    double orderPrice = OrderGetDouble(ORDER_PRICE_OPEN);



    // BUY STOP: placed above market.

    // Check if current market moves down away from placement reference price:

    if (type == ORDER_TYPE_BUY_STOP) {

      double refAsk = (PendingOrderRefAsk > 0 ? PendingOrderRefAsk : (orderPrice - MathMax(InitialDistance, GetMinimumStopDistance())));

      double moveDown = refAsk - currentAsk;



      if (moveDown >= resetPriceDist) {

        double movePips = (GetPipValueInPrice() > 0 ? (moveDown / GetPipValueInPrice()) : 0.0);

        Print("[PENDING RESET] BUY STOP @ ", DoubleToString(orderPrice, 2), " | Ref Ask: ",

              DoubleToString(refAsk, 2), " | Current Ask: ", DoubleToString(currentAsk, 2),

              " | Distance: ", DoubleToString(movePips, 1),

              " pips ($", DoubleToString(moveDown, 2), ") >= Target: ",

              DoubleToString(PendingResetDistancePips, 1), " pips ($",

              DoubleToString(resetPriceDist, 2), "). Resetting orders.");

        return true;

      }

    }



    // SELL STOP: placed below market.

    // Check if current market moves up away from placement reference price:

    if (type == ORDER_TYPE_SELL_STOP) {

      double refBid = (PendingOrderRefBid > 0 ? PendingOrderRefBid : (orderPrice + MathMax(InitialDistance, GetMinimumStopDistance())));

      double moveUp = currentBid - refBid;



      if (moveUp >= resetPriceDist) {

        double movePips = (GetPipValueInPrice() > 0 ? (moveUp / GetPipValueInPrice()) : 0.0);

        Print("[PENDING RESET] SELL STOP @ ", DoubleToString(orderPrice, 2), " | Ref Bid: ",

              DoubleToString(refBid, 2), " | Current Bid: ", DoubleToString(currentBid, 2),

              " | Distance: ", DoubleToString(movePips, 1),

              " pips ($", DoubleToString(moveUp, 2), ") >= Target: ",

              DoubleToString(PendingResetDistancePips, 1), " pips ($",

              DoubleToString(resetPriceDist, 2), "). Resetting orders.");

        return true;

      }

    }

  }



  return false;

}



//+------------------------------------------------------------------+

//| START NEW CYCLE                                                  |

//+------------------------------------------------------------------+



void StartNewCycle() {

  if (IsPostCloseDelayActive())

    return;



  if (IsDateSkipped())

    return;



  if (!IsDateAllowed())

    return;



  if (IsFridayTradingBlocked())

    return;



  if (IsMaxPosCloseDayBlocked())

    return;



  if (CountPositions() > 0 || CountHedgePositions() > 0)

    return;



  if (CountPendingOrders() > 0) {

    DeleteAllPendingOrders();

  }



  if (TimeCurrent() < DDResumeTime)

    return;



  if (!IsInsideAnySession())

    return;



  MqlTick currentTick;

  double ask = 0.0;

  double bid = 0.0;

  if (SymbolInfoTick(_Symbol, currentTick) && currentTick.ask > 0 && currentTick.bid > 0) {

    ask = currentTick.ask;

    bid = currentTick.bid;

  } else {

    ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  }



  if (ask <= 0 || bid <= 0)

    return;



  // Throttle idle filter re-evaluations when previously blocked:

  // Skip if within the same M1 bar, < 5 seconds elapsed, and price moved < 1 pip

  static datetime s_lastBlockedCycleTime = 0;

  static datetime s_lastBlockedBarTime   = 0;

  static double   s_lastBlockedBid       = 0.0;

  static double   s_lastBlockedAsk       = 0.0;



  datetime curM1Time = iTime(_Symbol, PERIOD_M1, 0);

  double pipVal = GetPipValueInPrice();

  double minMove = (pipVal > 0 ? pipVal : _Point * 10);



  if (s_lastBlockedCycleTime > 0 && curM1Time == s_lastBlockedBarTime && (TimeCurrent() - s_lastBlockedCycleTime < 5)) {

    if (MathAbs(bid - s_lastBlockedBid) < minMove && MathAbs(ask - s_lastBlockedAsk) < minMove) {

      return;

    }

  }



  PendingOrderRefAsk    = ask;

  PendingOrderRefBid    = bid;

  PendingOrderPlaceTime = TimeCurrent();



  //================================================================

  // DIRECTIONAL PREDICTION + SR ZONE + TREND FILTER

  //

  // Decide which side(s) are allowed to open this cycle. When

  // directional prediction is enabled, on a directional prediction

  // (BUY or SELL) only that side is placed. On SIDEWAYS, both sides

  // are placed (unless OnlyTradeBothWhenSideways = false).

  // When directional prediction, SR filter, and trend filter are all

  // marked false, both BUY and SELL stop orders are unconditionally

  // placed with InitialDistance.

  //================================================================



  ENUM_PREDICTED_DIRECTION prediction = PRED_SIDEWAYS;



  bool allowBuy  = true;

  bool allowSell = true;



  if (EnableDirectionalPrediction) {

    prediction = PredictDirection();



    if (prediction == PRED_BUY) {

      allowSell = false;

    } else if (prediction == PRED_SELL) {

      allowBuy = false;

    } else if (!OnlyTradeBothWhenSideways) {

      // Sideways read and the user does not want both-sides fallback -

      // skip this cycle, but still log it for analysis.

      if (EnablePredictionLog) {

        LogPredictionCycle(prediction, false, false, false, false, false, false,

                            ask, bid, "NONE", "NONE", 0.0, 0, "Skipped (Sideways, both-side fallback disabled)");

      }

      static datetime lastSidewaysLogTime = 0;

      if (TimeCurrent() - lastSidewaysLogTime >= 60) {

        lastSidewaysLogTime = TimeCurrent();

        Print("[PREDICTION] Sideways read - both-side fallback disabled. Skipping cycle.");

      }

      return;

    }

  }



  bool srBlockedBuy  = false;

  bool srBlockedSell = false;

  bool trendBlockedBuy  = false;

  bool trendBlockedSell = false;

  bool rangeBlockedBuy  = false;

  bool rangeBlockedSell = false;



  // 24-Hour Range Boundary Guard (prevents buying at range ceiling or selling at range floor)

  if (EnableRangeBoundaryFilter) {

    bool applyRangeGuard = (!RangeBoundarySidewaysOnly) || (prediction == PRED_SIDEWAYS);

    if (applyRangeGuard) {

      if (allowBuy && IsPriceNear24HHigh(ask, RangeBoundaryThresholdPct, RangeLookbackHours)) {

        allowBuy = false;

        rangeBlockedBuy = true;

      }

      if (allowSell && IsPriceNear24HLow(bid, RangeBoundaryThresholdPct, RangeLookbackHours)) {

        allowSell = false;

        rangeBlockedSell = true;

      }

    }

  }



  ENUM_TREND_STATE trend = TREND_NONE;

  if (EnableTrendFilter) {

    trend = GetTrendFilterDirection();

  }



  // Combined Trend + SR filter logic

  if (EnableTrendFilter && EnableSRFilter) {

    // PULLBACK CONFIRMATION MODE (Both Trend & SR filters active simultaneously):

    // In an UPTREND, do not block BUY near resistance - instead, only allow BUY when price pulls back to SUPPORT (buying the dip in an uptrend).

    // In a DOWNTREND, only allow SELL when price rallies to RESISTANCE (selling the rally in a downtrend).

    if (trend == TREND_UP) {

      allowSell = false;

      trendBlockedSell = true; // No counter-trend selling in an uptrend



      if (allowBuy) {

        if (!IsNearStrongSupport(bid)) {

          allowBuy = false;

          srBlockedBuy = true; // Waiting for pullback to support

        }

      }

    } else if (trend == TREND_DOWN) {

      allowBuy = false;

      trendBlockedBuy = true; // No counter-trend buying in a downtrend



      if (allowSell) {

        if (!IsNearStrongResistance(ask)) {

          allowSell = false;

          srBlockedSell = true; // Waiting for rally to resistance

        }

      }

    } else {

      // TREND_NONE (Sideways / No confirmed trend): Standard SR range boundaries apply

      if (allowBuy && IsNearStrongResistance(ask)) {

        allowBuy = false;

        srBlockedBuy = true;

      }

      if (allowSell && IsNearStrongSupport(bid)) {

        allowSell = false;

        srBlockedSell = true;

      }

    }

  } else {

    // Independent filter operation (one or neither active)

    if (EnableSRFilter) {

      if (allowBuy && IsNearStrongResistance(ask)) {

        allowBuy = false;

        srBlockedBuy = true;

      }

      if (allowSell && IsNearStrongSupport(bid)) {

        allowSell = false;

        srBlockedSell = true;

      }

    }



    if (EnableTrendFilter) {

      if (allowBuy && trend == TREND_DOWN) {

        allowBuy = false;

        trendBlockedBuy = true;

      }

      if (allowSell && trend == TREND_UP) {

        allowSell = false;

        trendBlockedSell = true;

      }

    }

  }



  // Macro H4 Trend Filter (Complete Counter-Trend Disable Mode)

  if (EnableMacroTrendFilter && MacroCounterTrendMode == COUNTER_TREND_DISABLE) {

    ENUM_TREND_STATE mTrend = GetMacroTrendState();

    if (allowBuy && mTrend == TREND_DOWN) {

      allowBuy = false;

      trendBlockedBuy = true;

    }

    if (allowSell && mTrend == TREND_UP) {

      allowSell = false;

      trendBlockedSell = true;

    }

  }



  if (!allowBuy && !allowSell) {

    s_lastBlockedCycleTime = TimeCurrent();

    s_lastBlockedBarTime   = curM1Time;

    s_lastBlockedBid       = bid;

    s_lastBlockedAsk       = ask;



    if (EnablePredictionLog) {

      LogPredictionCycle(prediction, false, false, srBlockedBuy, srBlockedSell,

                          trendBlockedBuy, trendBlockedSell, ask, bid, "NONE", "NONE",

                          0.0, 0, "Skipped (no valid side after filters)");

    }

    static datetime lastFilterBlockedLogTime = 0;

    if (TimeCurrent() - lastFilterBlockedLogTime >= 60) {

      lastFilterBlockedLogTime = TimeCurrent();

      if (!MQLInfoInteger(MQL_TESTER)) {

        Print("[PREDICTION] Both sides blocked by filters this cycle (Prediction: ", 

              (prediction == PRED_BUY ? "BUY" : (prediction == PRED_SELL ? "SELL" : "SIDEWAYS")),

              ", Range-blocked: [Buy:", rangeBlockedBuy, ", Sell:", rangeBlockedSell,

              "], SR-blocked: [Buy:", srBlockedBuy, ", Sell:", srBlockedSell,

              "], Trend-blocked: [Buy:", trendBlockedBuy, ", Sell:", trendBlockedSell, "]). Waiting for clear signal.");

      }

    }

    return;

  }



  s_lastBlockedCycleTime = 0;



  // Record the decision for this cycle; the outcome row is written

  // when the cycle eventually closes (LogPredictionOutcome()).

  CurrentPrediction.active             = true;

  CurrentPrediction.cycleStartTime     = TimeCurrent();

  CurrentPrediction.predictedDirection = EnableDirectionalPrediction ?

      (prediction == PRED_BUY ? "BUY" : (prediction == PRED_SELL ? "SELL" : "SIDEWAYS")) : "DISABLED";

  CurrentPrediction.allowBuy           = allowBuy;

  CurrentPrediction.allowSell          = allowSell;

  CurrentPrediction.rangeBlockedBuy    = rangeBlockedBuy;

  CurrentPrediction.rangeBlockedSell   = rangeBlockedSell;

  CurrentPrediction.srBlockedBuy       = srBlockedBuy;

  CurrentPrediction.srBlockedSell      = srBlockedSell;

  CurrentPrediction.trendBlockedBuy    = trendBlockedBuy;

  CurrentPrediction.trendBlockedSell   = trendBlockedSell;

  CurrentPrediction.initialAsk         = ask;

  CurrentPrediction.initialBid         = bid;

  CurrentPrediction.sideOpened         = (allowBuy && allowSell) ? "BOTH" : (allowBuy ? "BUY" : "SELL");

  CycleMaxGridLevel                    = 0;

  FridayHedgeLockedThisCycle           = false;

  CycleSessionMultiplier               = GetActiveDistanceMultiplier();



  double minimumDistance = GetMinimumStopDistance();



  //================================================================

  // ATR BASELINE (captured once per cycle; every grid level's

  // distance this cycle is scaled relative to this value)

  //================================================================



  if (UseATRDistanceScaling) {

    double startingATR = GetCurrentATR();



    if (startingATR > 0) {

      BaselineATR = startingATR;

    } else {

      Print("[ATR WARNING] Could not read starting ATR - distance "

            "scaling ratio will be 1.0 until a valid reading is available.");

    }

  }



  CycleBaseLot = 0.0;

  Level1PartialClosedThisCycle = false;



  // Compute effective initial lots and distance multipliers per direction

  double lotBuy  = GetEffectiveInitialLot(POSITION_TYPE_BUY);

  double lotSell = GetEffectiveInitialLot(POSITION_TYPE_SELL);



  double distMultBuy  = GetMacroDistanceMultiplier(POSITION_TYPE_BUY);

  double distMultSell = GetMacroDistanceMultiplier(POSITION_TYPE_SELL);



  double actualDistanceBuy  = MathMax(InitialDistance * distMultBuy, minimumDistance);

  double actualDistanceSell = MathMax(InitialDistance * distMultSell, minimumDistance);



  // Initial TP distance in price units (converted from pips)

  double effectiveInitialTP = PipsToPriceDistance(InitialTPPips);



  //================================================================

  // BUY STOP (only placed when the prediction/SR/trend filters allow it)

  //================================================================



  if (allowBuy) {

    double buyPrice = NormalizeToTickSize(ask + actualDistanceBuy);



    // Ensure BUY STOP remains far enough from ASK

    if ((buyPrice - ask) < minimumDistance) {

      buyPrice = NormalizeToTickSize(ask + minimumDistance + SymbolTickSize());

    }



    double buyTP = 0;

    bool willTrailBuy = EnableLevel1TrendRunner && (lotBuy >= 0.02 || Level1TrailFullSingleLot);




    if (effectiveInitialTP > 0 && !willTrailBuy) {

      double actualTPDistance = MathMax(effectiveInitialTP, minimumDistance);



      buyTP = NormalizeToTickSize(buyPrice + actualTPDistance);



      // Final safety check

      if ((buyTP - buyPrice) < minimumDistance) {

        buyTP =

            NormalizeToTickSize(buyPrice + minimumDistance + SymbolTickSize());

      }

    }



    bool buyResult = trade.BuyStop(lotBuy, buyPrice, _Symbol, 0, buyTP,

                                   ORDER_TIME_GTC, 0, EAComment + "_INITIAL_BUY");



    if (buyResult) {

      Print("------------------------------------------");

      Print("INITIAL BUY STOP PLACED");

      Print("Lot       : ", lotBuy);

      Print("Price     : ", buyPrice);

      Print("TP        : ", buyTP);

      Print("Distance  : ", buyPrice - ask);

      Print("Prediction: ", CurrentPrediction.predictedDirection);

      Print("------------------------------------------");

    } else {

      Print("BUY STOP ERROR");

      Print("Retcode   : ", trade.ResultRetcode());

      Print("Message   : ", trade.ResultRetcodeDescription());

      Print("Ask       : ", ask);

      Print("Price     : ", buyPrice);

      Print("TP        : ", buyTP);

      Print("Min Dist  : ", minimumDistance);

    }

  } else {

    if (!MQLInfoInteger(MQL_TESTER)) {

      Print("[PREDICTION/FILTER] BUY side skipped this cycle (Prediction: ", CurrentPrediction.predictedDirection,

            ", Range-blocked: ", rangeBlockedBuy, ", SR-blocked: ", srBlockedBuy, ", Trend-blocked: ", trendBlockedBuy, ")");

    }

  }



  //================================================================

  // SELL STOP (only placed when the prediction/SR/trend filters allow it)

  //================================================================



  if (allowSell) {

    double sellPrice = NormalizeToTickSize(bid - actualDistanceSell);



    // Ensure SELL STOP remains far enough from BID

    if ((bid - sellPrice) < minimumDistance) {

      sellPrice = NormalizeToTickSize(bid - minimumDistance - SymbolTickSize());

    }



    double sellTP = 0;

    bool willTrailSell = EnableLevel1TrendRunner && (lotSell >= 0.02 || Level1TrailFullSingleLot);




    if (effectiveInitialTP > 0 && !willTrailSell) {

      double actualTPDistance = MathMax(effectiveInitialTP, minimumDistance);



      sellTP = NormalizeToTickSize(sellPrice - actualTPDistance);



      if ((sellPrice - sellTP) < minimumDistance) {

        sellTP =

            NormalizeToTickSize(sellPrice - minimumDistance - SymbolTickSize());

      }

    }



    bool sellResult =

        trade.SellStop(lotSell, sellPrice, _Symbol, 0, sellTP, ORDER_TIME_GTC, 0,

                       EAComment + "_INITIAL_SELL");



    if (sellResult) {

      Print("------------------------------------------");

      Print("INITIAL SELL STOP PLACED");

      Print("Lot       : ", lotSell);

      Print("Price     : ", sellPrice);

      Print("TP        : ", sellTP);

      Print("Distance  : ", bid - sellPrice);

      Print("Prediction: ", CurrentPrediction.predictedDirection);

      Print("------------------------------------------");

    } else {

      Print("SELL STOP ERROR");

      Print("Retcode   : ", trade.ResultRetcode());

      Print("Message   : ", trade.ResultRetcodeDescription());

      Print("Bid       : ", bid);

      Print("Price     : ", sellPrice);

      Print("TP        : ", sellTP);

      Print("Min Dist  : ", minimumDistance);

    }

  } else {

    if (!MQLInfoInteger(MQL_TESTER)) {

      Print("[PREDICTION/FILTER] SELL side skipped this cycle (Prediction: ", CurrentPrediction.predictedDirection,

            ", Range-blocked: ", rangeBlockedSell, ", SR-blocked: ", srBlockedSell, ", Trend-blocked: ", trendBlockedSell, ")");

    }

  }

}



//+------------------------------------------------------------------+

//| MANAGE MARTINGALE                                                |

//+------------------------------------------------------------------+



void ManageMartingale(ENUM_POSITION_TYPE direction, int tradeCount) {

  // Only one pending order at a time - exit immediately to avoid all downstream calculations

  if (CountPendingOrders() > 0) {

    return;

  }



  if (tradeCount < 0) {

    tradeCount = CountPositions();

  }



  if (tradeCount > CycleMaxGridLevel) {

    CycleMaxGridLevel = tradeCount;

  }



  if (tradeCount >= MaximumTrades) {

    return;

  }



  // Hard grid cap: an independent, typically LOWER ceiling than

  // MaximumTrades, so the grid can be capped tightly without touching

  // the MaximumTrades safety limit used elsewhere.

  if (EnableHardGridCap && tradeCount >= MaxGridLevelsHardCap) {

    return;

  }



  // Macro H4 Trend Cap: restrict grid depth depending on whether cycle is with-trend or counter-trend

  if (EnableMacroTrendFilter && MacroCounterTrendMode == COUNTER_TREND_CAP_GRID) {

    int macroCap = GetMacroAllowedGridLevels(direction);

    if (tradeCount >= macroCap) {

      return;

    }

  }



  // Safety guard: do not place new grid limit orders if max positions close limit reached

  if (EnableMaxPositionsClose && tradeCount >= MaxPositionsToClose) {

    return;

  }



  // Friday Rollover Protection: do not place new grid limit orders if locked with 100% hedge

  if (FridayHedgeLockedThisCycle) {

    return;

  }



  // News filter: optionally pause adding NEW grid levels during a

  // high-impact blackout. Existing positions, basket TP updates,

  // and basket SL checks are unaffected - only new averaging-down

  // orders are paused.

  if (InpEnableNewsFilter && InpBlockGridDuringNews &&

      IsHighImpactNewsWindow()) {

    return;

  }



  double lastEntry = GetLastEntryPrice(direction);



  if (lastEntry <= 0) {

    Print("[MARTINGALE ERROR] Invalid frontier entry price: ", lastEntry);

    return;

  }



  int nextLevel = tradeCount + 1;



  if (nextLevel > MaximumTrades) {

    return;

  }



  double rawLot = GetLotForLevel(nextLevel);

  double nextLot = rawLot;



  if (nextLot > MaximumLot) {

    nextLot = NormalizeLotRound(MaximumLot);

  }



  //===============================================================

  // DISTANCE (ATR VOLATILITY-SCALED & SESSION-AWARE)

  //===============================================================



  double atrRatio = GetATRVolatilityRatio();

  double distMult = GetActiveDistanceMultiplier();



  double distance =

      InitialDistance * MathPow(distMult, tradeCount - 1) * atrRatio;



  double minimumDistance = GetMinimumStopDistance();



  distance = MathMax(distance, minimumDistance);



  //===============================================================

  // BUY MARTINGALE

  //===============================================================



  if (direction == POSITION_TYPE_BUY) {

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);



    if (ask <= 0 || bid <= 0)

      return;



    double targetPrice = NormalizeToTickSize(lastEntry - distance);



    // Case 1: Market price has already reached or crossed the grid level (overshot) -> Market Buy

    if (ask <= targetPrice) {

      Print("==========================================");

      Print("BUY MARTINGALE MARKET ENTRY (PRICE REACHED / OVERSHOT)");

      Print("Level       : ", nextLevel);

      Print("Raw Lot     : ", rawLot);

      Print("Final Lot   : ", nextLot);

      Print("Frontier Buy: ", lastEntry);

      Print("Target Price: ", targetPrice);

      Print("Current Ask : ", ask);

      Print("ATR Ratio   : ", DoubleToString(atrRatio, 3));

      Print("Dist Mult   : ", DoubleToString(distMult, 2), " (" + GetCurrentSession() + ")");

      Print("Distance    : ", distance);

      Print("==========================================");



      bool result = trade.Buy(nextLot, _Symbol, 0, 0, 0, EAComment + "_MG_BUY");



      if (result) {

        Print("BUY MARKET ORDER PLACED SUCCESS. Deal/Order: ", trade.ResultDeal(), " / ", trade.ResultOrder());

      } else {

        Print("BUY MARKET ORDER ERROR");

        Print("Retcode     : ", trade.ResultRetcode());

        Print("Message     : ", trade.ResultRetcodeDescription());

      }

      return;

    }



    // Case 2: Market price is still above target -> Place BuyLimit

    double orderPrice = targetPrice;

    if ((ask - orderPrice) < minimumDistance) {

      orderPrice = NormalizeToTickSize(ask - minimumDistance);

    }



    if (orderPrice < ask) {

      Print("==========================================");

      Print("BUY MARTINGALE PLACING LIMIT ORDER");

      Print("Level       : ", nextLevel);

      Print("Raw Lot     : ", rawLot);

      Print("Final Lot   : ", nextLot);

      Print("Frontier Buy: ", lastEntry);

      Print("Target Price: ", targetPrice);

      Print("Current Ask : ", ask);

      Print("ATR Ratio   : ", DoubleToString(atrRatio, 3));

      Print("Dist Mult   : ", DoubleToString(distMult, 2), " (" + GetCurrentSession() + ")");

      Print("Distance    : ", distance);

      Print("Order Price : ", orderPrice);

      Print("==========================================");



      bool result = trade.BuyLimit(nextLot, orderPrice, _Symbol, 0, 0,

                                   ORDER_TIME_GTC, 0, EAComment + "_MG_BUY");



      if (result) {

        Print("BUY LIMIT PLACED SUCCESS. Ticket: ", trade.ResultOrder());

      } else {

        Print("==========================================");

        Print("BUY LIMIT ERROR");

        Print("Retcode     : ", trade.ResultRetcode());

        Print("Message     : ", trade.ResultRetcodeDescription());

        Print("Level       : ", nextLevel);

        Print("Lot         : ", nextLot);

        Print("Ask         : ", ask);

        Print("Price       : ", orderPrice);

        Print("Min Dist    : ", minimumDistance);

        Print("==========================================");

      }

    }

  }



  //===============================================================

  // SELL MARTINGALE

  //===============================================================



  if (direction == POSITION_TYPE_SELL) {

    double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

    double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);



    if (ask <= 0 || bid <= 0)

      return;



    double targetPrice = NormalizeToTickSize(lastEntry + distance);



    // Case 1: Market price has already reached or crossed the grid level (overshot) -> Market Sell

    if (bid >= targetPrice) {

      Print("==========================================");

      Print("SELL MARTINGALE MARKET ENTRY (PRICE REACHED / OVERSHOT)");

      Print("Level        : ", nextLevel);

      Print("Raw Lot      : ", rawLot);

      Print("Final Lot    : ", nextLot);

      Print("Frontier Sell: ", lastEntry);

      Print("Target Price : ", targetPrice);

      Print("Current Bid  : ", bid);

      Print("ATR Ratio    : ", DoubleToString(atrRatio, 3));

      Print("Dist Mult    : ", DoubleToString(distMult, 2), " (" + GetCurrentSession() + ")");

      Print("Distance     : ", distance);

      Print("==========================================");



      bool result = trade.Sell(nextLot, _Symbol, 0, 0, 0, EAComment + "_MG_SELL");



      if (result) {

        Print("SELL MARKET ORDER PLACED SUCCESS. Deal/Order: ", trade.ResultDeal(), " / ", trade.ResultOrder());

      } else {

        Print("SELL MARKET ORDER ERROR");

        Print("Retcode      : ", trade.ResultRetcode());

        Print("Message      : ", trade.ResultRetcodeDescription());

      }

      return;

    }



    // Case 2: Market price is still below target -> Place SellLimit

    double orderPrice = targetPrice;

    if ((orderPrice - bid) < minimumDistance) {

      orderPrice = NormalizeToTickSize(bid + minimumDistance);

    }



    if (orderPrice > bid) {

      Print("==========================================");

      Print("SELL MARTINGALE PLACING LIMIT ORDER");

      Print("Level        : ", nextLevel);

      Print("Raw Lot      : ", rawLot);

      Print("Final Lot    : ", nextLot);

      Print("Frontier Sell: ", lastEntry);

      Print("Target Price : ", targetPrice);

      Print("Current Bid  : ", bid);

      Print("ATR Ratio    : ", DoubleToString(atrRatio, 3));

      Print("Dist Mult    : ", DoubleToString(distMult, 2), " (" + GetCurrentSession() + ")");

      Print("Distance     : ", distance);

      Print("Order Price  : ", orderPrice);

      Print("==========================================");



      bool result = trade.SellLimit(nextLot, orderPrice, _Symbol, 0, 0,

                                    ORDER_TIME_GTC, 0, EAComment + "_MG_SELL");



      if (result) {

        Print("SELL LIMIT PLACED SUCCESS. Ticket: ", trade.ResultOrder());

      } else {

        Print("==========================================");

        Print("SELL LIMIT ERROR");

        Print("Retcode      : ", trade.ResultRetcode());

        Print("Message      : ", trade.ResultRetcodeDescription());

        Print("Level        : ", nextLevel);

        Print("Lot          : ", nextLot);

        Print("Bid          : ", bid);

        Print("Price        : ", orderPrice);

        Print("Min Dist     : ", minimumDistance);

        Print("==========================================");

      }

    }

  }

}



//+------------------------------------------------------------------+

//| GET PIP VALUE IN PRICE                                           |

//+------------------------------------------------------------------+



double GetPipValueInPrice() {

  int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

  double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

  string sym = _Symbol;

  StringToUpper(sym);



  if (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0) {

    if (digits == 3 || digits == 2 || digits == 1)

      return 0.10; // 1 pip on Gold is 10 cents ($0.10)

    return point * 10.0;

  }



  if (digits == 3 || digits == 5)

    return point * 10.0;



  return point;

}



//+------------------------------------------------------------------+

//| CONVERT PIPS TO PRICE DISTANCE                                   |

//+------------------------------------------------------------------+



double PipsToPriceDistance(double pips) { return pips * GetPipValueInPrice(); }



//+------------------------------------------------------------------+

//| DYNAMIC LOT & SKEW CALCULATION HELPERS                           |

//+------------------------------------------------------------------+



double GetCompoundedInitialLot() {

  if (!EnableAutoLotCompounding || CompoundingBaseBalance <= 0)

    return InitialLot;



  double currentBalance = AccountInfoDouble(ACCOUNT_BALANCE);

  if (currentBalance <= 0)

    return InitialLot;



  double factor = currentBalance / CompoundingBaseBalance;

  return InitialLot * factor;

}



double GetActiveSessionLotMultiplier() {

  MqlDateTime tm;

  TimeToStruct(GetSessionCurrentTime(), tm);

  int currentMinutes = tm.hour * 60 + tm.min;



  if (EnableSession1 && IsTimeInRangeFast(currentMinutes, g_Session1StartMin, g_Session1EndMin))

    return Session1LotMultiplier;



  if (EnableSession2 && IsTimeInRangeFast(currentMinutes, g_Session2StartMin, g_Session2EndMin))

    return Session2LotMultiplier;



  if (EnableSession3 && IsTimeInRangeFast(currentMinutes, g_Session3StartMin, g_Session3EndMin))

    return Session3LotMultiplier;



  if (EnableSession4 && IsTimeInRangeFast(currentMinutes, g_Session4StartMin, g_Session4EndMin))

    return Session4LotMultiplier;



  if (EnableSession5 && IsTimeInRangeFast(currentMinutes, g_Session5StartMin, g_Session5EndMin))

    return Session5LotMultiplier;



  return 1.0;

}



double GetMacroLotMultiplier(ENUM_POSITION_TYPE direction) {

  if (!EnableMacroTrendFilter || !EnableMacroSkew)

    return 1.0;



  ENUM_TREND_STATE mTrend = GetMacroTrendState();

  if (mTrend == TREND_UP) {

    return (direction == POSITION_TYPE_BUY) ? MacroWithTrendLotMult : MacroCounterTrendLotMult;

  } else if (mTrend == TREND_DOWN) {

    return (direction == POSITION_TYPE_SELL) ? MacroWithTrendLotMult : MacroCounterTrendLotMult;

  }

  return 1.0;

}



double GetMacroDistanceMultiplier(ENUM_POSITION_TYPE direction) {

  if (!EnableMacroTrendFilter || !EnableMacroSkew)

    return 1.0;



  ENUM_TREND_STATE mTrend = GetMacroTrendState();

  if (mTrend == TREND_UP) {

    return (direction == POSITION_TYPE_BUY) ? MacroWithTrendDistMult : MacroCounterTrendDistMult;

  } else if (mTrend == TREND_DOWN) {

    return (direction == POSITION_TYPE_SELL) ? MacroWithTrendDistMult : MacroCounterTrendDistMult;

  }

  return 1.0;

}



double GetEffectiveInitialLot(ENUM_POSITION_TYPE direction) {

  double base = GetCompoundedInitialLot();

  double sessionMult = GetActiveSessionLotMultiplier();

  double macroMult = GetMacroLotMultiplier(direction);



  double effective = base * sessionMult * macroMult;

  if (effective > MaximumLot)

    effective = MaximumLot;



  return NormalizeLotRound(effective);

}



//+------------------------------------------------------------------+

//| LEVEL 1 TREND-RUNNER (PARTIAL TP + TRAILING STOP)                |

//+------------------------------------------------------------------+



void ManageLevel1TrendRunner(ENUM_POSITION_TYPE direction, int positions) {

  if (!EnableLevel1TrendRunner)

    return;



  if (positions < 0)

    positions = CountPositions();



  if (positions != 1)

    return;



  ulong ticket = 0;

  double openPrice = 0.0;

  double currentLot = 0.0;

  double currentSL = 0.0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong t = PositionGetTicket(i);

    if (t == 0) continue;

    if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber) continue;

    ticket = t;

    openPrice = PositionGetDouble(POSITION_PRICE_OPEN);

    currentLot = PositionGetDouble(POSITION_VOLUME);

    currentSL = PositionGetDouble(POSITION_SL);

    double currentTP = PositionGetDouble(POSITION_TP);

    break;

  }



  if (ticket == 0 || openPrice <= 0 || currentLot <= 0)


  // Clear broker TP if runner will manage trailing, preventing broker from killing trail prematurely
  if ((currentLot >= 0.02 || Level1TrailFullSingleLot) && PositionGetDouble(POSITION_TP) > 0) {
    trade.PositionModify(ticket, currentSL, 0);
  }

    return;



  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

  double minDistance = GetMinimumStopDistance();

  double tpPipsDistance = PipsToPriceDistance(InitialTPPips);

  double trailDistance = PipsToPriceDistance(Level1TrailingDistancePips);

  double beBuffer = PipsToPriceDistance(Level1BreakevenBufferPips);



  // 1. Partial TP Execution when profit reaches InitialTPPips (for volume >= 0.02)

  // 1. Partial TP Execution when profit reaches InitialTPPips (for volume >= 0.02)
  // or full close for single lot when trailing on single lot is disabled
  if (!Level1PartialClosedThisCycle) {
    bool tpReached = (direction == POSITION_TYPE_BUY) ? (bid >= openPrice + tpPipsDistance) :
                                                        (ask <= openPrice - tpPipsDistance);
    if (tpReached) {
      if (currentLot >= 0.02) {
        double closeLot = NormalizeLotRound(currentLot * (Level1PartialClosePct / 100.0));
        double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
        if (closeLot >= minLot && (currentLot - closeLot) >= minLot) {
          if (trade.PositionClosePartial(ticket, closeLot)) {
            Level1PartialClosedThisCycle = true;
            Print("[LEVEL 1 RUNNER] Partial TP executed: closed ", closeLot, " lots. Remaining: ", currentLot - closeLot);
          }
        }
      } else if (!Level1TrailFullSingleLot) {
        if (trade.PositionClose(ticket)) {
          Level1PartialClosedThisCycle = true;
          Print("[LEVEL 1 RUNNER] Single lot TP executed: closed ", currentLot, " lots at Initial TP.");
          return;
        }
      }
    }
  }

  if (false && !Level1PartialClosedThisCycle && currentLot >= 0.02) {

    bool tpReached = (direction == POSITION_TYPE_BUY) ? (bid >= openPrice + tpPipsDistance) :

                                                        (ask <= openPrice - tpPipsDistance);

    if (tpReached) {

      double closeLot = NormalizeLotRound(currentLot * (Level1PartialClosePct / 100.0));

      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      if (closeLot >= minLot && (currentLot - closeLot) >= minLot) {

        if (trade.PositionClosePartial(ticket, closeLot)) {

          Level1PartialClosedThisCycle = true;

          Print("[LEVEL 1 RUNNER] Partial TP executed: closed ", closeLot, " lots. Remaining: ", currentLot - closeLot);

        }

      }

    }

  }



  // 2. Trailing Stop & Breakeven Lock

  bool allowTrailing = Level1PartialClosedThisCycle || (Level1TrailFullSingleLot && currentLot > 0);

  if (allowTrailing) {

    if (direction == POSITION_TYPE_BUY) {

      double targetBE = NormalizeToTickSize(openPrice + beBuffer);

      double currentProfitDist = bid - openPrice;

      if (currentProfitDist >= tpPipsDistance) {

        double newSL = NormalizeToTickSize(bid - trailDistance);

        if (newSL < targetBE) newSL = targetBE;

        if (newSL > currentSL + minDistance && newSL < bid - minDistance) {

          trade.PositionModify(ticket, newSL, 0);

          Print("[LEVEL 1 RUNNER] BUY Trailing SL locked to: ", newSL);

        }

      }

    } else {

      double targetBE = NormalizeToTickSize(openPrice - beBuffer);

      double currentProfitDist = openPrice - ask;

      if (currentProfitDist >= tpPipsDistance) {

        double newSL = NormalizeToTickSize(ask + trailDistance);

        if (newSL > targetBE) newSL = targetBE;

        if ((currentSL == 0 || newSL < currentSL - minDistance) && newSL > ask + minDistance) {

          trade.PositionModify(ticket, newSL, 0);

          Print("[LEVEL 1 RUNNER] SELL Trailing SL locked to: ", newSL);

        }

      }

    }

  }

}



//+------------------------------------------------------------------+

//| LOT CALCULATION                                                  |

//+------------------------------------------------------------------+



double GetLotForLevel(int level) {

  double base = (CycleBaseLot > 0) ? CycleBaseLot : InitialLot;

  double lot = base * MathPow(Multiplier, level - 1);



  if (lot > MaximumLot)

    lot = MaximumLot;



  return NormalizeLotRound(lot);

}



//+------------------------------------------------------------------+

//| GET ACTIVE BASKET TP BASED ON GRID LEVEL                         |

//+------------------------------------------------------------------+



double GetActiveBasketTP(int positions = -1, ENUM_POSITION_TYPE direction = (ENUM_POSITION_TYPE)-1) {

  if (positions < 0)

    positions = CountPositions();



  ENUM_POSITION_TYPE dir = direction;

  if ((int)dir == -1) {

    dir = GetBasketDirection();

  }



  // Time-decay TP for stale baskets (> 24h): step down TP to Breakeven + 0.05

  if (EnableTimeDecayTP && TimeDecayHours > 0) {

    datetime firstOpen = GetBasketFirstOpenTime(dir);

    if (firstOpen > 0 && ((double)(TimeCurrent() - firstOpen) / 3600.0) >= TimeDecayHours) {

      return DecayBasketTP;

    }

  }



  double baseTP = BasketTP;

  if (EnableStepBasketTP && positions >= StepBasketTPGridLevel) {

    baseTP = StepBasketTP;

  }



  // Volatility-Adaptive Basket TP: scale TP distance during ATR volatility expansions

  if (UseATRBasketTPScaling) {

    double atrRatio = GetATRVolatilityRatio();

    if (atrRatio > 1.0) {

      double scale = MathMin(atrRatio, ATR_TP_MaxRatio);

      baseTP = NormalizeToTickSize(baseTP * scale);

    }

  }



  return baseTP;

}



//+------------------------------------------------------------------+

//| UPDATE BASKET TP                                                 |

//+------------------------------------------------------------------+



void UpdateBasketTP(ENUM_POSITION_TYPE direction, int positions) {

  if (positions < 0)

    positions = CountPositions();



  if (positions <= 0)

    return;



  static int                s_lastTPPositions = -1;

  static datetime           s_lastTPCalcTime = 0;

  static ENUM_POSITION_TYPE s_lastTPDir = (ENUM_POSITION_TYPE)-1;



  bool hasActiveHedge = (EnableADXHedge && ADXHedgeAffectsBasketTP && CountHedgePositions() > 0);



  // If basket positions have not changed, direction has not changed, no active hedge, and calculated within last 10s:

  if (!hasActiveHedge && VirtualBasketTP > 0.0 && positions == s_lastTPPositions && direction == s_lastTPDir && (TimeCurrent() - s_lastTPCalcTime < 10)) {

    return;

  }



  double averagePrice = GetWeightedAveragePrice(direction);



  if (averagePrice <= 0)

    return;



  double minimumDistance = GetMinimumStopDistance();

  double activeBasketTP = GetActiveBasketTP(positions, direction);



  double tpDistance = MathMax(activeBasketTP, minimumDistance);



  //===============================================================

  // ADX HEDGE PROFIT ADJUSTMENT

  //

  // Live floating P/L of the currently open hedge is converted

  // into a price-distance equivalent for the basket lot size and used

  // to shift how far the basket needs to travel.

  //===============================================================



  if (EnableADXHedge && ADXHedgeAffectsBasketTP) {

    double hedgeProfit = GetHedgeFloatingProfit();



    if (hedgeProfit != 0) {

      double basketLots = GetBasketLots(direction);



      if (basketLots > 0) {

        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);



        double tickSize = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);



        if (tickValue > 0 && tickSize > 0) {

          double valuePerPriceUnit = (tickValue / tickSize) * basketLots;



          if (valuePerPriceUnit > 0) {

            double creditShift = hedgeProfit / valuePerPriceUnit;



            tpDistance -= creditShift;

          }

        }

      }

    }



    tpDistance = MathMax(tpDistance, minimumDistance);

  }



  //===============================================================

  // SWAP & COMMISSION COMPENSATION

  //

  // Negative rollover swap and broker commission accumulate on open

  // basket positions. If not compensated, exiting at a nominal price

  // TP can cause a net monetary loss (e.g. Wednesday 3x swap).

  // We calculate the net fee deficit and expand tpDistance so the

  // basket always exits with net positive profit.

  //===============================================================



  if (InpCompensateSwapAndCommission) {

    double totalFees = 0.0;



    for (int i = PositionsTotal() - 1; i >= 0; i--) {

      ulong ticket = PositionGetTicket(i);

      if (ticket == 0) continue;

      if (PositionGetString(POSITION_SYMBOL) != _Symbol) continue;

      ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

      if (magic != MagicNumber) {

        if (!(EnableADXHedge && ADXHedgeAffectsBasketTP && magic == ADXHedgeMagicNumber))

          continue;

      }

      totalFees += PositionGetDouble(POSITION_SWAP);

    }



    if (totalFees < 0) {

      double basketLots = GetBasketLots(direction);

      if (basketLots > 0) {

        double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);

        double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);

        if (tickValue > 0 && tickSize > 0) {

          double valuePerPriceUnit = (tickValue / tickSize) * basketLots;

          if (valuePerPriceUnit > 0) {

            double feeShift = MathAbs(totalFees) / valuePerPriceUnit;

            tpDistance += feeShift;

          }

        }

      }

    }

  }



  double targetTP;



  if (direction == POSITION_TYPE_BUY) {

    targetTP = NormalizeToTickSize(averagePrice + tpDistance);

  } else {

    targetTP = NormalizeToTickSize(averagePrice - tpDistance);

  }



  // NOTE: no "clamp target away from current market price" step here.

  // That clamp only makes sense for a REAL broker TP order (brokers

  // reject a TP placed closer than the symbol's minimum stop distance).

  // This TP is virtual and monitored purely in code by CheckBasketTP(),

  // so it must be allowed to sit at or even behind the current price -

  // otherwise the target keeps getting pushed further away every tick

  // as price approaches it and can never be reached.



  //===============================================================

  // STORE AS VIRTUAL TP (EA-MANAGED, NOT A REAL BROKER TP)

  //

  // The basket exit is executed exclusively by CheckBasketTP(), which

  // closes the hedge FIRST and the grid SECOND. If a real TP were left

  // on the grid positions, the broker could fill it independently of

  // the EA (e.g. on a fast tick or gap), closing the grid before the

  // hedge - which is exactly the bug being fixed here. Any pre-existing

  // real TP (e.g. from the initial BuyStop/SellStop InitialTP) is

  // stripped below so it can never fire on its own.

  //===============================================================



  VirtualBasketTP = targetTP;

  s_lastTPPositions = positions;

  s_lastTPCalcTime  = TimeCurrent();

  s_lastTPDir       = direction;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    ENUM_POSITION_TYPE type =

        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);



    if (type != direction)

      continue;



    double currentSL = PositionGetDouble(POSITION_SL);



    double currentTP = PositionGetDouble(POSITION_TP);



    if (currentTP != 0) {

      if (!trade.PositionModify(ticket, currentSL, 0)) {

        Print("TP CLEAR ERROR (switching to virtual TP)");

        Print("Ticket : ", ticket);

        Print("Error  : ", trade.ResultRetcodeDescription());

      }

    }

  }

}



//+------------------------------------------------------------------+

//| CHECK VIRTUAL BASKET TP (CLOSE HEDGE FIRST, THEN GRID)           |

//+------------------------------------------------------------------+

//

// This is the ONLY place the basket is closed on a take-profit hit.

// Order is strict and intentional:

//   1. Close any open hedge position(s) first.

//   2. Only then close the grid basket.

// Doing this in a single EA-controlled tick (rather than relying on a

// real broker TP order on the grid) prevents the grid from ever being

// closed by the broker before the hedge has been closed by the EA.



bool CheckBasketTP(ENUM_POSITION_TYPE direction) {

  if (VirtualBasketTP <= 0)

    return false;



  double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);



  double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);



  bool hit = false;



  if (direction == POSITION_TYPE_BUY) {

    hit = (bid >= VirtualBasketTP);

  } else {

    hit = (ask <= VirtualBasketTP);

  }



  if (!hit)

    return false;



  // Ensure Net Dollar Profit on grid positions (hedge excluded to ease pressure on existing grid lots)

  if (InpEnsureNetProfitOnTP) {

    double gridFloating = GetGridFloatingProfit();

    double requiredMinProfit = InpMinNetProfitOnTP;

    if (EnableTimeDecayTP && TimeDecayHours > 0) {

      datetime firstOpen = GetBasketFirstOpenTime(direction);

      if (firstOpen > 0 && ((double)(TimeCurrent() - firstOpen) / 3600.0) >= TimeDecayHours) {

        requiredMinProfit = 0.0; // Allow breakeven exit for stale baskets

      }

    }

    if (gridFloating < requiredMinProfit) {

      return false;

    }

  }



  Print("==========================================");

  Print("BASKET TP HIT");

  Print("Target      : ", VirtualBasketTP);

  Print("Direction   : ", EnumToString(direction));

  Print("==========================================");







  // 1. FIRST: close the hedge (must always close before the grid).

  CloseAllHedgePositions();

  Print("1. CLOSED HEDGE POSITION(S) BEFORE GRID");



  // 2. SECOND: close the grid basket itself.

  CloseBasket();

  Print("2. CLOSED GRID BASKET");



  RecordPositionClose();

  VirtualBasketTP = 0.0;

  ADXHedgeOpenedThisCycle = false;

  FridayHedgeLockedThisCycle = false;

  CycleWasActive = false;

  DeleteAllPendingOrders();

  LogPredictionOutcome("Basket TP Hit");

  if (EnableDDLogging) {

    OnBasketCycleClosed("Basket TP Hit");

  } else {

    DDThresholdLoggedThisCycle = false;

    CurrentCycleMaxDD = 0.0;

  }



  return true;

}



//+------------------------------------------------------------------+

//| GET GRID ONLY FLOATING PROFIT (EXCLUDES HEDGE POSITIONS)         |

//+------------------------------------------------------------------+



double GetGridFloatingProfit() {

  double totalFloating = 0.0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);

    if (ticket == 0)

      continue;

    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;

    ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

    if (magic == MagicNumber) {

      totalFloating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

    }

  }



  return totalFloating;

}



//+------------------------------------------------------------------+

//| GET TOTAL FLOATING PROFIT (GRID + HEDGE)                         |

//+------------------------------------------------------------------+



double GetTotalFloatingProfit() {

  double totalFloating = 0.0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);

    if (ticket == 0)

      continue;

    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;

    ulong magic = (ulong)PositionGetInteger(POSITION_MAGIC);

    if (magic == MagicNumber || magic == ADXHedgeMagicNumber) {

      totalFloating += PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

    }

  }



  return totalFloating;

}



//+------------------------------------------------------------------+

//| GET FIRST POSITION OPEN TIME IN BASKET                           |

//+------------------------------------------------------------------+



datetime GetBasketFirstOpenTime(ENUM_POSITION_TYPE direction) {

  datetime earliestTime = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);

    if (ticket == 0)

      continue;

    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;

    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    ENUM_POSITION_TYPE type = (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);

    if (type != direction)

      continue;



    datetime posTime = (datetime)PositionGetInteger(POSITION_TIME);

    if (earliestTime == 0 || (posTime > 0 && posTime < earliestTime)) {

      earliestTime = posTime;

    }

  }



  return earliestTime;

}



//+------------------------------------------------------------------+

//| WRITE CSV DATA HELPER (SUPPORTS FILE_COMMON & LOCAL)             |

//+------------------------------------------------------------------+



void WriteCSVToFileHandle(string filename, int commonFlag) {

  int flags = FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE;

  if (commonFlag != 0)

    flags |= commonFlag;



  int fileHandle = FileOpen(filename, flags, ',');

  if (fileHandle != INVALID_HANDLE) {

    // Write CSV Header

    FileWrite(fileHandle,

              "Date",

              "Grid_Start_Time",

              "DD_Trigger_Time",

              "Basket_Close_Time",

              "Trigger_DD_Amount_USD",

              "Peak_DD_Amount_USD",

              "Peak_DD_Pct",

              "Direction",

              "Trades_Count",

              "Peak_Volume_Lots",

              "Average_Price",

              "Exit_Reason");



    int totalEvents = ArraySize(DDHistory);

    if (totalEvents > 0) {

      for (int i = 0; i < totalEvents; i++) {

        FileWrite(fileHandle,

                  DDHistory[i].ddDate,

                  TimeToString(DDHistory[i].gridStartTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS),

                  TimeToString(DDHistory[i].ddHitTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS),

                  (DDHistory[i].closeTime > 0 ? TimeToString(DDHistory[i].closeTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS) : "Active"),

                  DoubleToString(DDHistory[i].hitDD, 2),

                  DoubleToString(DDHistory[i].maxDD, 2),

                  DoubleToString(DDHistory[i].maxDDPct, 2) + "%",

                  DDHistory[i].direction,

                  IntegerToString(DDHistory[i].maxPositions),

                  DoubleToString(DDHistory[i].maxLots, 2),

                  DoubleToString(DDHistory[i].avgPrice, (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS)),

                  DDHistory[i].exitReason);

      }

    } else {

      // Write information row if 0 threshold events occurred during this run

      FileWrite(fileHandle,

                GetCurrentFormattedDate(),

                "N/A",

                "N/A",

                "N/A",

                "0.00",

                DoubleToString(OverallMaxDDObserved, 2),

                "0.00%",

                "NONE",

                "0",

                "0.00",

                "0.00",

                StringFormat("No events >= $%.2f (Peak DD Observed: $%.2f)", DDLogThreshold, OverallMaxDDObserved));

    }



    FileClose(fileHandle);

  }

}



//+------------------------------------------------------------------+

//| SAVE / REWRITE FULL DRAWDOWN CSV LOG WITH UPDATED AMOUNTS        |

//+------------------------------------------------------------------+



void SaveFullDDLogToCSV() {

  string filename = (DDLogFileName != "" ? DDLogFileName : "DD_50000_Log.csv");



  // 1. Write to Terminal Common Files folder (accessible across backtests and live charts)

  WriteCSVToFileHandle(filename, FILE_COMMON);



  // 2. Also write to Local Files folder

  WriteCSVToFileHandle(filename, 0);

}



//+------------------------------------------------------------------+

//| PREDICTION / OUTCOME LOG                                         |

//+------------------------------------------------------------------+



string BuildBlockedFlags(bool buyBlocked, bool sellBlocked) {

  if (buyBlocked && sellBlocked) return "BUY+SELL";

  if (buyBlocked) return "BUY";

  if (sellBlocked) return "SELL";

  return "NONE";

}



void WritePredictionCSVToFileHandle(string filename, int commonFlag) {

  int flags = FILE_WRITE | FILE_CSV | FILE_ANSI | FILE_SHARE_READ | FILE_SHARE_WRITE;

  if (commonFlag != 0)

    flags |= commonFlag;



  int fileHandle = FileOpen(filename, flags, ',');

  if (fileHandle != INVALID_HANDLE) {

    FileWrite(fileHandle,

              "Date",

              "Cycle_Start_Time",

              "Cycle_Close_Time",

              "Predicted_Direction",

              "SR_Blocked_Side",

              "Trend_Blocked_Side",

              "Side_Opened",

              "Actual_Side_Filled",

              "Net_Profit_USD",

              "Max_Grid_Level",

              "First_Time_Win",

              "Prediction_Correct",

              "Final_Result",

              "Exit_Reason");



    int total = ArraySize(PredictionLog);

    for (int i = 0; i < total; i++) {

      FileWrite(fileHandle,

                PredictionLog[i].dateStr,

                TimeToString(PredictionLog[i].cycleStartTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS),

                TimeToString(PredictionLog[i].cycleCloseTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS),

                PredictionLog[i].predictedDirection,

                PredictionLog[i].srBlocked,

                PredictionLog[i].trendBlocked,

                PredictionLog[i].sideOpened,

                PredictionLog[i].actualSide,

                DoubleToString(PredictionLog[i].netProfit, 2),

                IntegerToString(PredictionLog[i].maxGridLevel),

                PredictionLog[i].firstTimeWin,

                PredictionLog[i].predictionCorrect,

                PredictionLog[i].finalResult,

                PredictionLog[i].exitReason);

    }



    FileClose(fileHandle);

  }

}



void SavePredictionLogToCSV() {

  if (!EnablePredictionLog)

    return;



  string filename = (PredictionLogFileName != "" ? PredictionLogFileName : "GT_Prediction_Log.csv");



  // 1. Terminal Common Files folder (survives across chart instances/backtests)

  WritePredictionCSVToFileHandle(filename, FILE_COMMON);



  // 2. Local Files folder too

  WritePredictionCSVToFileHandle(filename, 0);

}



void AppendPredictionLogEntry(SPredictionLogEntry &entry) {

  int idx = ArraySize(PredictionLog);

  ArrayResize(PredictionLog, idx + 1);

  PredictionLog[idx] = entry;

  if (!MQLInfoInteger(MQL_TESTER)) {

    SavePredictionLogToCSV();

  }

}



// Used when a cycle is SKIPPED entirely (prediction/filters left no valid

// side to open) - there is nothing to wait for, so the row is written

// immediately instead of at basket close.

void LogPredictionCycle(ENUM_PREDICTED_DIRECTION prediction, bool allowBuy, bool allowSell,

                         bool srBlockedBuy, bool srBlockedSell, bool trendBlockedBuy, bool trendBlockedSell,

                         double ask, double bid, string sideOpened, string actualSide,

                         double netProfit, int maxGridLevel, string exitReason) {

  if (!EnablePredictionLog)

    return;



  SPredictionLogEntry e;

  e.dateStr            = GetCurrentFormattedDate();

  e.cycleStartTime     = TimeCurrent();

  e.cycleCloseTime     = TimeCurrent();

  e.predictedDirection = (prediction == PRED_BUY ? "BUY" : (prediction == PRED_SELL ? "SELL" : "SIDEWAYS"));

  e.srBlocked          = BuildBlockedFlags(srBlockedBuy, srBlockedSell);

  e.trendBlocked       = BuildBlockedFlags(trendBlockedBuy, trendBlockedSell);

  e.sideOpened         = sideOpened;

  e.actualSide         = actualSide;

  e.netProfit          = netProfit;

  e.maxGridLevel       = maxGridLevel;

  e.firstTimeWin       = "N/A";

  e.predictionCorrect  = "N/A";

  e.finalResult        = "SKIPPED";

  e.exitReason         = exitReason;



  AppendPredictionLogEntry(e);

}



// Called from every basket-close path once a cycle that was actually

// opened (CurrentPrediction.active == true) finishes, win or lose.

void LogPredictionOutcome(string exitReason) {

  if (!EnablePredictionLog || !CurrentPrediction.active)

    return;



  HistorySelect(CurrentPrediction.cycleStartTime - 5, TimeCurrent() + 5);



  double netProfit    = 0.0;

  string actualSide   = "NONE";

  datetime firstInTime = 0;



  int totalDeals = HistoryDealsTotal();

  for (int i = 0; i < totalDeals; i++) {

    ulong dealTicket = HistoryDealGetTicket(i);

    if (dealTicket == 0)

      continue;

    if (HistoryDealGetString(dealTicket, DEAL_SYMBOL) != _Symbol)

      continue;



    ulong magic = HistoryDealGetInteger(dealTicket, DEAL_MAGIC);

    if (magic != MagicNumber && magic != ADXHedgeMagicNumber)

      continue;



    netProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT) +

                 HistoryDealGetDouble(dealTicket, DEAL_SWAP) +

                 HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);



    if (magic == MagicNumber) {

      ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(dealTicket, DEAL_ENTRY);

      if (entry == DEAL_ENTRY_IN) {

        datetime dealTime = (datetime)HistoryDealGetInteger(dealTicket, DEAL_TIME);

        if (firstInTime == 0 || dealTime < firstInTime) {

          firstInTime = dealTime;

          ENUM_DEAL_TYPE dtype = (ENUM_DEAL_TYPE)HistoryDealGetInteger(dealTicket, DEAL_TYPE);

          actualSide = (dtype == DEAL_TYPE_BUY) ? "BUY" : (dtype == DEAL_TYPE_SELL ? "SELL" : "NONE");

        }

      }

    }

  }



  string finalResult = (netProfit > 0) ? "WIN" : (netProfit < 0 ? "LOSS" : "BREAKEVEN");

  string firstTimeWin = (CycleMaxGridLevel <= 1 && netProfit > 0) ? "YES" : "NO";



  string predictionCorrect;

  if (CurrentPrediction.predictedDirection == "SIDEWAYS" || actualSide == "NONE") {

    predictionCorrect = "N/A";

  } else {

    predictionCorrect = (CurrentPrediction.predictedDirection == actualSide && netProfit > 0) ? "YES" : "NO";

  }



  SPredictionLogEntry e;

  e.dateStr            = GetCurrentFormattedDate(CurrentPrediction.cycleStartTime);

  e.cycleStartTime     = CurrentPrediction.cycleStartTime;

  e.cycleCloseTime     = TimeCurrent();

  e.predictedDirection = CurrentPrediction.predictedDirection;

  e.srBlocked          = BuildBlockedFlags(CurrentPrediction.srBlockedBuy, CurrentPrediction.srBlockedSell);

  e.trendBlocked       = BuildBlockedFlags(CurrentPrediction.trendBlockedBuy, CurrentPrediction.trendBlockedSell);

  e.sideOpened         = CurrentPrediction.sideOpened;

  e.actualSide         = actualSide;

  e.netProfit          = netProfit;

  e.maxGridLevel       = CycleMaxGridLevel;

  e.firstTimeWin       = firstTimeWin;

  e.predictionCorrect  = predictionCorrect;

  e.finalResult        = finalResult;

  e.exitReason         = exitReason;



  AppendPredictionLogEntry(e);



  CurrentPrediction.active = false;

}



//+------------------------------------------------------------------+

//| DRAWDOWN CYCLE CLOSURE HANDLER (LOGS PEAK DD & STATUS)           |

//+------------------------------------------------------------------+



void OnBasketCycleClosed(string exitReason) {

  if (DDThresholdLoggedThisCycle && ArraySize(DDHistory) > 0) {

    int idx = ArraySize(DDHistory) - 1;

    datetime closeTime = TimeCurrent();

    DDHistory[idx].closeTime    = closeTime;

    DDHistory[idx].exitReason   = exitReason;

    DDHistory[idx].maxDD        = CurrentCycleMaxDD;

    double baseBal = (DailyDeposit > 0 ? DailyDeposit : AccountInfoDouble(ACCOUNT_BALANCE));

    if (baseBal > 0) {

      DDHistory[idx].maxDDPct = (CurrentCycleMaxDD / baseBal) * 100.0;

    }



    int durationSec = (int)(closeTime - DDHistory[idx].gridStartTime);

    int dH = durationSec / 3600;

    int dM = (durationSec % 3600) / 60;

    int dS = durationSec % 60;



    Print("====================================================================");

    Print(">>> [DRAWDOWN 50k BASKET CYCLE CLOSED] <<<");

    Print("Date                  : ", DDHistory[idx].ddDate);

    Print("Grid Start Time       : ", TimeToString(DDHistory[idx].gridStartTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS));

    Print("Basket Close Time     : ", TimeToString(closeTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS));

    Print("Cycle Duration        : ", StringFormat("%02dh %02dm %02ds", dH, dM, dS));

    Print("Trigger Drawdown      : -$ ", DoubleToString(DDHistory[idx].hitDD, 2));

    Print("PEAK DRAWDOWN AMOUNT  : -$ ", DoubleToString(CurrentCycleMaxDD, 2), " (", DoubleToString(DDHistory[idx].maxDDPct, 2), "%)");

    Print("Exit Reason           : ", exitReason);

    Print("Max Grid Level        : ", DDHistory[idx].maxPositions);

    Print("Peak Total Lots       : ", DoubleToString(DDHistory[idx].maxLots, 2), " lots");

    Print("====================================================================");



    if (WriteDDLogToFile) {

      SaveFullDDLogToCSV();

    }

  }



  DDThresholdLoggedThisCycle = false;

  CurrentCycleMaxDD = 0.0;

}



//+------------------------------------------------------------------+

//| CHECK AND LOG DRAWDOWN THRESHOLD (E.G. >= $50,000)               |

//+------------------------------------------------------------------+



void CheckAndLogDrawdown(ENUM_POSITION_TYPE direction, int openPositions) {

  if (!EnableDDLogging)

    return;



  double basketFloating = GetTotalFloatingProfit();

  double equityDD = MathMax(0.0, AccountInfoDouble(ACCOUNT_BALANCE) - AccountInfoDouble(ACCOUNT_EQUITY));

  double currentDD = MathMax(equityDD, (basketFloating < 0 ? MathAbs(basketFloating) : 0.0));

  int currentPositions = (openPositions >= 0 ? openPositions : CountPositions());

  double currentLots = GetBasketLots(direction);



  if (currentDD > CurrentCycleMaxDD) {

    CurrentCycleMaxDD = currentDD;

    // Update maxDD for current event if already recorded

    if (DDThresholdLoggedThisCycle && ArraySize(DDHistory) > 0) {

      int idx = ArraySize(DDHistory) - 1;

      DDHistory[idx].maxDD = CurrentCycleMaxDD;

      double baseBal = (DailyDeposit > 0 ? DailyDeposit : AccountInfoDouble(ACCOUNT_BALANCE));

      if (baseBal > 0) {

        DDHistory[idx].maxDDPct = (CurrentCycleMaxDD / baseBal) * 100.0;

      }

      if (currentPositions > DDHistory[idx].maxPositions) {

        DDHistory[idx].maxPositions = currentPositions;

      }

      if (currentLots > DDHistory[idx].maxLots) {

        DDHistory[idx].maxLots = currentLots;

      }

    }

  }



  if (currentDD >= DDLogThreshold) {

    if (!DDThresholdLoggedThisCycle) {

      DDThresholdLoggedThisCycle = true;



      datetime gridStartTime = GetBasketFirstOpenTime(direction);

      if (gridStartTime <= 0)

        gridStartTime = TimeCurrent();



      datetime ddHitTime = TimeCurrent();

      int positions = currentPositions;

      double lots = GetBasketLots(direction);

      double avgPrice = GetWeightedAveragePrice(direction);

      int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

      double currentPrice = (direction == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK));

      string dirStr = (direction == POSITION_TYPE_BUY ? "BUY" : "SELL");

      string hitDateStr = GetCurrentFormattedDate(ddHitTime);

      string gridStartDateStr = GetCurrentFormattedDate(gridStartTime);

      double baseBal = (DailyDeposit > 0 ? DailyDeposit : AccountInfoDouble(ACCOUNT_BALANCE));

      double hitDDPct = (baseBal > 0) ? (currentDD / baseBal) * 100.0 : 0.0;



      // Record to history array

      int idx = ArraySize(DDHistory);

      ArrayResize(DDHistory, idx + 1);

      DDHistory[idx].ddDate        = hitDateStr;

      DDHistory[idx].gridStartTime = gridStartTime;

      DDHistory[idx].ddHitTime     = ddHitTime;

      DDHistory[idx].closeTime     = 0;

      DDHistory[idx].hitDD         = currentDD;

      DDHistory[idx].maxDD         = currentDD;

      DDHistory[idx].maxDDPct      = hitDDPct;

      DDHistory[idx].direction     = dirStr;

      DDHistory[idx].positions     = positions;

      DDHistory[idx].maxPositions  = positions;

      DDHistory[idx].lots          = lots;

      DDHistory[idx].maxLots       = lots;

      DDHistory[idx].avgPrice      = avgPrice;

      DDHistory[idx].currentPrice  = currentPrice;

      DDHistory[idx].exitReason    = "Active";



      // Real-time Console Print

      Print("====================================================================");

      Print(">>> [DRAWDOWN ALERT] THRESHOLD $", DoubleToString(DDLogThreshold, 2), " REACHED! <<<");

      Print("Occurrence #          : ", idx + 1);

      Print("Date (DD Reached)     : ", hitDateStr, " (", TimeToString(ddHitTime, TIME_DATE), ")");

      Print("Grid Start Time       : ", TimeToString(gridStartTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS), " (Date: ", gridStartDateStr, ")");

      Print("DD Trigger Time       : ", TimeToString(ddHitTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS));

      Print("DRAWDOWN AMOUNT       : -$ ", DoubleToString(currentDD, 2), " (Floating: $", DoubleToString(basketFloating, 2), " | ", DoubleToString(hitDDPct, 2), "%)");

      Print("Basket Direction      : ", dirStr);

      Print("Open Positions Count  : ", positions);

      Print("Total Open Volume     : ", DoubleToString(lots, 2), " lots");

      Print("Average Entry Price   : ", DoubleToString(avgPrice, digits));

      Print("Current Market Price  : ", DoubleToString(currentPrice, digits));

      Print("====================================================================");



      // Write to CSV file immediately

      if (WriteDDLogToFile) {

        SaveFullDDLogToCSV();

      }

    }

  }

}



//+------------------------------------------------------------------+

//| PRINT CONSOLIDATED DRAWDOWN SUMMARY REPORT                       |

//+------------------------------------------------------------------+



void PrintDDSummaryReport() {

  if (!EnableDDLogging)

    return;



  int totalEvents = ArraySize(DDHistory);

  Print("====================================================================");

  Print("         DRAWDOWN >= $", DoubleToString(DDLogThreshold, 2), " SUMMARY REPORT");

  Print("====================================================================");

  Print("Total Recorded Occurrences: ", totalEvents);

  Print("Peak Max DD Across Run    : $", DoubleToString(OverallMaxDDObserved, 2));



  if (totalEvents == 0) {

    Print("No drawdown events >= $", DoubleToString(DDLogThreshold, 2), " occurred during this execution / backtest.");

    Print("Peak Drawdown reached during the entire run was: $", DoubleToString(OverallMaxDDObserved, 2));

  } else {

    Print("------------------------------------------------------------------------------------------------------------------------------------------------------");

    Print(StringFormat("%-4s | %-12s | %-19s | %-19s | %-6s | %-15s | %-15s | %-9s | %-8s | %-18s",

                       "#", "DD Date", "Grid Start Time", "DD Trigger Time", "Dir", "Trigger DD ($)", "Peak DD ($)", "Peak DD %", "Lots", "Exit Reason"));

    Print("------------------------------------------------------------------------------------------------------------------------------------------------------");

    for (int i = 0; i < totalEvents; i++) {

      Print(StringFormat("%-4d | %-12s | %-19s | %-19s | %-6s | -$%-14.2f | -$%-14.2f | %-8.2f%% | %-8.2f | %-18s",

                         i + 1,

                         DDHistory[i].ddDate,

                         TimeToString(DDHistory[i].gridStartTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS),

                         TimeToString(DDHistory[i].ddHitTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS),

                         DDHistory[i].direction,

                         DDHistory[i].hitDD,

                         DDHistory[i].maxDD,

                         DDHistory[i].maxDDPct,

                         DDHistory[i].maxLots,

                         DDHistory[i].exitReason));

    }

    Print("------------------------------------------------------------------------------------------------------------------------------------------------------");

  }



  if (WriteDDLogToFile) {

    SaveFullDDLogToCSV();

    Print("--------------------------------------------------------------------");

    Print("CSV Log saved to Terminal Common Files (accessible across all backtests & live):");

    Print("  Folder   : Terminal/Common/Files/");

    Print("  File Name: ", (DDLogFileName != "" ? DDLogFileName : "DD_50000_Log.csv"));

    Print("  Full Path: C:\\Users\\bJaya\\AppData\\Roaming\\MetaQuotes\\Terminal\\Common\\Files\\", (DDLogFileName != "" ? DDLogFileName : "DD_50000_Log.csv"));

    Print("--------------------------------------------------------------------");

  }

  Print("====================================================================");

}



//+------------------------------------------------------------------+

//| DRAWDOWN CONTROL / BASKET STOP LOSS                              |

//+------------------------------------------------------------------+



bool CheckDrawdownControl(ENUM_POSITION_TYPE direction) {

  if (!EnableDDControl)

    return false;



  bool triggered = false;

  string reason = "";

  double totalFloating = GetTotalFloatingProfit();



  if (DDControlMode == DD_CONTROL_PERCENT) {

    double balance = (DailyDeposit > 0 ? DailyDeposit : AccountInfoDouble(ACCOUNT_BALANCE));

    if (balance > 0 && totalFloating < 0) {

      double ddPct = (MathAbs(totalFloating) / balance) * 100.0;

      if (ddPct >= MaxDrawdownPct) {

        triggered = true;

        reason = StringFormat("Max Drawdown %% Hit: %.2f%% >= %.2f%% (Base: $%.2f)", ddPct, MaxDrawdownPct, balance);

      }

    }

  } else if (DDControlMode == DD_CONTROL_MONEY) {

    if (totalFloating < 0 && MathAbs(totalFloating) >= MaxDrawdownMoney) {

      triggered = true;

      reason = StringFormat("Max Drawdown Money Hit: -$%.2f >= -$%.2f", MathAbs(totalFloating), MaxDrawdownMoney);

    }

  } else if (DDControlMode == DD_CONTROL_DISTANCE) {

    double averagePrice = GetWeightedAveragePrice(direction);

    if (averagePrice > 0) {

      double currentPrice = (direction == POSITION_TYPE_BUY ? SymbolInfoDouble(_Symbol, SYMBOL_BID) : SymbolInfoDouble(_Symbol, SYMBOL_ASK));

      double lossDistance = (direction == POSITION_TYPE_BUY ? averagePrice - currentPrice : currentPrice - averagePrice);

      if (lossDistance >= BasketStopLoss) {

        triggered = true;

        reason = StringFormat("Price Distance SL Hit: %.2f >= %.2f", lossDistance, BasketStopLoss);

      }

    }

  }



  if (!triggered)

    return false;



  datetime pauseUntil = TimeCurrent() + (datetime)(DDPauseHours * 3600);

  if (PauseRestOfDayOnDDControl) {

    pauseUntil = MathMax(pauseUntil, GetStartOfNextDay(TimeCurrent()));

  }

  DDResumeTime = pauseUntil;



  Print("==========================================");

  Print("DRAWDOWN CONTROL HIT - CLOSING ALL POSITIONS");

  Print("Reason            : ", reason);

  Print("Floating P/L      : $", DoubleToString(totalFloating, 2));

  Print("Pause Duration    : ", DoubleToString(DDPauseHours, 1), " hours");

  Print("Resume Trading At : ", TimeToString(DDResumeTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS));

  Print("==========================================");



  // 1. FIRST: close the hedge (must always close before the grid).

  CloseAllHedgePositions();

  Print("1. CLOSED HEDGE POSITION(S) BEFORE GRID");



  // 2. SECOND: close the grid basket itself.

  CloseBasket();

  Print("2. CLOSED GRID BASKET");



  RecordPositionClose();

  VirtualBasketTP = 0.0;

  ADXHedgeOpenedThisCycle = false;

  FridayHedgeLockedThisCycle = false;

  DeleteAllPendingOrders();



  CycleWasActive = false;

  LogPredictionOutcome("DD Control Hit (" + reason + ")");

  if (EnableDDLogging) {

    OnBasketCycleClosed("DD Control Hit (" + reason + ")");

  } else {

    DDThresholdLoggedThisCycle = false;

    CurrentCycleMaxDD = 0.0;

  }



  return true;

}



//+------------------------------------------------------------------+

//| CHECK BASKET MAX DURATION TIMEOUT (AUTO-CLOSE)                   |

//+------------------------------------------------------------------+



bool CheckBasketMaxDuration(ENUM_POSITION_TYPE direction) {

  if (!EnableMaxGridDuration || MaxGridDurationHours <= 0)

    return false;



  datetime firstOpenTime = GetBasketFirstOpenTime(direction);

  if (firstOpenTime <= 0)

    return false;



  datetime currentTime = TimeCurrent();

  double elapsedSeconds = (double)(currentTime - firstOpenTime);

  double elapsedHours = elapsedSeconds / 3600.0;



  if (elapsedHours < MaxGridDurationHours)

    return false;



  Print("==========================================");

  Print("BASKET MAX DURATION REACHED - CLOSING ALL POSITIONS");

  Print("Direction         : ", EnumToString(direction));

  Print("Basket Open Time  : ", TimeToString(firstOpenTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS));

  Print("Current Time      : ", TimeToString(currentTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS));

  Print("Elapsed Duration  : ", DoubleToString(elapsedHours, 2), " hours");

  Print("Max Allowed Hours : ", DoubleToString(MaxGridDurationHours, 2), " hours");

  Print("==========================================");



  // 1. FIRST: close any open hedge position(s).

  CloseAllHedgePositions();

  Print("1. CLOSED HEDGE POSITION(S) BEFORE GRID");



  // 2. SECOND: close the grid basket.

  CloseBasket();

  Print("2. CLOSED GRID BASKET ON TIMEOUT");



  RecordPositionClose();

  VirtualBasketTP = 0.0;

  ADXHedgeOpenedThisCycle = false;

  FridayHedgeLockedThisCycle = false;

  DeleteAllPendingOrders();



  CycleWasActive = false;

  LogPredictionOutcome("Max Duration Timeout");

  if (EnableDDLogging) {

    OnBasketCycleClosed("Max Duration Timeout");

  } else {

    DDThresholdLoggedThisCycle = false;

    CurrentCycleMaxDD = 0.0;

  }



  return true;

}



//+------------------------------------------------------------------+

//| CHECK MAX POSITIONS AUTO-CLOSE (CLOSE BASKET AT NTH POSITION)   |

//+------------------------------------------------------------------+



bool CheckMaxPositionsClose(ENUM_POSITION_TYPE direction, int positions) {

  if (!EnableMaxPositionsClose || MaxPositionsToClose <= 0)

    return false;



  if (positions < MaxPositionsToClose)

    return false;



  Print("==========================================");

  Print(">>> MAX POSITIONS LIMIT REACHED - CLOSING ALL POSITIONS <<<");

  Print("Direction         : ", EnumToString(direction));

  Print("Open Positions    : ", positions);

  Print("Configured Max Pos: ", MaxPositionsToClose);

  Print("Floating P/L      : $", DoubleToString(GetTotalFloatingProfit(), 2));

  Print("==========================================");



  // 1. FIRST: close any open hedge position(s).

  CloseAllHedgePositions();

  Print("1. CLOSED HEDGE POSITION(S) BEFORE GRID");



  // 2. SECOND: close the grid basket.

  CloseBasket();

  Print("2. CLOSED GRID BASKET ON MAX POSITIONS REACHED");



  RecordPositionClose();

  VirtualBasketTP = 0.0;

  ADXHedgeOpenedThisCycle = false;

  FridayHedgeLockedThisCycle = false;

  DeleteAllPendingOrders();



  if (PauseRestOfDayOnMaxPosClose) {

    MaxPosCloseResumeTime = GetStartOfNextDay(TimeCurrent());

    Print("3. TRADING PAUSED FOR REST OF THE DAY (Until: ", TimeToString(MaxPosCloseResumeTime, TIME_DATE | TIME_MINUTES | TIME_SECONDS), ")");

  }



  CycleWasActive = false;

  string exitReason = StringFormat("Max Positions Reached (%d)", positions);

  LogPredictionOutcome(exitReason);

  if (EnableDDLogging) {

    OnBasketCycleClosed(exitReason);

  } else {

    DDThresholdLoggedThisCycle = false;

    CurrentCycleMaxDD = 0.0;

  }



  return true;

}



//+------------------------------------------------------------------+

//| CLOSE BASKET                                                     |

//+------------------------------------------------------------------+



bool CloseBasket() {

  if (!IsMarketTradeable()) {

    return false;

  }



  bool allClosed = true;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    if (!trade.PositionClose(ticket)) {

      Print("POSITION CLOSE ERROR: Ticket #", ticket, " - ", trade.ResultRetcodeDescription());

      allClosed = false;

    }

  }

  return (allClosed && CountPositions() == 0);

}



//+------------------------------------------------------------------+

//| ADX HEDGE: CLOSE ALL HEDGE POSITIONS                             |

//+------------------------------------------------------------------+



bool CloseAllHedgePositions() {

  if (!IsMarketTradeable()) {

    return false;

  }



  bool allClosed = true;

  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != ADXHedgeMagicNumber)

      continue;



    if (!hedgeTrade.PositionClose(ticket)) {

      Print("HEDGE CLOSE ERROR: Ticket #", ticket, " - ", hedgeTrade.ResultRetcodeDescription());

      allClosed = false;

    } else {

      Print("Hedge closed. Ticket: ", ticket);

    }

  }

  return (allClosed && CountHedgePositions() == 0);

}



//+------------------------------------------------------------------+

//| ADX HEDGE: TOTAL FLOATING PROFIT OF OPEN HEDGE POSITIONS         |

//+------------------------------------------------------------------+



double GetHedgeFloatingProfit() {

  double total = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != ADXHedgeMagicNumber)

      continue;



    total +=

        PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);

  }



  return total;

}



//+------------------------------------------------------------------+

//| ADX HEDGE: COUNT OPEN HEDGE POSITIONS                            |

//+------------------------------------------------------------------+



int CountHedgePositions() {

  int count = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) == ADXHedgeMagicNumber) {

      count++;

    }

  }



  return count;

}



//+------------------------------------------------------------------+

//| ADX / FRIDAY HEDGE: GET TOTAL OPEN HEDGE VOLUME                  |

//+------------------------------------------------------------------+



double GetHedgeLots() {

  double total = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != ADXHedgeMagicNumber)

      continue;



    total += PositionGetDouble(POSITION_VOLUME);

  }



  return total;

}



//+------------------------------------------------------------------+

//| ADX HEDGE: GET CURRENT ADX VALUE                                 |

//+------------------------------------------------------------------+



double GetCurrentADXForHedge() {

  if (hADX_Hedge == INVALID_HANDLE) {

    hADX_Hedge = iADX(_Symbol, ADXHedgeTimeframe, ADXHedgePeriod);

    if (hADX_Hedge == INVALID_HANDLE)

      return 0.0;

  }



  double buf[1];

  if (CopyBuffer(hADX_Hedge, 0, 1, 1, buf) <= 0) {

    return 0.0;

  }



  return buf[0];

}



//+------------------------------------------------------------------+

//| ADX HEDGE: OPEN OPPOSITE HEDGE WHEN ADX EXCEEDS THRESHOLD        |

//| Multiplies sum of all open grid lots by ADXHedgeLotMultiplier    |

//+------------------------------------------------------------------+



void ManageADXHedge(ENUM_POSITION_TYPE gridDirection) {

  if (!EnableADXHedge || FridayHedgeLockedThisCycle)

    return;



  // Only manage if there are active grid positions

  int gridPositions = CountPositions();

  if (gridPositions == 0) {

    ADXHedgeOpenedThisCycle = false;

    return;

  }



  // Check minimum required open grid positions (default 5)

  if (gridPositions < ADXHedgeMinGrids)

    return;



  // If any hedge position is already active, do not open duplicate hedges

  if (CountHedgePositions() > 0)

    return;



  // If already triggered for this active basket, do not re-trigger

  if (ADXHedgeOpenedThisCycle)

    return;



  double currentADX = GetCurrentADXForHedge();

  if (currentADX <= 0.0)

    return;



  // Check if ADX exceeds configurable threshold (e.g. 30.0)

  if (currentADX >= ADXHedgeThreshold) {

    double totalGridLots = GetBasketLots(gridDirection);

    if (totalGridLots <= 0.0)

      return;



    // Hedge volume = Sum of all open grid lots multiplied by ADXHedgeLotMultiplier (e.g. 3.0x)

    double rawHedgeLot = totalGridLots * ADXHedgeLotMultiplier;

    double hedgeLot = NormalizeLotRound(rawHedgeLot);



    double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

    double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

    hedgeLot = MathMax(minLot, MathMin(hedgeLot, maxLot));



    bool result = false;



    // Grid basket is BUY -> Open SELL hedge. Grid basket is SELL -> Open BUY hedge.

    if (gridDirection == POSITION_TYPE_BUY) {

      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

      if (bid <= 0) return;

      result = hedgeTrade.Sell(hedgeLot, _Symbol, 0, 0, 0, EAComment + "_ADX_HEDGE");

    } else {

      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      if (ask <= 0) return;

      result = hedgeTrade.Buy(hedgeLot, _Symbol, 0, 0, 0, EAComment + "_ADX_HEDGE");

    }



    if (result) {

      ADXHedgeOpenedThisCycle = true;



      Print("==========================================");

      Print(">>> ADX HEDGE TRIGGERED & OPENED <<<");

      Print("Current ADX (" + EnumToString(ADXHedgeTimeframe) + ", Period " + IntegerToString(ADXHedgePeriod) + ") : ", DoubleToString(currentADX, 2), " >= ", DoubleToString(ADXHedgeThreshold, 2));

      Print("Basket Direction   : ", (gridDirection == POSITION_TYPE_BUY ? "BUY" : "SELL"));

      Print("Sum of Grid Lots   : ", DoubleToString(totalGridLots, 2));

      Print("ADX Multiplier     : ", DoubleToString(ADXHedgeLotMultiplier, 2), "x");

      Print("Opened Hedge Lot   : ", DoubleToString(hedgeLot, 2));

      Print("Grid additions continue up to maximum grid levels.");

      Print("==========================================");





    } else {

      Print("==========================================");

      Print("ADX HEDGE OPEN ERROR: ", hedgeTrade.ResultRetcodeDescription());

      Print("==========================================");

    }

  }

}



//+------------------------------------------------------------------+

//| OFFLINE NEWS CSV HELPER FUNCTIONS                                |

//+------------------------------------------------------------------+



datetime ParseCSVDateTime(string dateStr, string timeStr) {

  StringTrimLeft(dateStr);

  StringTrimRight(dateStr);

  StringTrimLeft(timeStr);

  StringTrimRight(timeStr);



  if (StringLen(timeStr) == 0) {

    int spaceIdx = StringFind(dateStr, " ");

    if (spaceIdx > 0) {

      timeStr = StringSubstr(dateStr, spaceIdx + 1);

      dateStr = StringSubstr(dateStr, 0, spaceIdx);

      StringTrimLeft(timeStr);

      StringTrimRight(timeStr);

      StringTrimRight(dateStr);

    }

  }



  // Parse Date

  int year = 0, month = 0, day = 0;

  StringReplace(dateStr, "/", ".");

  StringReplace(dateStr, "-", ".");



  string dateParts[];

  int numParts = StringSplit(dateStr, '.', dateParts);

  if (numParts == 3) {

    if (StringLen(dateParts[0]) == 4) { // YYYY.MM.DD

      year  = (int)StringToInteger(dateParts[0]);

      month = (int)StringToInteger(dateParts[1]);

      day   = (int)StringToInteger(dateParts[2]);

    } else if (StringLen(dateParts[2]) == 4) { // MM.DD.YYYY or DD.MM.YYYY

      year = (int)StringToInteger(dateParts[2]);

      int p0 = (int)StringToInteger(dateParts[0]);

      int p1 = (int)StringToInteger(dateParts[1]);

      if (p0 > 12) { day = p0; month = p1; } // DD.MM.YYYY

      else { month = p0; day = p1; }         // MM.DD.YYYY

    }

  }

  if (year <= 1970)

    return 0;



  // Parse Time

  int hour = 0, min = 0, sec = 0;

  string timeUpper = timeStr;

  StringToUpper(timeUpper);

  bool isPM = (StringFind(timeUpper, "PM") >= 0);

  bool isAM = (StringFind(timeUpper, "AM") >= 0);

  StringReplace(timeUpper, "AM", "");

  StringReplace(timeUpper, "PM", "");

  StringTrimLeft(timeUpper);

  StringTrimRight(timeUpper);



  string timeParts[];

  int numTimeParts = StringSplit(timeUpper, ':', timeParts);

  if (numTimeParts >= 2) {

    hour = (int)StringToInteger(timeParts[0]);

    min  = (int)StringToInteger(timeParts[1]);

    if (numTimeParts >= 3)

      sec = (int)StringToInteger(timeParts[2]);



    if (isPM && hour < 12)

      hour += 12;

    if (isAM && hour == 12)

      hour = 0;

  }



  MqlDateTime dt;

  dt.year = year;

  dt.mon  = month;

  dt.day  = day;

  dt.hour = hour;

  dt.min  = min;

  dt.sec  = sec;



  return StructToTime(dt);

}



bool IsCurrencyMatched(string cur) {

  if (StringLen(InpNewsCurrencies) == 0)

    return true;



  string curUpper = cur;

  StringToUpper(curUpper);

  StringTrimLeft(curUpper);

  StringTrimRight(curUpper);



  string filterCurrencies = InpNewsCurrencies;

  StringToUpper(filterCurrencies);



  string curParts[];

  int n = StringSplit(filterCurrencies, ',', curParts);

  for (int i = 0; i < n; i++) {

    string target = curParts[i];

    StringTrimLeft(target);

    StringTrimRight(target);

    if (target == curUpper)

      return true;

  }

  return false;

}



bool IsImpactMatched(string impact) {

  string impUpper = impact;

  StringToUpper(impUpper);

  StringTrimLeft(impUpper);

  StringTrimRight(impUpper);



  if (StringFind(impUpper, "HIGH") >= 0 || impUpper == "RED" || impUpper == "3")

    return true;



  if (!InpNewsFilterHighOnly) {

    if (StringFind(impUpper, "MEDIUM") >= 0 || StringFind(impUpper, "MED") >= 0 || impUpper == "ORANGE" || impUpper == "2")

      return true;

  }



  return false;

}



void QuickSortOfflineNews(int left, int right) {

  if (left >= right)

    return;



  int i = left;

  int j = right;

  datetime pivot = OfflineNewsList[(left + right) / 2].eventTime;



  while (i <= j) {

    while (OfflineNewsList[i].eventTime < pivot)

      i++;

    while (OfflineNewsList[j].eventTime > pivot)

      j--;

    if (i <= j) {

      SOfflineNewsEvent tmp = OfflineNewsList[i];

      OfflineNewsList[i] = OfflineNewsList[j];

      OfflineNewsList[j] = tmp;

      i++;

      j--;

    }

  }



  if (left < j)

    QuickSortOfflineNews(left, j);

  if (i < right)

    QuickSortOfflineNews(i, right);

}



void LoadOfflineNewsCSV() {

  OfflineNewsCount = 0;

  ArrayResize(OfflineNewsList, 0);



  if (!InpEnableNewsFilter || !InpUseOfflineNewsCSV)

    return;



  int flags = FILE_READ | FILE_TXT | FILE_ANSI | FILE_SHARE_READ;

  if (InpNewsCSVCommonDir)

    flags |= FILE_COMMON;



  int fileHandle = FileOpen(InpNewsCSVFileName, flags);

  if (fileHandle == INVALID_HANDLE) {

    Print("[NEWS CSV] Notice: File '", InpNewsCSVFileName, "' not found in ",

          (InpNewsCSVCommonDir ? "Common/Files" : "MQL5/Files"),

          ". Fallback to live calendar or unfiltered in tester.");

    return;

  }



  int colDate = -1, colTime = -1, colCur = -1, colImp = -1, colTitle = -1;



  while (!FileIsEnding(fileHandle)) {

    string line = FileReadString(fileHandle);

    StringTrimLeft(line);

    StringTrimRight(line);

    if (StringLen(line) == 0)

      continue;

    if (StringSubstr(line, 0, 1) == "#")

      continue; // Skip comments



    string cols[];

    int numCols = StringSplit(line, ',', cols);

    if (numCols < 3)

      continue;



    // Clean quotes and whitespace

    for (int c = 0; c < numCols; c++) {

      StringTrimLeft(cols[c]);

      StringTrimRight(cols[c]);

      int len = StringLen(cols[c]);

      if (len >= 2 && StringSubstr(cols[c], 0, 1) == "\"" && StringSubstr(cols[c], len - 1, 1) == "\"") {

        cols[c] = StringSubstr(cols[c], 1, len - 2);

        StringTrimLeft(cols[c]);

        StringTrimRight(cols[c]);

      }

    }



    // Check for header row

    string c0Upper = cols[0];

    StringToUpper(c0Upper);

    if (StringFind(c0Upper, "DATE") >= 0 || StringFind(c0Upper, "TIME") >= 0) {

      for (int c = 0; c < numCols; c++) {

        string h = cols[c];

        StringToUpper(h);

        if (StringFind(h, "DATE") >= 0 && colDate < 0)

          colDate = c;

        else if (StringFind(h, "TIME") >= 0 && colTime < 0)

          colTime = c;

        else if ((StringFind(h, "CUR") >= 0 || StringFind(h, "SYM") >= 0) && colCur < 0)

          colCur = c;

        else if ((StringFind(h, "IMP") >= 0 || StringFind(h, "SEV") >= 0) && colImp < 0)

          colImp = c;

        else if ((StringFind(h, "TITLE") >= 0 || StringFind(h, "EVENT") >= 0 || StringFind(h, "NAME") >= 0) && colTitle < 0)

          colTitle = c;

      }

      continue;

    }



    int useDateCol  = (colDate >= 0)  ? colDate  : 0;

    int useTimeCol  = (colTime >= 0)  ? colTime  : ((numCols >= 4) ? 1 : -1);

    int useCurCol   = (colCur >= 0)   ? colCur   : ((numCols >= 4) ? 2 : 1);

    int useImpCol   = (colImp >= 0)   ? colImp   : ((numCols >= 4) ? 3 : 2);

    int useTitleCol = (colTitle >= 0) ? colTitle : ((numCols >= 5) ? 4 : -1);



    string dateStr  = (useDateCol < numCols) ? cols[useDateCol] : "";

    string timeStr  = (useTimeCol >= 0 && useTimeCol < numCols) ? cols[useTimeCol] : "";

    string curStr   = (useCurCol < numCols) ? cols[useCurCol] : "";

    string impStr   = (useImpCol < numCols) ? cols[useImpCol] : "";

    string titleStr = (useTitleCol >= 0 && useTitleCol < numCols) ? cols[useTitleCol] : "High Impact News";



    datetime eventDt = ParseCSVDateTime(dateStr, timeStr);

    if (eventDt <= 0)

      continue;



    if (!IsCurrencyMatched(curStr))

      continue;



    if (!IsImpactMatched(impStr))

      continue;



    int sz = ArraySize(OfflineNewsList);

    ArrayResize(OfflineNewsList, sz + 1, 500);

    OfflineNewsList[sz].eventTime = eventDt;

    OfflineNewsList[sz].currency  = curStr;

    OfflineNewsList[sz].impact    = impStr;

    OfflineNewsList[sz].title     = titleStr;

  }



  FileClose(fileHandle);

  OfflineNewsCount = ArraySize(OfflineNewsList);



  if (OfflineNewsCount > 1) {

    QuickSortOfflineNews(0, OfflineNewsCount - 1);

  }



  Print("[NEWS CSV] Successfully loaded ", OfflineNewsCount, " offline news events from '", InpNewsCSVFileName, "'.");

}



//+------------------------------------------------------------------+

//| NEWS FILTER: DOES EVENT NAME MATCH AN ENABLED CATEGORY           |

//+------------------------------------------------------------------+



bool EventMatchesEnabledCategory(string nameUpper) {

  //===============================================================

  // Keyword matching against the live calendar's event name.

  // Multiple synonyms per category since exact wording can vary.

  // If a category never triggers for you, check the Experts log

  // (matched event names are printed) and add the exact wording

  // your broker's calendar feed uses.

  //===============================================================



  if (InpFilterFOMC_Rate) {

    if (StringFind(nameUpper, "FOMC STATEMENT") >= 0)

      return true;



    if (StringFind(nameUpper, "FED INTEREST RATE") >= 0)

      return true;



    if (StringFind(nameUpper, "FEDERAL FUNDS RATE") >= 0)

      return true;



    if (StringFind(nameUpper, "INTEREST RATE DECISION") >= 0)

      return true;

  }



  if (InpFilterFOMC_DotPlot) {

    if (StringFind(nameUpper, "ECONOMIC PROJECTIONS") >= 0)

      return true;



    if (StringFind(nameUpper, "DOT PLOT") >= 0)

      return true;

  }



  if (InpFilterFOMC_PressConf) {

    if (StringFind(nameUpper, "PRESS CONFERENCE") >= 0)

      return true;

  }



  if (InpFilterNFP) {

    if (StringFind(nameUpper, "NONFARM PAYROLLS") >= 0)

      return true;



    if (StringFind(nameUpper, "NON-FARM PAYROLLS") >= 0)

      return true;



    if (StringFind(nameUpper, "NFP") >= 0)

      return true;

  }



  if (InpFilterCPI) {

    if (StringFind(nameUpper, "CONSUMER PRICE INDEX") >= 0)

      return true;



    if (StringFind(nameUpper, "CPI") >= 0)

      return true;

  }



  if (InpFilterCorePCE) {

    if (StringFind(nameUpper, "CORE PCE") >= 0)

      return true;



    if (StringFind(nameUpper, "PCE PRICE INDEX") >= 0)

      return true;



    if (StringFind(nameUpper, "PERSONAL CONSUMPTION EXPENDITURES") >= 0)

      return true;

  }



  if (InpFilterGDP) {

    if (StringFind(nameUpper, "GDP") >= 0)

      return true;



    if (StringFind(nameUpper, "GROSS DOMESTIC PRODUCT") >= 0)

      return true;

  }



  if (InpFilterRetailSales) {

    if (StringFind(nameUpper, "RETAIL SALES") >= 0)

      return true;

  }



  if (InpFilterPPI) {

    if (StringFind(nameUpper, "PRODUCER PRICE INDEX") >= 0)

      return true;



    if (StringFind(nameUpper, "PPI") >= 0)

      return true;

  }



  if (InpFilterISM_PMI) {

    if (StringFind(nameUpper, "ISM MANUFACTURING") >= 0)

      return true;



    if (StringFind(nameUpper, "ISM SERVICES") >= 0)

      return true;



    if (StringFind(nameUpper, "ISM NON-MANUFACTURING") >= 0)

      return true;



    if (StringFind(nameUpper, "ISM PMI") >= 0)

      return true;

  }



  if (InpFilterJacksonHole) {

    if (StringFind(nameUpper, "JACKSON HOLE") >= 0)

      return true;

  }



  if (InpFilterFedChairSpeech) {

    if (StringFind(nameUpper, "FED CHAIR") >= 0)

      return true;



    if (StringFind(nameUpper, "FED CHAIRMAN") >= 0)

      return true;



    if (StringFind(nameUpper, "POWELL") >= 0)

      return true;



    if (StringFind(nameUpper, "FOMC MEMBER") >= 0)

      return true;

  }



  return false;

}



//+------------------------------------------------------------------+

//| NEWS FILTER: CHECK IF CURRENTLY INSIDE A HIGH-IMPACT BLACKOUT    |

//+------------------------------------------------------------------+



bool IsHighImpactNewsWindow() {

  if (!InpEnableNewsFilter)

    return false;



  //===============================================================

  // Throttle: recheck at most once every 30 seconds. The calendar

  // doesn't change fast enough to need per-tick queries.

  //===============================================================



  if (TimeCurrent() - NewsLastCheckTime < 30)

    return NewsBlackoutActive;



  NewsLastCheckTime = TimeCurrent();



  //===============================================================

  // OFFLINE CSV NEWS CHECK (Works in both Tester and Live)

  //===============================================================

  if (InpUseOfflineNewsCSV && OfflineNewsCount > 0) {

    datetime curTime = TimeCurrent();

    bool blackout = false;

    string matchedName = "";



    for (int i = 0; i < OfflineNewsCount; i++) {

      datetime eventTime = OfflineNewsList[i].eventTime;



      if (InpNewsGmtMode == 1) {

        eventTime += InpNewsGmtOffset * 3600;

      }



      datetime windowStart = eventTime - InpNewsBeforeMinutes * 60;

      datetime windowEnd   = eventTime + InpNewsAfterMinutes * 60;



      if (curTime >= windowStart && curTime <= windowEnd) {

        blackout = true;

        matchedName = OfflineNewsList[i].title + " (" + OfflineNewsList[i].currency + ")";

        break;

      }



      if (eventTime - InpNewsBeforeMinutes * 60 > curTime)

        break; // Events are sorted chronologically

    }



    if (blackout && !NewsBlackoutActive) {

      Print("==========================================");

      Print("NEWS BLACKOUT STARTED: ", matchedName);

      Print("==========================================");

    }



    if (!blackout && NewsBlackoutActive) {

      Print("==========================================");

      Print("NEWS BLACKOUT ENDED");

      Print("==========================================");

    }



    NewsBlackoutActive = blackout;

    NewsActiveEventName = matchedName;



    return blackout;

  }



  int lookbackMinutes = InpNewsAfterMinutes + 5;

  int lookaheadMinutes = InpNewsBeforeMinutes + 5;



  datetime rangeFrom = TimeCurrent() - lookbackMinutes * 60;



  datetime rangeTo = TimeCurrent() + lookaheadMinutes * 60;



  MqlCalendarValue values[];



  int total = CalendarValueHistory(values, rangeFrom, rangeTo, NULL, "USD");



  //===============================================================

  // FAIL-SAFE: if the calendar query itself fails (no internet,

  // broker doesn't support it, etc), treat it as a blackout rather

  // than silently trading with no protection at all. This is

  // logged clearly so it's visible if it happens.

  // In Strategy Tester: if broker doesn't synchronize calendar data,

  // do not permanently lock up trading.

  //===============================================================



  if (total < 0) {

    if (!MQLInfoInteger(MQL_TESTER)) {

      Print("NEWS FILTER: Calendar query FAILED (error ", GetLastError(),

            "). Blocking trading until it recovers (fail-safe).");



      NewsBlackoutActive = true;

      NewsActiveEventName = "CALENDAR UNAVAILABLE";



      return true;

    } else {

      static bool s_TesterCalendarWarned = false;

      if (!s_TesterCalendarWarned) {

        Print("NEWS FILTER [TESTER NOTICE]: CalendarValueHistory query returned no data (error ", GetLastError(),

              "). Strategy Tester proceeding with tick data.");

        s_TesterCalendarWarned = true;

      }

      NewsBlackoutActive = false;

      NewsActiveEventName = "";

      return false;

    }

  }



  bool blackout = false;

  string matchedName = "";



  for (int i = 0; i < total; i++) {

    MqlCalendarEvent ev;



    if (!CalendarEventById(values[i].event_id, ev))

      continue;



    if (ev.importance != CALENDAR_IMPORTANCE_HIGH)

      continue;



    string nameUpper = ev.name;



    StringToUpper(nameUpper);



    if (!EventMatchesEnabledCategory(nameUpper))

      continue;



    datetime eventTime = values[i].time;



    if (InpNewsGmtMode == 1) {

      eventTime += InpNewsGmtOffset * 3600;

    }



    datetime windowStart = eventTime - InpNewsBeforeMinutes * 60;



    datetime windowEnd = eventTime + InpNewsAfterMinutes * 60;



    if (TimeCurrent() >= windowStart && TimeCurrent() <= windowEnd) {

      blackout = true;

      matchedName = ev.name;

      break;

    }

  }



  if (blackout && !NewsBlackoutActive) {

    Print("==========================================");

    Print("NEWS BLACKOUT STARTED: ", matchedName);

    Print("==========================================");

  }



  if (!blackout && NewsBlackoutActive) {

    Print("==========================================");

    Print("NEWS BLACKOUT ENDED");

    Print("==========================================");

  }



  NewsBlackoutActive = blackout;

  NewsActiveEventName = matchedName;



  return blackout;

}



//+------------------------------------------------------------------+

//| DELETE OPPOSITE PENDING ORDERS                                   |

//+------------------------------------------------------------------+



void DeleteOppositePendingOrders(ENUM_POSITION_TYPE direction) {

  for (int i = OrdersTotal() - 1; i >= 0; i--) {

    ulong ticket = OrderGetTicket(i);



    if (ticket == 0)

      continue;



    if (!OrderSelect(ticket))

      continue;



    if (OrderGetString(ORDER_SYMBOL) != _Symbol)

      continue;



    if ((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)

      continue;



    ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);



    bool deleteOrder = false;



    // For an active BUY basket, the ONLY valid grid order is a BUY_LIMIT.

    // Any other order type (initial stops, opposite limits) must be deleted.

    if (direction == POSITION_TYPE_BUY) {

      if (type != ORDER_TYPE_BUY_LIMIT) {

        deleteOrder = true;

      }

    }



    // For an active SELL basket, the ONLY valid grid order is a SELL_LIMIT.

    // Any other order type (initial stops, opposite limits) must be deleted.

    if (direction == POSITION_TYPE_SELL) {

      if (type != ORDER_TYPE_SELL_LIMIT) {

        deleteOrder = true;

      }

    }



    if (deleteOrder) {

      if (trade.OrderDelete(ticket)) {

        Print("Stale/opposite pending order deleted: Ticket #", ticket, " Type: ", EnumToString(type));

      } else {

        Print("PENDING DELETE ERROR: Ticket #", ticket, " Error: ", trade.ResultRetcodeDescription());

      }

    }

  }

}



//+------------------------------------------------------------------+

//| DELETE ALL PENDING ORDERS                                        |

//+------------------------------------------------------------------+



void DeleteAllPendingOrders() {

  for (int i = OrdersTotal() - 1; i >= 0; i--) {

    ulong ticket = OrderGetTicket(i);



    if (ticket == 0)

      continue;



    if (!OrderSelect(ticket))

      continue;



    if (OrderGetString(ORDER_SYMBOL) != _Symbol)

      continue;



    if ((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)

      continue;



    ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);



    if (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||

        type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||

        type == ORDER_TYPE_BUY_STOP_LIMIT ||

        type == ORDER_TYPE_SELL_STOP_LIMIT) {

      if (!trade.OrderDelete(ticket)) {

        Print("PENDING DELETE ERROR");

        Print("Ticket : ", ticket);

        Print("Error  : ", trade.ResultRetcodeDescription());

      }

    }

  }

}



//+------------------------------------------------------------------+

//| COUNT POSITIONS                                                  |

//+------------------------------------------------------------------+



int CountPositions() {

  int count = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    count++;

  }



  return count;

}



//+------------------------------------------------------------------+

//| COUNT PENDING ORDERS                                             |

//+------------------------------------------------------------------+



int CountPendingOrders() {

  int count = 0;



  for (int i = OrdersTotal() - 1; i >= 0; i--) {

    ulong ticket = OrderGetTicket(i);



    if (ticket == 0)

      continue;



    if (!OrderSelect(ticket))

      continue;



    if (OrderGetString(ORDER_SYMBOL) != _Symbol)

      continue;



    if ((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber)

      continue;



    ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);



    if (type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_SELL_STOP ||

        type == ORDER_TYPE_BUY_LIMIT || type == ORDER_TYPE_SELL_LIMIT ||

        type == ORDER_TYPE_BUY_STOP_LIMIT ||

        type == ORDER_TYPE_SELL_STOP_LIMIT) {

      count++;

    }

  }



  return count;

}



//+------------------------------------------------------------------+

//| GET BASKET DIRECTION                                             |

//+------------------------------------------------------------------+



ENUM_POSITION_TYPE GetBasketDirection() {

  double buyLots = 0;

  double sellLots = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    ENUM_POSITION_TYPE type =

        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);



    double volume = PositionGetDouble(POSITION_VOLUME);



    if (type == POSITION_TYPE_BUY)

      buyLots += volume;



    if (type == POSITION_TYPE_SELL)

      sellLots += volume;

  }



  if (buyLots >= sellLots)

    return POSITION_TYPE_BUY;



  return POSITION_TYPE_SELL;

}



//+------------------------------------------------------------------+

//| WEIGHTED AVERAGE PRICE                                          |

//+------------------------------------------------------------------+



double GetWeightedAveragePrice(ENUM_POSITION_TYPE direction) {

  double totalVolume = 0;

  double totalValue = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    ENUM_POSITION_TYPE type =

        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);



    if (type != direction)

      continue;



    double volume = PositionGetDouble(POSITION_VOLUME);



    double price = PositionGetDouble(POSITION_PRICE_OPEN);



    totalVolume += volume;



    totalValue += price * volume;

  }



  if (totalVolume <= 0)

    return 0;



  return totalValue / totalVolume;

}



//+------------------------------------------------------------------+

//| GET BASKET LOTS                                                  |

//+------------------------------------------------------------------+



double GetBasketLots(ENUM_POSITION_TYPE direction) {

  double total = 0;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    ENUM_POSITION_TYPE type =

        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);



    if (type == direction) {

      total += PositionGetDouble(POSITION_VOLUME);

    }

  }



  return total;

}



//+------------------------------------------------------------------+

//| GET LAST ENTRY PRICE                                             |

//+------------------------------------------------------------------+



double GetLastEntryPrice(ENUM_POSITION_TYPE direction) {

  double frontierPrice = 0;

  bool found = false;



  for (int i = PositionsTotal() - 1; i >= 0; i--) {

    ulong ticket = PositionGetTicket(i);



    if (ticket == 0)

      continue;



    if (!PositionSelectByTicket(ticket))

      continue;



    if (PositionGetString(POSITION_SYMBOL) != _Symbol)

      continue;



    if ((ulong)PositionGetInteger(POSITION_MAGIC) != MagicNumber)

      continue;



    ENUM_POSITION_TYPE type =

        (ENUM_POSITION_TYPE)PositionGetInteger(POSITION_TYPE);



    if (type != direction)

      continue;



    double openPrice = PositionGetDouble(POSITION_PRICE_OPEN);



    if (!found) {

      frontierPrice = openPrice;

      found = true;

    } else {

      if (direction == POSITION_TYPE_BUY) {

        if (openPrice < frontierPrice)

          frontierPrice = openPrice; // Lowest BUY open price

      } else {

        if (openPrice > frontierPrice)

          frontierPrice = openPrice; // Highest SELL open price

      }

    }

  }



  return frontierPrice;

}



//+------------------------------------------------------------------+

//| NORMALIZE LOT                                                    |

//+------------------------------------------------------------------+



double NormalizeLotRound(double lot) {

  double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);



  double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);



  double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);



  if (step <= 0)

    step = 0.01;



  if (lot < minLot)

    lot = minLot;



  if (lot > maxLot)

    lot = maxLot;



  lot = MathRound(lot / step) * step;



  if (lot < minLot)

    lot = minLot;



  if (lot > maxLot)

    lot = maxLot;



  return NormalizeDouble(lot, VolumeDigits(step));

}



//+------------------------------------------------------------------+

//| VOLUME DIGITS                                                    |

//+------------------------------------------------------------------+



int VolumeDigits(double step) {

  if (step >= 1.0)

    return 0;



  if (step >= 0.1)

    return 1;



  if (step >= 0.01)

    return 2;



  return 3;

}



//+------------------------------------------------------------------+

//| NORMALIZE PRICE                                                  |

//+------------------------------------------------------------------+



double NormalizePrice(double price) {

  int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);



  return NormalizeDouble(price, digits);

}



//+------------------------------------------------------------------+

//| SYMBOL TICK SIZE                                                 |

//+------------------------------------------------------------------+



double SymbolTickSize() {

  double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);



  if (tick <= 0) {

    tick = SymbolInfoDouble(_Symbol, SYMBOL_POINT);

  }



  return tick;

}



//+------------------------------------------------------------------+

//| GET SESSION CLOCK TIME (AUTO-ADAPTED TO GMT)                     |

//+------------------------------------------------------------------+



datetime GetSessionCurrentTime() {

  if (!AutoAdaptSessionGMT || MQLInfoInteger(MQL_TESTER))

    return TimeCurrent();



  datetime gmt = TimeGMT();

  if (gmt > 0) {

    return gmt + (datetime)(SessionsBaseGMT * 3600);

  }



  return TimeCurrent();

}



// Session Time Minute Caches (Pre-parsed once at OnInit for ultra-fast tester execution)

int g_Session1StartMin = -1;

int g_Session1EndMin   = -1;

int g_Session2StartMin = -1;

int g_Session2EndMin   = -1;

int g_Session3StartMin = -1;

int g_Session3EndMin   = -1;

int g_Session4StartMin = -1;

int g_Session4EndMin   = -1;

int g_Session5StartMin = -1;

int g_Session5EndMin   = -1;

int g_FridayCutoffMin  = -1;



void InitSessionTimeCaches() {

  g_Session1StartMin = StringToMinutes(Session1Start);

  g_Session1EndMin   = StringToMinutes(Session1End);

  g_Session2StartMin = StringToMinutes(Session2Start);

  g_Session2EndMin   = StringToMinutes(Session2End);

  g_Session3StartMin = StringToMinutes(Session3Start);

  g_Session3EndMin   = StringToMinutes(Session3End);

  g_Session4StartMin = StringToMinutes(Session4Start);

  g_Session4EndMin   = StringToMinutes(Session4End);

  g_Session5StartMin = StringToMinutes(Session5Start);

  g_Session5EndMin   = StringToMinutes(Session5End);

  g_FridayCutoffMin  = StringToMinutes(FridayCutoffTime);

  g_FridayBasketActionMin  = StringToMinutes(FridayBasketActionTime);

  g_MondayHedgeUnfreezeMin = StringToMinutes(MondayHedgeUnfreezeTime);

}



//+------------------------------------------------------------------+

//| CHECK TIME RANGE FAST (INTEGER MINUTES)                          |

//+------------------------------------------------------------------+



bool IsTimeInRangeFast(int currentMinutes, int start, int end) {

  if (start < 0 || end < 0 || start == end)

    return false;



  // Normal session

  if (start < end) {

    return (currentMinutes >= start && currentMinutes < end);

  }



  // Overnight session

  return (currentMinutes >= start || currentMinutes < end);

}



//+------------------------------------------------------------------+

//| CHECK ANY SESSION                                                |

//+------------------------------------------------------------------+



bool IsInsideAnySession() {

  MqlDateTime tm;



  TimeToStruct(GetSessionCurrentTime(), tm);



  int currentMinutes = tm.hour * 60 + tm.min;



  if (EnableSession1 &&

      IsTimeInRangeFast(currentMinutes, g_Session1StartMin, g_Session1EndMin))

    return true;



  if (EnableSession2 &&

      IsTimeInRangeFast(currentMinutes, g_Session2StartMin, g_Session2EndMin))

    return true;



  if (EnableSession3 &&

      IsTimeInRangeFast(currentMinutes, g_Session3StartMin, g_Session3EndMin))

    return true;



  if (EnableSession4 &&

      IsTimeInRangeFast(currentMinutes, g_Session4StartMin, g_Session4EndMin))

    return true;



  if (EnableSession5 &&

      IsTimeInRangeFast(currentMinutes, g_Session5StartMin, g_Session5EndMin))

    return true;



  return false;

}



//+------------------------------------------------------------------+

//| GET CURRENT SESSION                                              |

//+------------------------------------------------------------------+



string GetCurrentSession() {

  MqlDateTime tm;



  TimeToStruct(GetSessionCurrentTime(), tm);



  int currentMinutes = tm.hour * 60 + tm.min;



  if (EnableSession1 &&

      IsTimeInRangeFast(currentMinutes, g_Session1StartMin, g_Session1EndMin))

    return "SESSION 1";



  if (EnableSession2 &&

      IsTimeInRangeFast(currentMinutes, g_Session2StartMin, g_Session2EndMin))

    return "SESSION 2";



  if (EnableSession3 &&

      IsTimeInRangeFast(currentMinutes, g_Session3StartMin, g_Session3EndMin))

    return "SESSION 3";



  if (EnableSession4 &&

      IsTimeInRangeFast(currentMinutes, g_Session4StartMin, g_Session4EndMin))

    return "SESSION 4";



  if (EnableSession5 &&

      IsTimeInRangeFast(currentMinutes, g_Session5StartMin, g_Session5EndMin))

    return "SESSION 5";



  return "NONE";

}



//+------------------------------------------------------------------+

//| GET ACTIVE DISTANCE MULTIPLIER (SESSION-AWARE)                   |

//+------------------------------------------------------------------+



double GetActiveDistanceMultiplier() {

  MqlDateTime tm;

  TimeToStruct(GetSessionCurrentTime(), tm);

  int currentMinutes = tm.hour * 60 + tm.min;



  if (EnableSession1 && IsTimeInRangeFast(currentMinutes, g_Session1StartMin, g_Session1EndMin))

    return Session1DistanceMultiplier;



  if (EnableSession2 && IsTimeInRangeFast(currentMinutes, g_Session2StartMin, g_Session2EndMin))

    return Session2DistanceMultiplier;



  if (EnableSession3 && IsTimeInRangeFast(currentMinutes, g_Session3StartMin, g_Session3EndMin))

    return Session3DistanceMultiplier;



  if (EnableSession4 && IsTimeInRangeFast(currentMinutes, g_Session4StartMin, g_Session4EndMin))

    return Session4DistanceMultiplier;



  if (EnableSession5 && IsTimeInRangeFast(currentMinutes, g_Session5StartMin, g_Session5EndMin))

    return Session5DistanceMultiplier;



  // If outside active session but an open basket cycle exists, preserve the cycle's starting session multiplier

  if (CycleSessionMultiplier > 0.0)

    return CycleSessionMultiplier;



  return Session1DistanceMultiplier;

}



//+------------------------------------------------------------------+

//| CHECK TIME RANGE (LEGACY WRAPPER)                                |

//+------------------------------------------------------------------+



bool IsTimeInRange(int currentMinutes, string startTime, string endTime) {

  int start = StringToMinutes(startTime);

  int end = StringToMinutes(endTime);

  return IsTimeInRangeFast(currentMinutes, start, end);

}



//+------------------------------------------------------------------+

//| STRING TO MINUTES                                                |

//+------------------------------------------------------------------+



int StringToMinutes(string text) {

  string parts[];



  int count = StringSplit(text, ':', parts);



  if (count != 2)

    return -1;



  int hour = (int)StringToInteger(parts[0]);



  int minute = (int)StringToInteger(parts[1]);



  if (hour < 0 || hour > 23)

    return -1;



  if (minute < 0 || minute > 59)

    return -1;



  return hour * 60 + minute;

}



//+------------------------------------------------------------------+

//| CHECK IF TRADING IS BLOCKED DUE TO FRIDAY CUTOFF                 |

//+------------------------------------------------------------------+



bool IsFridayTradingBlocked() {

  if (!EnableFridayFilter)

    return false;



  datetime currentTime = GetSessionCurrentTime();

  MqlDateTime tm;

  TimeToStruct(currentTime, tm);



  // In MQL5 MqlDateTime: tm.day_of_week == 5 is Friday (0 = Sunday, 1 = Monday, ..., 5 = Friday, 6 = Saturday)

  if (tm.day_of_week == 5) {

    if (g_FridayCutoffMin >= 0) {

      int currentMinutes = tm.hour * 60 + tm.min;

      if (currentMinutes >= g_FridayCutoffMin) {

        return true; // Block opening new cycles after Friday cutoff time

      }

    }

  }



  return false;

}



//+------------------------------------------------------------------+

//| CHECK IF FRIDAY ROLLOVER PROTECTION WINDOW IS ACTIVE             |

//+------------------------------------------------------------------+



bool IsFridayRolloverActive() {

  if (!EnableFridayBasketRule)

    return false;



  datetime currentTime = TimeCurrent();

  MqlDateTime tm;

  TimeToStruct(currentTime, tm);



  // In MQL5 MqlDateTime: tm.day_of_week == 5 is Friday

  if (tm.day_of_week == 5) {

    if (g_FridayBasketActionMin >= 0) {

      int currentMinutes = tm.hour * 60 + tm.min;

      if (currentMinutes >= g_FridayBasketActionMin) {

        return true;

      }

    }

  }



  return false;

}



//+------------------------------------------------------------------+

//| CHECK FRIDAY ROLLOVER BASKET PROTECTION (LEVEL 8+ RULE)           |

//+------------------------------------------------------------------+



bool CheckFridayBasketProtection(ENUM_POSITION_TYPE direction, int positions) {

  if (!EnableFridayBasketRule)

    return false;



  //------------------------------------------------------------------

  // 1. MONDAY UNFREEZE: Auto-close 100% hedge to resume basket

  //------------------------------------------------------------------

  if (FridayHedgeLockedThisCycle && FridayHedgeCloseOnMonday) {

    MqlDateTime tm;

    TimeToStruct(TimeCurrent(), tm);

    // tm.day_of_week == 1 is Monday

    if (tm.day_of_week == 1) {

      int currentMinutes = tm.hour * 60 + tm.min;

      if (g_MondayHedgeUnfreezeMin >= 0 && currentMinutes >= g_MondayHedgeUnfreezeMin) {

        if (!IsMarketTradeable()) {

          return true; // Market closed or in rollover, retry next tick

        }



        Print("====================================================================");

        Print(">>> MONDAY ROLLOVER RESUME: CLOSING FRIDAY 100% HEDGE <<<");

        Print("Server Time : ", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS));

        Print("Direction   : ", (direction == POSITION_TYPE_BUY ? "BUY" : "SELL"));

        Print("Action      : Unlocking hedge to resume normal grid basket management.");

        Print("====================================================================");



        if (!CloseAllHedgePositions()) {

          Print(">>> [MONDAY UNFREEZE PENDING] Market closed or execution rejected by broker. Retrying on next tick...");

          return true;

        }



        FridayHedgeLockedThisCycle = false;

        UpdateBasketTP(direction);

        return false;

      }

    }

  }



  //------------------------------------------------------------------

  // If already locked, keep pending orders deleted and block grid adds

  //------------------------------------------------------------------

  if (FridayHedgeLockedThisCycle) {

    DeleteAllPendingOrders();

    return true;

  }



  //------------------------------------------------------------------

  // 2. CHECK FRIDAY ROLLOVER TIME & GRID LEVEL THRESHOLD

  //------------------------------------------------------------------

  if (!IsFridayRolloverActive())

    return false;



  if (positions < FridayBasketMinLevel)

    return false;



  //------------------------------------------------------------------

  // 3. EXECUTE SELECTED ACTION

  //------------------------------------------------------------------

  if (FridayBasketAction == FRIDAY_ACTION_CLOSE_MARKET) {

    double floatingPL = GetTotalFloatingProfit();

    Print("====================================================================");

    Print(">>> FRIDAY ROLLOVER PROTECTION: CLOSING BASKET AT MARKET <<<");

    Print("Server Time        : ", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS));

    Print("Basket Direction   : ", (direction == POSITION_TYPE_BUY ? "BUY" : "SELL"));

    Print("Open Grid Levels   : ", positions, " (Threshold: >=", FridayBasketMinLevel, ")");

    Print("Total Grid Volume  : ", DoubleToString(GetBasketLots(direction), 2), " lots");

    Print("Total Floating P/L : $", DoubleToString(floatingPL, 2));

    Print("Action             : Closing all grid & hedge positions before weekend rollover");

    Print("====================================================================");



    // Close any hedge positions first

    CloseAllHedgePositions();

    Print("1. CLOSED HEDGE POSITION(S) BEFORE GRID");



    // Close grid basket

    CloseBasket();

    Print("2. CLOSED GRID BASKET AT MARKET ON FRIDAY ROLLOVER");



    RecordPositionClose();

    VirtualBasketTP = 0.0;

    ADXHedgeOpenedThisCycle = false;

    FridayHedgeLockedThisCycle = false;

    DeleteAllPendingOrders();



    CycleWasActive = false;

    string exitReason = StringFormat("Friday Rollover Close (Level %d >= %d at %s)", positions, FridayBasketMinLevel, FridayBasketActionTime);

    LogPredictionOutcome(exitReason);

    if (EnableDDLogging) {

      OnBasketCycleClosed(exitReason);

    } else {

      DDThresholdLoggedThisCycle = false;

      CurrentCycleMaxDD = 0.0;

    }

    return true;

  }

  else if (FridayBasketAction == FRIDAY_ACTION_LOCK_100_HEDGE) {

    double totalGridLots = GetBasketLots(direction);

    double existingHedgeLots = GetHedgeLots();

    double neededHedgeLots = totalGridLots - existingHedgeLots;



    if (neededHedgeLots > 0.0) {

      double hedgeLot = NormalizeLotRound(neededHedgeLots);

      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);

      double maxLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);

      hedgeLot = MathMax(minLot, MathMin(hedgeLot, maxLot));



      bool result = false;

      if (direction == POSITION_TYPE_BUY) {

        double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

        if (bid <= 0) return false;

        result = hedgeTrade.Sell(hedgeLot, _Symbol, 0, 0, 0, EAComment + "_FRIDAY_100_HEDGE");

      } else {

        double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

        if (ask <= 0) return false;

        result = hedgeTrade.Buy(hedgeLot, _Symbol, 0, 0, 0, EAComment + "_FRIDAY_100_HEDGE");

      }



      if (result) {

        FridayHedgeLockedThisCycle = true;

        DeleteAllPendingOrders();



        Print("====================================================================");

        Print(">>> FRIDAY ROLLOVER PROTECTION: 100% HEDGE LOCKED <<<");

        Print("Server Time        : ", TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES | TIME_SECONDS));

        Print("Basket Direction   : ", (direction == POSITION_TYPE_BUY ? "BUY" : "SELL"));

        Print("Open Grid Levels   : ", positions, " (Threshold >= ", FridayBasketMinLevel, ")");

        Print("Total Grid Volume  : ", DoubleToString(totalGridLots, 2), " lots");

        Print("Previous Hedge     : ", DoubleToString(existingHedgeLots, 2), " lots");

        Print("Added Friday Hedge : ", DoubleToString(hedgeLot, 2), " lots");

        Print("Total Hedge Volume : ", DoubleToString(existingHedgeLots + hedgeLot, 2), " lots (100% DELTA NEUTRAL LOCK)");

        Print("Pending Orders     : Deleted (Martingale halted for weekend rollover)");

        Print("====================================================================");

        return true;

      } else {

        Print("====================================================================");

        Print("FRIDAY 100% HEDGE OPEN ERROR: ", hedgeTrade.ResultRetcodeDescription());

        Print("====================================================================");

      }

    } else {

      // Already fully hedged

      FridayHedgeLockedThisCycle = true;

      DeleteAllPendingOrders();

      return true;

    }

  }



  return false;

}





//+------------------------------------------------------------------+

//| CHART DISPLAY                                                    |

//+------------------------------------------------------------------+



void UpdateChartDisplay() {

  if (!EnableChartDisplay || MQLInfoInteger(MQL_TESTER))

    return;



  MqlDateTime tmServer, tmSession;



  TimeToStruct(TimeCurrent(), tmServer);

  TimeToStruct(GetSessionCurrentTime(), tmSession);



  int currentMinutes = tmSession.hour * 60 + tmSession.min;



  string serverTime = StringFormat("%02d:%02d:%02d", tmServer.hour, tmServer.min, tmServer.sec);

  string sessionTime = StringFormat("%02d:%02d:%02d (GMT+%d)", tmSession.hour, tmSession.min, tmSession.sec, SessionsBaseGMT);



  string text = "";



  text += "XAUUSD MARTINGALE EA\n";

  text += "====================================\n";



  text += "Server Time  : " + serverTime + "\n";

  if (AutoAdaptSessionGMT)

    text += "Session Clock: " + sessionTime + "\n";

  text += "Daily Deposit: $" + DoubleToString(DailyDeposit, 2) + "\n";

  text += "Date (Today) : " + GetCurrentFormattedDate() + (IsDateSkipped() ? " [SKIPPED DATE]" : "") + "\n";

  text += "Symbol       : " + _Symbol + "\n\n";



  //================================================================

  // SESSIONS

  //================================================================



  bool s1 = EnableSession1 &&

            IsTimeInRange(currentMinutes, Session1Start, Session1End);



  text += "Session 1 : ";



  if (EnableSession1)

    text += "ENABLED  ";

  else

    text += "DISABLED ";



  text += Session1Start + " - " + Session1End;



  if (s1)

    text += "   < ACTIVE";



  text += "\n";



  bool s2 = EnableSession2 &&

            IsTimeInRange(currentMinutes, Session2Start, Session2End);



  text += "Session 2 : ";



  if (EnableSession2)

    text += "ENABLED  ";

  else

    text += "DISABLED ";



  text += Session2Start + " - " + Session2End;



  if (s2)

    text += "   < ACTIVE";



  text += "\n";



  bool s3 = EnableSession3 &&

            IsTimeInRange(currentMinutes, Session3Start, Session3End);



  text += "Session 3 : ";



  if (EnableSession3)

    text += "ENABLED  ";

  else

    text += "DISABLED ";



  text += Session3Start + " - " + Session3End;



  if (s3)

    text += "   < ACTIVE";



  text += "\n";



  bool s4 = EnableSession4 &&

            IsTimeInRange(currentMinutes, Session4Start, Session4End);



  text += "Session 4 : ";



  if (EnableSession4)

    text += "ENABLED  ";

  else

    text += "DISABLED ";



  text += Session4Start + " - " + Session4End;



  if (s4)

    text += "   < ACTIVE";



  text += "\n";



  bool s5 = EnableSession5 &&

            IsTimeInRange(currentMinutes, Session5Start, Session5End);



  text += "Session 5 : ";



  if (EnableSession5)

    text += "ENABLED  ";

  else

    text += "DISABLED ";



  text += Session5Start + " - " + Session5End;



  if (s5)

    text += "   < ACTIVE";



  text += "\n\n";



  //================================================================

  // CURRENT SESSION

  //================================================================



  string currentSession = GetCurrentSession();



  bool sessionActive = IsInsideAnySession();



  text += "CURRENT SESSION : " + currentSession + "\n";



  //================================================================

  // NEWS FILTER STATUS

  //================================================================



  if (InpEnableNewsFilter) {

    text +=

        "NEWS FILTER     : " +

        (NewsBlackoutActive ? "BLACKOUT - " + NewsActiveEventName : "clear") +

        "\n";

  } else {

    text += "NEWS FILTER     : DISABLED\n";

  }



  if (EnableDDControl) {

    if (TimeCurrent() < DDResumeTime) {

      int remainingSec = (int)(DDResumeTime - TimeCurrent());

      int rH = remainingSec / 3600;

      int rM = (remainingSec % 3600) / 60;

      text += "DD CONTROL      : PAUSED (" + StringFormat("%02dh %02dm left", rH, rM) + ")\n";

    } else {

      text += "DD CONTROL      : ACTIVE (Monitoring)\n";

    }

  }



  if (EnableDDLogging) {

    text += "DD 50k MONITOR  : ACTIVE (" + IntegerToString(ArraySize(DDHistory)) + " hits recorded | Current DD: $" + DoubleToString(CurrentCycleMaxDD, 2) + ")\n";

  }



  bool dateSkipped = IsDateSkipped();

  bool dateAllowed = IsDateAllowed();

  bool fridayBlocked = IsFridayTradingBlocked();

  string newEntryStatus = "";

  if (dateSkipped) {

    newEntryStatus = "SKIPPED DATE";

  } else if (!dateAllowed) {

    newEntryStatus = "DATE NOT ALLOWED";

  } else if (fridayBlocked) {

    newEntryStatus = "FRIDAY AFTER " + FridayCutoffTime;

  } else if (TimeCurrent() < DDResumeTime) {

    newEntryStatus = "DD PAUSED";

  } else if (IsMaxPosCloseDayBlocked()) {

    newEntryStatus = "DAY PAUSED (MAX POS HIT)";

  } else if (IsPostCloseDelayActive()) {

    int remSec = (int)((LastPositionCloseTime + PostCloseDelaySec) - TimeCurrent());

    if (remSec <= 0) remSec = 1;

    newEntryStatus = "POST-CLOSE DELAY (" + IntegerToString(remSec) + "s)";

  } else if (!sessionActive) {

    newEntryStatus = (CountPositions() > 0 ? "SESSION EXPIRED" : "NO");

  } else if (NewsBlackoutActive) {

    newEntryStatus = "NEWS BLACKOUT";

  } else {

    newEntryStatus = "YES";

  }



  if (CountPositions() > 0) {

    text += "NEW ENTRY       : " + newEntryStatus + "\n";

    text += "MARTINGALE      : RUNNING\n";

  } else {

    text += "NEW ENTRY       : " + newEntryStatus + "\n";

    string mgStatus = "WAITING";

    if (dateSkipped) mgStatus = "SKIPPED (DATE)";

    else if (!dateAllowed) mgStatus = "SKIPPED (DATE NOT ALLOWED)";

    else if (IsMaxPosCloseDayBlocked()) mgStatus = "PAUSED (MAX POS TODAY)";

    text += "MARTINGALE      : " + mgStatus + "\n";

  }



  text += "\n";



  //================================================================

  // BASKET

  //================================================================



  int positions = CountPositions();



  int pending = CountPendingOrders();



  text += "Positions : " + IntegerToString(positions) + " / " +

          IntegerToString(MaximumTrades) +

          (EnableMaxPositionsClose ? " (Auto-Close @ " + IntegerToString(MaxPositionsToClose) + ")" : "") + "\n";



  text += "Pending   : " + IntegerToString(pending) + "\n";



  if (positions > 0) {

    ENUM_POSITION_TYPE direction = GetBasketDirection();



    string directionText = direction == POSITION_TYPE_BUY ? "BUY" : "SELL";



    double lots = GetBasketLots(direction);



    double average = GetWeightedAveragePrice(direction);



    double activeTP = GetActiveBasketTP(positions, direction);

    double targetTP;



    if (direction == POSITION_TYPE_BUY) {

      targetTP = average + activeTP;

    } else {

      targetTP = average - activeTP;

    }



    int digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);



    text += "Direction : " + directionText + "\n";



    text += "Lots      : " + DoubleToString(lots, 2) + "\n";



    text += "Average   : " + DoubleToString(average, digits) + "\n";



    datetime firstOpenForHud = GetBasketFirstOpenTime(direction);

    bool isDecayedForHud = (EnableTimeDecayTP && firstOpenForHud > 0 && ((double)(TimeCurrent() - firstOpenForHud) / 3600.0) >= TimeDecayHours);

    string tpSuffix = isDecayedForHud ? " [TIME-DECAY]" : (EnableStepBasketTP && positions >= StepBasketTPGridLevel ? " [STEP]" : "");

    text += "Basket TP : " + DoubleToString(targetTP, digits) + " (TP: " + DoubleToString(activeTP, 2) + tpSuffix + ")\n";



    // ADX Hedge Status

    if (EnableADXHedge) {

      if (CountHedgePositions() > 0) {

        text += "ADX Hedge : ACTIVE (" +

                (direction == POSITION_TYPE_BUY ? "SELL" : "BUY") + ")\n";

      } else {

        text += "ADX Hedge : MONITORING (Min Grids: " + IntegerToString(ADXHedgeMinGrids) + ")\n";

      }

    } else {

      text += "ADX Hedge : DISABLED\n";

    }



    // Basket Duration Status

    if (EnableMaxGridDuration) {

      datetime firstTime = GetBasketFirstOpenTime(direction);

      if (firstTime > 0) {

        int elapsedSec = (int)(TimeCurrent() - firstTime);

        int maxSec = (int)(MaxGridDurationHours * 3600.0);

        int remSec = MathMax(0, maxSec - elapsedSec);

        int elH = elapsedSec / 3600;

        int elM = (elapsedSec % 3600) / 60;

        int remH = remSec / 3600;

        int remM = (remSec % 3600) / 60;

        text += StringFormat("Duration  : %02dh %02dm (Max: %.1fh | Left: %02dh %02dm)\n", elH, elM, MaxGridDurationHours, remH, remM);

      }

    }



    int nextLevel = positions + 1;



    if (nextLevel <= MaximumTrades) {

      double nextLot = GetLotForLevel(nextLevel);



      double atrRatioPreview = GetATRVolatilityRatio();

      double distMultPreview = GetActiveDistanceMultiplier();



      double nextDistance =

          InitialDistance * MathPow(distMultPreview, positions - 1) * atrRatioPreview;



      nextDistance = MathMax(nextDistance, GetMinimumStopDistance());



      text += "\n";



      text += "Next Level    : " + IntegerToString(nextLevel) + "\n";



      text += "Next Lot      : " + DoubleToString(nextLot, 2) + "\n";



      text += "Next Distance : " + DoubleToString(nextDistance, 2) + "\n";



      text += "Dist Mult     : " + DoubleToString(distMultPreview, 2) + " (" + GetCurrentSession() + ")\n";



      if (UseATRDistanceScaling) {

        text += "ATR Ratio     : " + DoubleToString(atrRatioPreview, 3) +

                " (ATR " + DoubleToString(GetCurrentATR(), 2) +

                " / Baseline " + DoubleToString(BaselineATR, 2) + ")\n";

      }

    } else {

      text += "\n";

      text += "MAXIMUM LEVEL REACHED\n";

    }

  } else {

    text += "\n";



    if (pending > 0) {

      text += "WAITING FOR PENDING STOP:\n";

      for (int i = OrdersTotal() - 1; i >= 0; i--) {

        ulong ticket = OrderGetTicket(i);

        if (ticket == 0 || !OrderSelect(ticket)) continue;

        if (OrderGetString(ORDER_SYMBOL) != _Symbol) continue;

        if ((ulong)OrderGetInteger(ORDER_MAGIC) != MagicNumber) continue;

        ENUM_ORDER_TYPE otype = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);

        double oprice = OrderGetDouble(ORDER_PRICE_OPEN);

        double pipVal = GetPipValueInPrice();

        if (otype == ORDER_TYPE_BUY_STOP) {

          double cAsk = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

          double gapPrice = oprice - cAsk;

          double gapPips = (pipVal > 0) ? (gapPrice / pipVal) : 0.0;

          double targetPrice = PipsToPriceDistance(PendingResetDistancePips);

          text += StringFormat("  BUY STOP @ %.2f (Ask: %.2f)\n  Dist Away: %.1f pips ($%.2f)\n  Reset At : %.1f pips ($%.2f)\n",

                               oprice, cAsk, gapPips, gapPrice, PendingResetDistancePips, targetPrice);

        } else if (otype == ORDER_TYPE_SELL_STOP) {

          double cBid = SymbolInfoDouble(_Symbol, SYMBOL_BID);

          double gapPrice = cBid - oprice;

          double gapPips = (pipVal > 0) ? (gapPrice / pipVal) : 0.0;

          double targetPrice = PipsToPriceDistance(PendingResetDistancePips);

          text += StringFormat("  SELL STOP @ %.2f (Bid: %.2f)\n  Dist Away: %.1f pips ($%.2f)\n  Reset At : %.1f pips ($%.2f)\n",

                               oprice, cBid, gapPips, gapPrice, PendingResetDistancePips, targetPrice);

        }

      }

    } else if (sessionActive) {

      text += "READY - NEW CYCLE\n";

    } else {

      text += "WAITING FOR NEXT SESSION\n";

    }

  }



  text += "\n";

  text += "------------------------------------\n";



  text += "Initial Lot : " + DoubleToString(InitialLot, 2) + "\n";



  text += "Distance    : " + DoubleToString(InitialDistance, 2) + "\n";



  text += "Initial TP  : " + DoubleToString(InitialTPPips, 1) + " pips (" + DoubleToString(PipsToPriceDistance(InitialTPPips), 2) + ")\n";

  text += "Post-Close  : " + IntegerToString(PostCloseDelaySec) + "s\n";



  text += "Basket TP   : " + DoubleToString(BasketTP, 2) + 

          (EnableStepBasketTP ? " (>=L" + IntegerToString(StepBasketTPGridLevel) + ": " + DoubleToString(StepBasketTP, 2) + ")" : "") + "\n";



  text += "Multiplier  : " + DoubleToString(Multiplier, 2) + "\n";

  text += "Dist Mult   : " + DoubleToString(GetActiveDistanceMultiplier(), 2) + " (" + GetCurrentSession() + ")\n";

  if (EnableAutoLotCompounding) {

    text += "Compounding : ON (Base $" + DoubleToString(CompoundingBaseBalance, 0) + ")\n";

  }

  if (EnableLevel1TrendRunner) {

    text += "L1 Runner   : ON (" + DoubleToString(Level1PartialClosePct, 0) + "% @ " + DoubleToString(InitialTPPips, 0) + "p | Trail " + DoubleToString(Level1TrailingDistancePips, 0) + "p)\n";

  }

  if (UseATRBasketTPScaling) {

    text += "ATR TP Scale: ON (Max " + DoubleToString(ATR_TP_MaxRatio, 1) + "x)\n";

  }



  if (EnableDirectionalPrediction || EnableRangeBoundaryFilter || EnableSRFilter || EnableTrendFilter || EnableMacroTrendFilter) {

    text += "------------------------------------\n";

    text += "PREDICTION / FILTERS\n";

    if (CurrentPrediction.active) {

      text += "Prediction  : " + CurrentPrediction.predictedDirection + "\n";

      text += "Side Opened : " + CurrentPrediction.sideOpened + "\n";

      text += "Grid Level  : " + IntegerToString(CycleMaxGridLevel) + (EnableHardGridCap ? (" / " + IntegerToString(MaxGridLevelsHardCap)) : "") + "\n";

    } else {

      text += "Prediction  : (no active cycle)\n";

    }

    if (EnableRangeBoundaryFilter) {

      text += "Range Guard : ON (24H Top/Bottom " + DoubleToString(RangeBoundaryThresholdPct, 0) + "%)\n";

    }

    if (EnableMacroTrendFilter) {

      ENUM_TREND_STATE mTrend = GetMacroTrendState();

      string mTrendStr = (mTrend == TREND_UP) ? "BULLISH (BUY<=L" + IntegerToString(MacroWithTrendMaxGrid) + " | SELL<=L" + IntegerToString(MacroCounterTrendMaxGrid) + ")" :

                         (mTrend == TREND_DOWN) ? "BEARISH (SELL<=L" + IntegerToString(MacroWithTrendMaxGrid) + " | BUY<=L" + IntegerToString(MacroCounterTrendMaxGrid) + ")" : "FLAT";

      text += "Macro Trend : " + mTrendStr + "\n";

    }

  }



  text += "ATR Scaling : " + (UseATRDistanceScaling ? "ON" : "OFF");



  if (EnableADXHedge) {

    double currentAdx = GetCurrentADXForHedge();

    text += "\nADX Hedge   : ON (ADX: " + DoubleToString(currentAdx, 1) + " / " + DoubleToString(ADXHedgeThreshold, 1) + " | MinGrids: " + IntegerToString(ADXHedgeMinGrids) + " | " + DoubleToString(ADXHedgeLotMultiplier, 1) + "x)";

  } else {

    text += "\nADX Hedge   : OFF";

  }



  if (EnableMaxGridDuration) {

    text += "\nMax Duration: ON (" + DoubleToString(MaxGridDurationHours, 1) + " hrs)";

  } else {

    text += "\nMax Duration: OFF";

  }



  if (EnableAllowedDatesOnly) {

    text += "\nAllowed Dates: ON (" + (AllowedTradingDates != "" ? AllowedTradingDates : "Custom") + ")";

  } else {

    text += "\nAllowed Dates: OFF (All Days)";

  }



  if (EnableSkipDatesFilter) {

    text += "\nSkip Dates   : ON";

  } else {

    text += "\nSkip Dates   : OFF";

  }



  if (EnablePendingOrderReset) {

    text += "\nPending Reset: ON (" + DoubleToString(PendingResetDistancePips, 0) + " pips)";

  } else {

    text += "\nPending Reset: OFF";

  }



  if (EnableFridayBasketRule) {

    text += "\nFriday Rollover: " + (FridayBasketAction == FRIDAY_ACTION_CLOSE_MARKET ? "CLOSE" : "HEDGE") + " (L" + IntegerToString(FridayBasketMinLevel) + "+ @ " + FridayBasketActionTime + ")";

    if (FridayHedgeLockedThisCycle) {

      text += " [LOCKED 100%]";

    }

  }





  Comment(text);

}



//+------------------------------------------------------------------+

//| ON TRADE TRANSACTION                                             |

//+------------------------------------------------------------------+



void OnTradeTransaction(const MqlTradeTransaction &trans,

                        const MqlTradeRequest &request,

                        const MqlTradeResult &result) {

  if (trans.type == TRADE_TRANSACTION_DEAL_ADD) {

    if (trans.symbol == _Symbol) {

      if (HistoryDealSelect(trans.deal)) {

        ulong magic = HistoryDealGetInteger(trans.deal, DEAL_MAGIC);

        if (magic == MagicNumber || magic == ADXHedgeMagicNumber) {

          ENUM_DEAL_ENTRY entry = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(trans.deal, DEAL_ENTRY);

          if (entry == DEAL_ENTRY_OUT || entry == DEAL_ENTRY_INOUT || entry == DEAL_ENTRY_OUT_BY) {

            if (CountPositions() == 0) {

              RecordPositionClose();

            }

          }

        }

      }

    }

  }

}



//+------------------------------------------------------------------+

//| END                                                              |

//+------------------------------------------------------------------+

