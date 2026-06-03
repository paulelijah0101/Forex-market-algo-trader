//+------------------------------------------------------------------+
//| XAUUSDFootprintEA.mq5  v5.5  -- Project Pravali                  |
//|                                                                  |
//| NEW IN v5.5 -- Footprint-Based Session VWAP:                     |
//|  Replaces tick-volume VWAP with true futures-volume VWAP built  |
//|  from ClusterDelta's bid+ask contract volume at each price level.|
//|  Accumulated bar by bar from session open (resets at 00:00).    |
//|  Shown on dashboard as "FP VWAP" with [CD] source tag.          |
//|  Fallback to tick VWAP if no footprint data yet this session.   |
//|                                                                  |
//| CARRIED FROM v5.4:                                              |
//|  RANGE(conv) trading suspension + EMA gap hysteresis            |
//|  Two-layer regime: M15 primary + M5/M1 momentum                 |
//|  [B][C][D][E] exit engine, EHL targets, zone breach tiering     |
//+------------------------------------------------------------------+
#property copyright "XAUUSD Footprint EA v5.5"
#property version   "5.50"
#property strict

#include <Trade\Trade.mqh>

//===================================================================
// INPUTS
//===================================================================
input group           "=== Signal ==="
input int    InpMinVol      = 3;      // Min volume for normal signal (0x3)
input int    InpStrongVol   = 10;     // Min volume for SELL strong signal (0x10)
                                       // Data: vol 10-19 = 57% win rate (normal sizing correct)
input int    InpStrongVol_Buy = 9;    // Min volume for BUY strong signal (9x0)
                                       // Data: BUY vol 9-17 = 71-79% win rate (better than SELL!)
                                       // Lower threshold for BUY because absorption at highs
                                       // is inherently stronger signal on gold
input int    InpUltraVol    = 20;     // Ultra signal threshold -- any direction
                                       // Data: vol 20+ = 69% win rate (highest tier)
                                       // Uses InpUltraLot for position sizing
input double InpTickSz      = 0.10;   // GC futures tick size
input int    InpTopRows     = 3;      // Rows from extreme to check

input group           "=== Microstructure Stop ==="
input double InpATR_Mult    = 0.15;   // ATR(1m) multiplier for buffer (raised: wider bars in war vol)
input double InpMinBuffer   = 1.0;    // Minimum SL buffer in points   (raised: tighter was getting run)
input double InpMaxBuffer   = 2.5;    // Maximum SL buffer in points   (raised: gives SL more room)
input double InpMinSL       = 3.0;    // Minimum SL distance (pts)     (raised from 2.0: stops too tight)
input double InpMaxSL       = 12.0;   // Normal signal: max SL (pts)   (raised from 8.0: war vol wider bars)
input double InpMaxSL_Strong= 20.0;   // Strong signal: max SL (pts)   (raised from 15.0)
input double InpMaxZoneDist = 10.0;   // Max entry dist from zone (vol<=5 only) (raised from 5.0)
input double InpBreachMid   = 8.0;    // Max breach for vol 6-9 (pts)  (raised from 3.0: fast moves breach instantly)
input double InpBreachStrong= 15.0;   // Max breach for vol 10+ (pts)  (raised from 6.0: 62% of blocks were winners)
input bool   InpZoneProtect = true;   // FALSE = disable zone breach check

input group           "=== Two-Stage TP ==="
input double InpTP1_R       = 1.0;    // TP1 RR (close 50%)
input double InpRR_1        = 1.8;    // TP2 RR for 1-row normal (FH min 1.8R)
input double InpRR_2        = 1.8;    // TP2 RR for 2-row normal
input double InpRR_3        = 1.8;    // TP2 RR for 3+ row normal
input double InpStrongRR    = 2.0;    // TP2 RR for strong/ultra (FH min 2.0R)
input double InpEHL_MinRR   = 1.0;    // Min RR for EHL level to qualify

input group           "=== Dynamic Exit Engine ==="
input double InpApproachDist  = 0.30; // [B] Close when within X pts of TP
input int    InpTrailBars     = 3;    // [C] Bars lookback for trailing stop
input double InpDecayRatio    = 0.40; // [D] Decay: range < prev x this (0=off)
input double InpThesisMinLoss = 0.5;  // [E] Min floating loss before thesis check
input int    InpThesisVol     = 2;    // [E] Min opposing vol (lower than entry InpMinVol)

input group           "=== Lot Sizing ==="
input double InpLot         = 0.01;   // Normal lot (vol 3-19 normal signals)
input double InpStrongLot   = 0.02;   // Strong signal lot (vol >= InpStrongVol/InpStrongVol_Buy)
input double InpUltraLot    = 0.03;   // Ultra signal lot (vol >= InpUltraVol=20)
                                       // Data: vol 20+ = 69% win rate -- highest tier, size up
input double InpPurityFactor = 0.5;   // Zone purity multiplier (0.5 = half lot on mixed zones)
                                       // Data: pure zone (all rows 0xN) = 61% win
                                       //       mixed zone (any row has bid+ask) = 58% win
                                       // Set to 1.0 to disable purity scaling

input group           "=== Range Timeout ==="
input int    InpTimeout     = 10;     // Close if stuck X minutes
input double InpMinMove     = 1.0;    // Min move to not be stuck

input group           "=== Dashboard ==="
input bool   InpShowPanel   = true;
input int    InpPanelX      = 20;
input int    InpPanelY      = 30;

input group           "=== FundedHive Risk Manager ==="
input bool   InpFH_Enable        = true;    // Enable FundedHive prop firm rules
input double InpFH_Balance       = 10000.0; // Starting account balance ($) -- adjust per challenge
input int    InpFH_Phase         = 1;       // Challenge phase: 1=8% target, 2=6% target
input double InpFH_Risk_Normal   = 0.20;    // Risk % of balance per NORMAL signal
input double InpFH_Risk_Strong   = 0.24;    // Risk % of balance per STRONG signal
input double InpFH_Risk_Ultra    = 0.30;    // Risk % of balance per ULTRA signal (vol>=20)
input double InpFH_DailyLimit    = 2.0;     // Max daily loss % (FH rule=5%, we use 2% safety buffer)
input double InpFH_MaxLoss       = 10.0;    // Max total loss % (FH rule=10%, hard stop)
input double InpFH_Target_P1     = 8.0;     // Phase 1 profit target %
input double InpFH_Target_P2     = 6.0;     // Phase 2 profit target %
input bool   InpFH_PauseOnTarget = true;    // Pause EA when target reached (protect the pass)
input bool   InpFH_SLTPOnly      = true;    // Close trades ONLY via SL/TP (disables [E][F][D] exits)
                                             // Set true for strict prop firm rule compliance
input int    InpFH_Cooldown      = 60;      // Seconds between trades (cooldown after each entry)
input int    InpFH_NewsBuffer    = 10;      // Minutes to block before/after red news events

input group           "=== General ==="
input int    InpMaxPos      = 1;
input int    InpMagic       = 20260306;
input bool   InpLog         = true;
input bool   InpGhostMode   = false;  // Ghost mode: press G on chart to toggle (hides panel, silences verbose log)

input group           "=== [F] Counter-Signal Exit ==="
input bool   InpCounterSig_Enable = true;  // Enable counter-signal exit engine
input int    InpCounterSig_MinVol = 10;    // Min vol for opposing signal to trigger [F] (STRONG only)

input group           "=== [G] Regime-Aware Delta Filter ==="
// Blocks entry when FULL-BAR DELTA and REGIME agree the signal is wrong
// Rule: TREND_UP + SELL signal + positive delta  -> skip (sellers losing, trend up)
//       TREND_DN + BUY  signal + negative delta  -> skip (buyers losing, trend down)
// RANGE/RANGE(conv) are never blocked -- absorption signals live there
// OBSERVATION MODE: InpDelta_Observe=true logs delta verdict without blocking
// Switch to InpDelta_Observe=false when ready to use as a live filter
input bool   InpDelta_Enable    = true;   // Enable regime-aware delta filter
input bool   InpDelta_Observe   = false;  // LIVE mode: data confirmed 67% aligned win rate in TREND
                                           // 3 sessions: TREND UP aligned=86% vs contra=36%
                                           // Set true to revert to observe-only mode
input int    InpDelta_Threshold = 10;     // Min |delta| to trigger filter

input group           "=== [H] Price vs EMA Confirmation ==="
// Prevents buying into downmoves and selling into upmoves when EMAs lag
// Problem: M1 EMA8/20 lags 1-3 bars behind price -- EA enters wrong direction
//          during trend reversals causing 3-4 consecutive losses
// Fix:     Require current PRICE to be on the correct side of EMA8 before entry
//          If price already crossed EMA8 against the regime -> skip
input bool   InpPriceConfirm       = true;  // Enable price vs EMA confirmation
input double InpPriceConfirmBuffer = 1.0;   // Allowance in pts -- avoids blocking at exact crossings
                                             // BUY in TREND UP: price must be > EMA8 - 1.0pts
                                             // SELL in TREND DN: price must be < EMA8 + 1.0pts

input group           "=== [I] Momentum Override ==="
// Allows counter-trend entries when SHORT-TERM MOMENTUM strongly contradicts EMA direction
// Problem: EMA says TREND UP but 3+ consecutive bearish candles + price below EMA8
//          -> real momentum is down, EA should allow SELL signals temporarily
// This is the "microstructure > moving average" principle for 1M gold
// Override ONLY activates when: N of last M candles confirm direction + price crossed EMA8
// Without override: SELL blocked in TREND UP even during sharp reversal
// With override:    SELL allowed temporarily -> catches the actual move
input bool   InpMomOverride       = true;  // Enable momentum override
input int    InpMomLookback       = 4;     // Candles to inspect for momentum
input int    InpMomMinCandles     = 3;     // Min candles in override direction (of last InpMomLookback)
                                            // e.g. 3 of last 4 bearish + price below EMA8 -> sell override

input group           "=== [J] Structure Engine (Phase 1) ==="
// Adds market location context before allowing footprint entries
// Footprint = TIMING  |  Structure = LOCATION  |  Momentum = CONFIRMATION
//
// Detects two high-probability structures:
//   1. Swing High/Low Revisit -- price returning to liquidity zone (stops cluster here)
//   2. Liquidity Sweep        -- price briefly breaks swing level then rejects (stop hunt)
//
// Uses a SCORE system (not hard block) for flexibility:
//   sell_score: points favouring SELL location
//   buy_score:  points favouring BUY  location
//   InpStructMinScore=0 -> OBSERVE only (logs score, never blocks)
//   InpStructMinScore=1 -> some structure required
//   InpStructMinScore=2 -> meaningful structure required
//   InpStructMinScore=3 -> strong structure only (sweep or clear swing level)
//
// START WITH InpStructMinScore=0 -- collect 2 weeks data, then raise if TRUE
// signals consistently score higher than FALSE signals
input bool   InpStructEnable    = true;  // Enable structure engine
input int    InpStructMinScore  = 0;     // Min score to allow entry (0=observe only)
input int    InpStructLookback  = 20;    // Bars to scan for swing highs/lows
input double InpStructDist      = 3.0;  // Pts from swing level to qualify as "at" it
input double InpSweepMin        = 0.5;  // Min pts beyond swing level to count as sweep

input group           "=== Equal High/Low TP Targets ==="
input int    InpEHL_Bars    = 30;     // Bars to scan
input double InpEHL_Tol     = 0.30;   // Tolerance for equal (pts)
input int    InpEHL_MinHits = 2;      // Min touches to qualify
input double InpEHL_MaxDist = 20.0;   // Max scan range (pts)

input group           "=== VWAP Filter ==="
input bool   InpVWAP_Filter = true;   // Enable VWAP distance filter
input double InpVWAP_ExtDist= 20.0;   // Block if price > X pts from VWAP
                                       // Raised from 8.0: data shows 56% of 8pt blocks were winners
                                       // War volatility expands intraday VWAP deviations significantly
input bool   InpVWAP_Strong = false;  // Apply to strong signals too

input group           "=== Market Regime -- M1 EMA8/20 (single layer) ==="
input bool   InpRegime_Enable = true; // Enable regime-aware signal filter
input int    InpEMA_Fast      = 8;    // Fast EMA period (M1)
input int    InpEMA_Slow      = 20;   // Slow EMA period (M1)
input int    InpADX_Period    = 14;   // ADX period (M1)
input double InpADX_Trend     = 25.0; // ADX > this = trending
input double InpADX_Range     = 20.0; // ADX < this = ranging
input double InpTrendSlope    = 0.5;  // Min EMA slope over 5 M1 bars (pts)
input int    InpRegimeBars    = 20;   // M1 bars for range high/low detection
input double InpEMA_MinGap    = 1.5;  // Min |EMA8-EMA20| pts to enter TREND
                                       // Raised from 0.5: M1 EMAs cross too easily in choppy markets
                                       // 1.5pts requires meaningful separation before calling it a trend
input double InpEMA_HystGap   = 0.8;  // Extra gap needed to EXIT RANGE(conv)
                                       // Raised from 0.3: exit threshold = 1.5+0.8 = 2.3pts total
input bool   InpConv_Disable  = false; // Suspend new entries during RANGE(conv)
                                        // Changed to FALSE: data shows 50% of conv blocks were winners
                                        // Wider EMA_MinGap (1.5) provides better protection instead

//===================================================================
// GLOBALS
//===================================================================
CTrade   Trade;
datetime g_last_bar        = 0;
datetime g_last_fp_bar     = 0;
datetime g_last_manage_bar = 0;

#define  MAX_LVL 500
double   g_price[MAX_LVL];
long     g_bid  [MAX_LVL];
long     g_ask  [MAX_LVL];
int      g_count    = 0;
double   g_bar_high = 0;
double   g_bar_low  = 0;

double   g_imbalance_top = 0;
double   g_imbalance_bot = 0;

// Session statistics
int      g_total_trades   = 0;
int      g_wins           = 0;
int      g_losses         = 0;
int      g_tp1_closes     = 0;
int      g_timeouts       = 0;
int      g_momentum_exits = 0;
int      g_thesis_exits   = 0;
int      g_approach_exits = 0;
int      g_counter_exits  = 0;    // [F] counter-signal exits
int      g_ultra_signals  = 0;    // vol >= InpUltraVol (20+) entries
int      g_purity_reduced = 0;    // entries where lot was halved due to mixed zone
bool     g_zone_pure      = false;// current signal: all zone rows have one side = 0

// FundedHive Risk Manager globals
double   g_fh_day_start_balance = 0;    // account balance at session start (daily reset)
double   g_fh_daily_pnl        = 0;    // today's realized P&L ($)
double   g_fh_total_pnl        = 0;    // total P&L since EA start ($)
bool     g_fh_daily_stopped    = false; // true = daily limit hit, no more trades today
bool     g_fh_max_stopped      = false; // true = max loss hit, no more trades ever
bool     g_fh_target_hit       = false; // true = phase target reached
datetime g_fh_last_day         = 0;    // last day reset date
datetime g_fh_last_trade_time  = 0;    // time of last trade entry (cooldown)
int      g_fh_news_blocks      = 0;    // trades blocked by news filter
int      g_fh_cooldown_blocks  = 0;    // trades blocked by cooldown
int      g_fh_rr_blocks        = 0;    // trades blocked by RR minimum
double   g_fh_balance_adj      = 0;    // dashboard balance adjustment (+/- button)
// Target % based on phase
double FH_Target() { return (InpFH_Phase==1) ? InpFH_Target_P1 : InpFH_Target_P2; }
double   g_session_pnl    = 0;
double   g_gross_profit   = 0;
double   g_gross_loss     = 0;
double   g_last_fp_secs   = 0;
string   g_last_signal    = "--";
datetime g_session_start  = 0;
// Stale detection: track whether FP_READY value has changed since last bar
// Timezone-safe -- does not rely on TimeCurrent() vs bar_time comparison
double   g_prev_fp_ready  = -1;   // last seen FP_READY value
int      g_fp_stale_bars  = 0;    // bars since FP_READY last changed

// Footprint VWAP accumulators (true GC futures volume, resets daily at 00:00)
double   g_fp_vwap_spv   = 0;   // SUM(price x total_vol) accumulated this session
double   g_fp_vwap_sv    = 0;   // SUM(total_vol) accumulated this session
double   g_fp_vwap       = 0;   // current session VWAP (futures volume weighted)
datetime g_fp_vwap_date  = 0;   // date of last VWAP reset (daily)

// Session Volume Profile -- POC / VAH / VAL
// Accumulates across ALL footprint bars this session (same reset as VWAP)
// POC  = price level with highest total volume traded today
// VAH  = upper boundary of 70% volume zone (Value Area High)
// VAL  = lower boundary of 70% volume zone (Value Area Low)
// Observation-only for now -- logged in STATUS, shown on dashboard
// Will be used for TP/SL targets once validated over 1-2 weeks
#define  VP_MAX_LEVELS 2000      // max distinct price levels tracked per session
double   g_vp_price[VP_MAX_LEVELS];  // price levels in profile
long     g_vp_vol  [VP_MAX_LEVELS];  // total volume at each level
int      g_vp_count  = 0;            // number of distinct levels recorded
double   g_poc_price = 0;            // Point of Control price
long     g_poc_vol   = 0;            // volume at POC
double   g_vah_price = 0;            // Value Area High (70% of session volume)
double   g_val_price = 0;            // Value Area Low
int      g_poc_bars  = 0;            // bars accumulated since session reset
datetime g_poc_date  = 0;            // session date for reset

// Market Regime -- M1 EMA8/20 single layer (L2 removed)
enum MarketRegime { REGIME_TREND_UP=0, REGIME_TREND_DN=1, REGIME_RANGE=2,
                    REGIME_BREAKOUT_UP=3, REGIME_BREAKOUT_DN=4 };
MarketRegime g_regime        = REGIME_RANGE;
string       g_regime_str    = "RANGE";
int          g_h_ema_fast    = INVALID_HANDLE;
int          g_h_ema_slow    = INVALID_HANDLE;
int          g_h_adx         = INVALID_HANDLE;
int          g_regime_blocks = 0;
bool         g_in_conv       = false;
int          g_conv_blocks   = 0;
double       g_last_adx      = 0;
double       g_last_ema_gap  = 0;
long         g_bar_delta     = 0;    // [G] full-bar delta computed each bar (ask-bid across all levels)
int          g_delta_blocks  = 0;    // [G] entries blocked by regime-aware delta filter
int          g_delta_observe = 0;    // [G] would-have-blocked count in observe mode
int          g_price_confirm_blocks = 0; // [H] entries blocked by price vs EMA confirmation
double       g_ema_fast_now  = 0;    // [H] current EMA8 value cached each bar for Execute()
bool         g_mom_override_sell = false; // [I] true = allow SELL even in TREND UP
bool         g_mom_override_buy  = false; // [I] true = allow BUY  even in TREND DN
int          g_mom_override_count = 0;    // [I] total overrides fired this session

// [J] Structure Engine globals
double       g_last_swing_high   = 0;    // most recent M1 swing high price
double       g_last_swing_low    = 0;    // most recent M1 swing low price
bool         g_near_swing_high   = false;// price within InpStructDist of swing high
bool         g_near_swing_low    = false;// price within InpStructDist of swing low
bool         g_sweep_up          = false;// bar swept above swing high then rejected back
bool         g_sweep_down        = false;// bar swept below swing low  then rejected back
int          g_struct_sell_score = 0;    // current sell structure score (logged each bar)
int          g_struct_buy_score  = 0;    // current buy  structure score (logged each bar)
int          g_struct_blocks     = 0;    // entries blocked by structure score < minimum

struct TradeInfo
{
   ulong    ticket;
   datetime open_time;
   double   open_price;
   double   sl;
   double   tp1;
   double   tp2;
   bool     tp1_hit;
   bool     is_strong;
   int      type;   // 0=buy 1=sell
};
TradeInfo g_trades[10];
int       g_trade_cnt = 0;

#define PANEL_PFX "FP_DASH_"

// Ghost mode -- runtime toggle via G key on chart
// When ON: panel hidden, verbose log suppressed, tiny "GHOST" label shown
// When OFF: full panel, full log -- normal operation
// InpGhostMode sets the startup default; G key toggles during session
bool g_ghost_mode = false;

//===================================================================
// ONINIT / ONDEINIT
//===================================================================
int OnInit()
{
   Trade.SetExpertMagicNumber(InpMagic);
   Trade.SetDeviationInPoints(30);
   Trade.SetTypeFilling(ORDER_FILLING_IOC);
   g_session_start = TimeCurrent();
   g_ghost_mode    = InpGhostMode;  // runtime flag -- G key can toggle anytime

   // M1 regime handles -- EMA8/20 + ADX on M1 (single layer, L2 removed)
   g_h_ema_fast = iMA(_Symbol,PERIOD_M1,InpEMA_Fast,0,MODE_EMA,PRICE_CLOSE);
   g_h_ema_slow = iMA(_Symbol,PERIOD_M1,InpEMA_Slow,0,MODE_EMA,PRICE_CLOSE);
   g_h_adx      = iADX(_Symbol,PERIOD_M1,InpADX_Period);
   if(g_h_ema_fast==INVALID_HANDLE||g_h_ema_slow==INVALID_HANDLE||g_h_adx==INVALID_HANDLE)
   {
      Print("ERROR: Failed to create M1 regime handles");
      return INIT_FAILED;
   }

   Print("=== XAUUSD Footprint EA v5.5 -- Recalibrated for War Volatility ===");
   Print("  Recalibration Apr 2026: VWAP 8->20pts, Breach 6->15pts, SL 8->12pts");
   Print("  Conv suspend OFF (data: 50% of blocks were winners -- EMA gap 0.5->1.5 protects instead)");
   Print("  [G] delta filter LIVE (data: TREND aligned=77-86% vs contra=36-48%)");
   Print("  Lot sizing: normal=",InpLot," strong=",InpStrongLot," ultra(>=",InpUltraVol,")=",InpUltraLot);
   Print("  Signal tiers: normal<",InpStrongVol_Buy,"(buy)/",InpStrongVol,
         "(sell)  strong<",InpUltraVol,"  ultra>=",InpUltraVol);
   Print("  Zone purity: purity factor=",InpPurityFactor,
         " (1.0=disabled, 0.5=half lot on mixed zones)");
   Print("  [D] Decay=",InpDecayRatio,(InpDecayRatio<=0?" (OFF)":""),
         "  [E] ThesisMin=",InpThesisMinLoss,"pts");
   Print("  [F] Counter-signal: ",(InpCounterSig_Enable?"ON":"OFF"),
         "  min vol=",InpCounterSig_MinVol,
         "  (close/BE/lock on opposing STRONG signal)");
   Print("  [G] Regime-delta: ",(InpDelta_Enable?"ON":"OFF"),
         "  mode=",(InpDelta_Observe?"OBSERVE (log only, no block)":"LIVE (blocks entry)"),
         "  threshold=",InpDelta_Threshold);
   Print("  [H] Price vs EMA: ",(InpPriceConfirm?"ON":"OFF"),
         "  buffer=",InpPriceConfirmBuffer,"pts",
         "  (blocks entries when price crossed EMA8 against regime)");
   Print("  [I] Momentum override: ",(InpMomOverride?"ON":"OFF"),
         "  lookback=",InpMomLookback," min=",InpMomMinCandles,
         "  (allows counter-regime entry when candles+price confirm reversal)");
   Print("  [J] Structure engine: ",(InpStructEnable?"ON":"OFF"),
         "  mode=",(InpStructMinScore==0?"OBSERVE (score logged, no block)":
                    StringFormat("LIVE (min score=%d)",InpStructMinScore)),
         "  lookback=",InpStructLookback,"bars  dist=",InpStructDist,"pts");
   Print("  M1 regime (single layer, L2 removed): ",(InpRegime_Enable?"ON":"OFF"),
         "  EMA",InpEMA_Fast,"/",InpEMA_Slow," M1  gap>=",InpEMA_MinGap,
         " hyst=",InpEMA_HystGap,"  ADX(",InpADX_Period,")");
   Print("  Conv suspend: ",(InpConv_Disable?"ON -- no trades in RANGE(conv)":"OFF"));
   Print("  Ghost mode: ",(g_ghost_mode?"ON (press G to disable)":"OFF (press G on chart to enable)"));

   if(InpShowPanel && !g_ghost_mode) DrawPanel();
   if(g_ghost_mode) DrawGhostLabel();  // tiny corner label when panel is hidden
   return INIT_SUCCEEDED;
}

void OnDeinit(const int reason)
{
   if(g_h_ema_fast!=INVALID_HANDLE) IndicatorRelease(g_h_ema_fast);
   if(g_h_ema_slow!=INVALID_HANDLE) IndicatorRelease(g_h_ema_slow);
   if(g_h_adx     !=INVALID_HANDLE) IndicatorRelease(g_h_adx);
   DeletePanel();
   ObjectDelete(0, "FP_GHOST_LBL");
   Print("=== XAUUSD Footprint EA v5.5 stopped ===");
}

void OnChartEvent(const int id,const long &lparam,
                  const double &dparam,const string &sparam)
{
   // G key toggles ghost mode
   if(id == CHARTEVENT_KEYDOWN && lparam == 71)
   {
      g_ghost_mode = !g_ghost_mode;
      if(g_ghost_mode)
      {
         DeletePanel(); DrawGhostLabel();
         Print("GHOST MODE ON -- panel hidden, verbose log suppressed. Press G to restore.");
      }
      else
      {
         ObjectDelete(0,"FP_GHOST_LBL");
         if(InpShowPanel) DrawPanel();
         Print("GHOST MODE OFF -- normal mode restored. Press G to re-enable.");
      }
      ChartRedraw(0); return;
   }

   // FH Balance +/- buttons (adjust by $500 each click)
   if(id == CHARTEVENT_OBJECT_CLICK)
   {
      if(sparam == "FH_BTN_PLUS")
      {
         g_fh_balance_adj += 500;
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_STATE,false);
         Print("[FH] Balance adjusted: ",DoubleToString(InpFH_Balance+g_fh_balance_adj,0),"$",
               " (base=",InpFH_Balance,"$ adj=+",g_fh_balance_adj,"$)");
         if(InpShowPanel && !g_ghost_mode) UpdatePanel();
      }
      else if(sparam == "FH_BTN_MINUS")
      {
         g_fh_balance_adj -= 500;
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_STATE,false);
         Print("[FH] Balance adjusted: ",DoubleToString(InpFH_Balance+g_fh_balance_adj,0),"$",
               " (base=",InpFH_Balance,"$ adj=",g_fh_balance_adj,"$)");
         if(InpShowPanel && !g_ghost_mode) UpdatePanel();
      }
   }

   if(id==CHARTEVENT_CHART_CHANGE && InpShowPanel && !g_ghost_mode) DrawPanel();
}

//===================================================================
// ONTICK
//===================================================================
void OnTick()
{
   // FundedHive risk manager -- runs every tick (not just new bars)
   if(InpFH_Enable) FH_UpdatePnL();

   ManageTrades();
   if(InpShowPanel && !g_ghost_mode) UpdatePanel();

   datetime bar0 = iTime(_Symbol,PERIOD_M1,0);
   if(bar0 == g_last_bar) return;
   g_last_bar = bar0;

   if(!GlobalVariableCheck("FP_READY"))
   { Print("ERROR: FP_READY not found"); return; }

   // ── Stale detection: timezone-safe ─────────────────────────────────
   // Problem with TimeCurrent()-fp_bar_time: ClusterDelta writes bar_time in
   // futures market timezone (CME), broker uses different timezone -> always
   // shows 2-7hr gap even when data is live. Absolute comparison is broken.
   //
   // Solution: check whether FP_READY VALUE has changed since last bar.
   // If it's the same for 3+ consecutive M1 bars -> ClusterDelta stopped updating.
   // This is completely timezone-independent.
   double fp_ready_now = GlobalVariableGet("FP_READY");
   if(fp_ready_now != g_prev_fp_ready)
   {
      g_prev_fp_ready = fp_ready_now;
      g_fp_stale_bars = 0;          // updated -- reset stale counter
   }
   else
   {
      g_fp_stale_bars++;            // same value -- increment stale counter
   }
   // Show stale bar count on dashboard (g_last_fp_secs reused for display)
   g_last_fp_secs = g_fp_stale_bars;

   datetime fp_bar_time = (datetime)fp_ready_now;
   datetime expected    = iTime(_Symbol,PERIOD_M1,1);
   if(InpLog && !g_ghost_mode)
      Print("-- Bar ",TimeToString(expected),
            " | FP bar ",TimeToString(fp_bar_time),
            " | stale=",g_fp_stale_bars,"bars");

   // Stale if FP_READY unchanged for 3+ bars (3+ minutes with no new footprint)
   if(g_fp_stale_bars >= 3)
   { if(InpLog && !g_ghost_mode) Print("  SKIP: ClusterDelta stale -- no update for ",g_fp_stale_bars," bars"); return; }

   datetime bar_start = iTime(_Symbol,PERIOD_M1,0);
   if(g_last_fp_bar == bar_start)
   { if(InpLog && !g_ghost_mode) Print("  SKIP: already processed"); return; }
   g_last_fp_bar = bar_start;

   if(!ReadFootprint())
   { if(InpLog && !g_ghost_mode) Print("  SKIP: footprint read failed"); return; }

   // Accumulate footprint data into session VWAP
   // Reset daily at 00:00 server time
   datetime today = StringToTime(TimeToString(TimeCurrent(), TIME_DATE));
   if(g_fp_vwap_date != today)
   {
      g_fp_vwap_spv  = 0;
      g_fp_vwap_sv   = 0;
      g_fp_vwap      = 0;
      g_fp_vwap_date = today;
   }
   for(int fi = 0; fi < g_count; fi++)
   {
      double vol = (double)(g_bid[fi] + g_ask[fi]);
      if(vol > 0)
      {
         g_fp_vwap_spv += g_price[fi] * (double)vol;
         g_fp_vwap_sv  += (double)vol;
      }
   }
   if(g_fp_vwap_sv > 0) g_fp_vwap = g_fp_vwap_spv / g_fp_vwap_sv;

   // ── FULL-BAR DELTA -- [G] Regime-Aware Delta Filter ───────────────────
   // Sum ask-bid across ALL price levels in this bar
   // Positive = net buying pressure, Negative = net selling pressure
   // Used by [G] filter in Execute() and logged in STATUS line
   g_bar_delta = 0;
   for(int di = 0; di < g_count; di++)
      g_bar_delta += (long)g_ask[di] - (long)g_bid[di];
   // Build a price->volume map across all footprint bars this session
   // Reset at same time as VWAP (00:00 server time)
   if(g_poc_date != today)
   {
      ArrayInitialize(g_vp_price, 0);
      ArrayInitialize(g_vp_vol,   0);
      g_vp_count  = 0;
      g_poc_price = 0;
      g_poc_vol   = 0;
      g_vah_price = 0;
      g_val_price = 0;
      g_poc_bars  = 0;
      g_poc_date  = today;
   }

   // Merge current bar's footprint levels into the session volume profile
   for(int pi = 0; pi < g_count; pi++)
   {
      long vol = g_bid[pi] + g_ask[pi];
      if(vol <= 0) continue;
      double price = NormalizeDouble(g_price[pi], 2);

      // Find if this price already exists in profile
      bool found = false;
      for(int vi = 0; vi < g_vp_count; vi++)
      {
         if(MathAbs(g_vp_price[vi] - price) < 0.005)
         {
            g_vp_vol[vi] += vol;
            found = true;
            break;
         }
      }
      // Add new level if not found and space available
      if(!found && g_vp_count < VP_MAX_LEVELS)
      {
         g_vp_price[g_vp_count] = price;
         g_vp_vol  [g_vp_count] = vol;
         g_vp_count++;
      }
   }
   g_poc_bars++;

   // Recalculate POC and Value Area (70%) from accumulated profile
   if(g_vp_count > 0)
   {
      // Find POC -- level with maximum volume
      g_poc_vol   = 0;
      g_poc_price = 0;
      long total_vol_profile = 0;
      for(int vi = 0; vi < g_vp_count; vi++)
      {
         total_vol_profile += g_vp_vol[vi];
         if(g_vp_vol[vi] > g_poc_vol)
         {
            g_poc_vol   = g_vp_vol[vi];
            g_poc_price = g_vp_price[vi];
         }
      }

      // Value Area: 70% of total session volume centred around POC
      // Sort levels by price to build ordered profile, then expand outward from POC
      // Simple approach: find price range that contains 70% of volume
      long target_vol  = (long)(total_vol_profile * 0.70);
      long area_vol    = g_poc_vol;
      double area_hi   = g_poc_price;
      double area_lo   = g_poc_price;

      // Expand outward from POC, always taking the side with more volume next
      for(int step = 0; step < g_vp_count && area_vol < target_vol; step++)
      {
         // Find best candidate above and below current area
         double best_hi_price = 0; long best_hi_vol = 0;
         double best_lo_price = 999999; long best_lo_vol = 0;

         for(int vi = 0; vi < g_vp_count; vi++)
         {
            double p = g_vp_price[vi]; long v = g_vp_vol[vi];
            if(p > area_hi && (best_hi_price == 0 || p < best_hi_price))
               { best_hi_price = p; best_hi_vol = v; }
            if(p < area_lo && (best_lo_price == 999999 || p > best_lo_price))
               { best_lo_price = p; best_lo_vol = v; }
         }

         // Take whichever side has more volume (or top if equal)
         if(best_hi_vol >= best_lo_vol && best_hi_price > 0)
            { area_hi = best_hi_price; area_vol += best_hi_vol; }
         else if(best_lo_price < 999999)
            { area_lo = best_lo_price; area_vol += best_lo_vol; }
         else
            break;
      }
      g_vah_price = area_hi;
      g_val_price = area_lo;
   }

   // ── STATUS LINE -- one line per bar showing full filter context ──────
   if(InpLog && !g_ghost_mode)
   {
      double vwap_now  = CalcVWAP();
      double mid_price = (g_bar_high + g_bar_low) / 2.0;
      double vwap_dist = mid_price - vwap_now;
      string vwap_ok   = (MathAbs(vwap_dist) <= InpVWAP_ExtDist) ? "OK"
                         : (vwap_dist > 0 ? "BUY-BLOCK" : "SELL-BLOCK");
      string vwap_str  = (vwap_now > 0)
                         ? StringFormat("%.2f(%+.1fpts %s)", vwap_now, vwap_dist, vwap_ok)
                         : "n/a";
      string l1_str    = StringFormat("M1 %s(ADX=%.1f gap=%.2f)",
                                      g_regime_str, g_last_adx, g_last_ema_gap);

      // Full-bar delta = total ask vol - total bid vol across ALL price levels
      // Positive = buyers dominated the bar (net buying pressure)
      // Negative = sellers dominated (net selling pressure)
      // Used for post-session analysis -- NOT a filter yet, data collection only
      // Full-bar delta -- already computed as g_bar_delta above
      string delta_str = (g_bar_delta > 0)
                         ? StringFormat("+%d (BUY)",  g_bar_delta)
                         : StringFormat("%d (SELL)", g_bar_delta);

      // POC/VAH/VAL summary for log
      string poc_str = (g_poc_price > 0 && g_poc_bars >= 10)
                       ? StringFormat("POC=%.2f  VAH=%.2f  VAL=%.2f  (%dbars)",
                                      g_poc_price, g_vah_price, g_val_price, g_poc_bars)
                       : StringFormat("POC=building(%dbars)", g_poc_bars);

      Print("  STATUS  Regime=",l1_str,"  VWAP=",vwap_str,"  DELTA=",delta_str);
      Print("  ",poc_str);
   }

   if(InpLog && !g_ghost_mode)
      Print("  levels=",g_count," H=",DoubleToString(g_bar_high,2),
            " L=",DoubleToString(g_bar_low,2));

   int sell_max=0, buy_max=0;
   int sell_rows = SellSignalRows(sell_max);
   int buy_rows  = BuySignalRows(buy_max);

   if(InpLog && !g_ghost_mode)
   {
      if(sell_rows>0)
         Print("  SELL | rows=",sell_rows," vol=",sell_max,
               " zone=",DoubleToString(g_imbalance_top,2),
               (sell_max>=InpStrongVol?" *** STRONG ***":" [normal]"));
      if(buy_rows>0)
         Print("  BUY  | rows=",buy_rows," vol=",buy_max,
               " zone=",DoubleToString(g_imbalance_bot,2),
               (buy_max>=InpStrongVol?" *** STRONG ***":" [normal]"));
      if(sell_rows==0 && buy_rows==0)
         Print("  No signal");
   }

   if(sell_rows>0 && buy_rows>0)
   { if(InpLog && !g_ghost_mode) Print("  SKIP: conflicting signals"); return; }

   if(sell_rows>0)
   {
      g_last_signal = (sell_max>=InpStrongVol
                       ?"!! SELL STRONG":"v SELL x"+IntegerToString(sell_rows));
      Execute(ORDER_TYPE_SELL,sell_rows,sell_max);
   }
   if(buy_rows>0)
   {
      g_last_signal = (buy_max>=InpStrongVol
                       ?"!! BUY STRONG":"^ BUY x"+IntegerToString(buy_rows));
      Execute(ORDER_TYPE_BUY,buy_rows,buy_max);
   }
   if(sell_rows==0 && buy_rows==0)
      g_last_signal = "No signal";

   // Update regime and momentum every bar
   DetectRegime();

   // ── [I] MOMENTUM OVERRIDE ────────────────────────────────────────────
   // Compute before Execute() so it's ready when signals are evaluated
   // Counts bearish/bullish candles in last InpMomLookback bars
   // If strong momentum contradicts EMA regime + price already crossed EMA8
   // -> temporarily allow the counter-direction signal
   g_mom_override_sell = false;
   g_mom_override_buy  = false;
   if(InpMomOverride && InpRegime_Enable && g_ema_fast_now > 0)
   {
      double cur_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      int bear_count = 0, bull_count = 0;
      for(int ci = 1; ci <= InpMomLookback; ci++)
      {
         double o = iOpen(_Symbol,PERIOD_M1,ci);
         double c = iClose(_Symbol,PERIOD_M1,ci);
         if(c < o) bear_count++;
         else if(c > o) bull_count++;
      }
      // Bear override: TREND UP but 3+ bearish candles + price below EMA8
      // Real momentum is down -- allow SELL signals temporarily
      if(g_regime == REGIME_TREND_UP &&
         bear_count >= InpMomMinCandles &&
         cur_price < g_ema_fast_now)
      {
         g_mom_override_sell = true;
         g_mom_override_count++;
         if(InpLog && !g_ghost_mode)
            Print("[I] MOMENTUM OVERRIDE: bear=",bear_count,"/",InpMomLookback,
                  " candles, price=",DoubleToString(cur_price,2),
                  " < EMA8=",DoubleToString(g_ema_fast_now,2),
                  " in TREND UP -> SELL temporarily allowed");
      }
      // Bull override: TREND DN but 3+ bullish candles + price above EMA8
      // Real momentum is up -- allow BUY signals temporarily
      if(g_regime == REGIME_TREND_DN &&
         bull_count >= InpMomMinCandles &&
         cur_price > g_ema_fast_now)
      {
         g_mom_override_buy = true;
         g_mom_override_count++;
         if(InpLog && !g_ghost_mode)
            Print("[I] MOMENTUM OVERRIDE: bull=",bull_count,"/",InpMomLookback,
                  " candles, price=",DoubleToString(cur_price,2),
                  " > EMA8=",DoubleToString(g_ema_fast_now,2),
                  " in TREND DN -> BUY temporarily allowed");
      }
   }

   // ── [J] STRUCTURE ENGINE ─────────────────────────────────────────
   DetectStructure();
}

//===================================================================
// MANAGE TRADES -- Dynamic Exit Engine
//===================================================================
void ManageTrades()
{
   datetime now = TimeCurrent();

   // Bar-level flag -- bar checks only once per bar close
   bool new_bar = false;
   datetime bar0 = iTime(_Symbol,PERIOD_M1,0);
   if(bar0 != g_last_manage_bar)
   { new_bar=true; g_last_manage_bar=bar0; }

   for(int i=g_trade_cnt-1; i>=0; i--)
   {
      ulong ticket = g_trades[i].ticket;
      if(!PositionSelectByTicket(ticket))
      { RecordClosedTrade(ticket); RemoveTrade(i); continue; }

      double cur     = PositionGetDouble(POSITION_PRICE_CURRENT);
      int    ptype   = (int)PositionGetInteger(POSITION_TYPE);
      bool   is_buy  = (ptype==POSITION_TYPE_BUY);
      double move    = is_buy ? cur-g_trades[i].open_price
                              : g_trades[i].open_price-cur;
      double floating= PositionGetDouble(POSITION_PROFIT);
      bool   in_profit = (move > 0);
      bool   in_loss   = (move < -InpThesisMinLoss);

      //── [A] TIMEOUT ──────────────────────────────────────────────
      int mins = (int)((now-g_trades[i].open_time)/60);
      if(mins>=InpTimeout && MathAbs(move)<InpMinMove)
      {
         if(InpLog) Print("TIMEOUT ticket=",ticket," ",mins,"min");
         bool _cl_TO = (InpFH_Enable && InpFH_SLTPOnly)
                        ? CloseViaSL(ticket, "TIMEOUT")
                        : Trade.PositionClose(ticket);
         g_timeouts++;
         RemoveTrade(i);
         continue;
      }

      //── [B] APPROACH EXIT (every tick) ───────────────────────────
      {
         double target    = g_trades[i].tp1_hit ? g_trades[i].tp2 : g_trades[i].tp1;
         double dist_to_tp= is_buy ? (target-cur) : (cur-target);

         if(dist_to_tp>=0 && dist_to_tp<=InpApproachDist)
         {
            if(!g_trades[i].tp1_hit)
            {
               // Approach TP1 -- partial close 50%, move SL to BE
               double vol = PositionGetDouble(POSITION_VOLUME);
               double cl50 = NormalizeDouble(vol*0.5,2);
               if(cl50 < SymbolInfoDouble(_Symbol,SYMBOL_VOLUME_MIN)) cl50=vol;

               if(Trade.PositionClosePartial(ticket,cl50))
               {
                  g_trades[i].tp1_hit = true;
                  g_tp1_closes++;
                  g_approach_exits++;
                  double be = NormalizeDouble(g_trades[i].open_price,_Digits);
                  if(Trade.PositionModify(ticket,be,g_trades[i].tp2))
                     g_trades[i].sl = be;
                  if(InpLog)
                     Print("[B] APPROACH TP1 ticket=",ticket,
                           " price=",DoubleToString(cur,2),
                           " dist=",DoubleToString(dist_to_tp,2),
                           " -> BE=",DoubleToString(be,2));
               }
            }
            else
            {
               // Approach TP2 -- full close (via TP for FH compliance)
               bool _cl_B2 = (InpFH_Enable && InpFH_SLTPOnly)
                             ? CloseViaTP(ticket, g_trades[i].tp2, "B_TP2")
                             : Trade.PositionClose(ticket);
               if(_cl_B2)
               {
                  g_approach_exits++;
                  if(InpLog)
                     Print("[B] APPROACH TP2 ticket=",ticket,
                           " price=",DoubleToString(cur,2));
                  RemoveTrade(i);
                  continue;
               }
            }
         }
      }

      // Bar-level checks only on new bar close
      if(!new_bar) continue;

      //── [C] TRAILING STRUCTURAL STOP (after TP1 only) ────────────
      if(g_trades[i].tp1_hit)
      {
         if(is_buy)
         {
            // Trail = lowest low of last N bars - buffer
            double lowest = iLow(_Symbol,PERIOD_M1,1);
            for(int b=2; b<=InpTrailBars; b++)
               lowest = MathMin(lowest,iLow(_Symbol,PERIOD_M1,b));
            double trail = NormalizeDouble(lowest-InpMinBuffer,_Digits);

            if(trail > g_trades[i].sl && trail < cur)
            {
               if(Trade.PositionModify(ticket,trail,g_trades[i].tp2))
               {
                  if(InpLog)
                     Print("[C] TRAIL UP ticket=",ticket,
                           " SL ",DoubleToString(g_trades[i].sl,2),
                           "->",DoubleToString(trail,2));
                  g_trades[i].sl = trail;
               }
            }
         }
         else
         {
            // Trail = highest high of last N bars + buffer
            double highest = iHigh(_Symbol,PERIOD_M1,1);
            for(int b=2; b<=InpTrailBars; b++)
               highest = MathMax(highest,iHigh(_Symbol,PERIOD_M1,b));
            double trail = NormalizeDouble(highest+InpMinBuffer,_Digits);

            if(trail < g_trades[i].sl && trail > cur)
            {
               if(Trade.PositionModify(ticket,trail,g_trades[i].tp2))
               {
                  if(InpLog)
                     Print("[C] TRAIL DN ticket=",ticket,
                           " SL ",DoubleToString(g_trades[i].sl,2),
                           "->",DoubleToString(trail,2));
                  g_trades[i].sl = trail;
               }
            }
         }
      }

      //── [D] MOMENTUM DECAY EXIT (in profit, before TP1 only) ─────
      // Disabled when InpFH_SLTPOnly=true (FundedHive rule: SL/TP only)
      if(in_profit && !g_trades[i].tp1_hit && InpDecayRatio>0
         && !(InpFH_Enable && InpFH_SLTPOnly))
      {
         double r1 = iHigh(_Symbol,PERIOD_M1,1)-iLow(_Symbol,PERIOD_M1,1);
         double r2 = iHigh(_Symbol,PERIOD_M1,2)-iLow(_Symbol,PERIOD_M1,2);

         // Avg of last 5 bars for context
         double avg=0;
         for(int b=1; b<=5; b++)
            avg += iHigh(_Symbol,PERIOD_M1,b)-iLow(_Symbol,PERIOD_M1,b);
         avg /= 5.0;

         // Both vs prev AND vs avg must collapse -- prevents single-bar noise
         if(r2>0 && r1<r2*InpDecayRatio && r1<avg*InpDecayRatio)
         {
            bool _cl_D = (InpFH_Enable && InpFH_SLTPOnly)
                         ? CloseViaSL(ticket, "D_DECAY")
                         : Trade.PositionClose(ticket);
            if(_cl_D)
            {
               g_momentum_exits++;
               if(InpLog)
                  Print("[D] DECAY ticket=",ticket,
                        " range=",DoubleToString(r1,2),
                        " prev=",DoubleToString(r2,2),
                        " ratio=",DoubleToString(r1/r2,2),
                        " pnl=",DoubleToString(floating,2));
               RemoveTrade(i);
               continue;
            }
         }
      }

      //── [E] THESIS INVALIDATION (in loss only) ───────────────────
      // SELL losing: 2 green bars + buyer imbalance at bottom = exit
      // BUY  losing: 2 red bars  + seller imbalance at top   = exit
      // Disabled when InpFH_SLTPOnly=true (FundedHive: SL/TP only)
      if(in_loss && !(InpFH_Enable && InpFH_SLTPOnly))
      {
         double o1=iOpen(_Symbol,PERIOD_M1,1), c1=iClose(_Symbol,PERIOD_M1,1);
         double o2=iOpen(_Symbol,PERIOD_M1,2), c2=iClose(_Symbol,PERIOD_M1,2);

         bool two_opposing = is_buy
                             ? (c1<o1 && c2<o2)   // 2 red bars on BUY
                             : (c1>o1 && c2>o2);  // 2 green bars on SELL

         if(two_opposing)
         {
            int dummy=0;
            bool conf = false;
            if(is_buy)
            {
               // BUY losing: check for seller imbalance at top
               int sr = SellSignalRows(dummy, InpThesisVol);
               conf = (sr>0);
            }
            else
            {
               // SELL losing: check for buyer imbalance at bottom
               int br = BuySignalRows(dummy, InpThesisVol);
               conf = (br>0);
            }

            if(conf)
            {
               bool _cl_E = (InpFH_Enable && InpFH_SLTPOnly)
                            ? CloseViaSL(ticket, "E_THESIS")
                            : Trade.PositionClose(ticket);
               if(_cl_E)
               {
                  g_thesis_exits++;
                  if(InpLog)
                     Print("[E] THESIS DEAD ticket=",ticket,
                           (is_buy?" 2red+sellImbal":" 2green+buyImbal"),
                           " vol>=",InpThesisVol,
                           " loss=",DoubleToString(MathAbs(move),2),"pts",
                           " saved=",
                           DoubleToString(MathAbs(g_trades[i].sl-cur),2),"pts");
                  RemoveTrade(i);
                  continue;
               }
            }
         }
      }

      //── [F] COUNTER-SIGNAL EXIT ───────────────────────────────────
      // Disabled when InpFH_SLTPOnly=true (FundedHive: SL/TP only)
      if(InpCounterSig_Enable && new_bar && !(InpFH_Enable && InpFH_SLTPOnly))
      {
         int  counter_vol = 0;
         bool counter_sig = false;

         if(is_buy)
         {
            // BUY trade: check for opposing SELL signal
            int sr = SellSignalRows(counter_vol, InpCounterSig_MinVol);
            if(sr > 0) counter_sig = true;
         }
         else
         {
            // SELL trade: check for opposing BUY signal
            int br = BuySignalRows(counter_vol, InpCounterSig_MinVol);
            if(br > 0) counter_sig = true;
         }

         if(counter_sig)
         {
            double saved_pts = MathAbs(g_trades[i].sl - cur);

            if(in_loss)
            {
               // State 1: In loss -> close immediately (via SL for FH)
               bool _cl_F = (InpFH_Enable && InpFH_SLTPOnly)
                            ? CloseViaSL(ticket, "F_COUNTER")
                            : Trade.PositionClose(ticket);
               if(_cl_F)
               {
                  g_counter_exits++;
                  Print("[F] COUNTER-SIG CLOSE ticket=",ticket,
                        (is_buy?" SELL":"  BUY")," v=",counter_vol,
                        " trade in loss=",DoubleToString(MathAbs(move),2),"pts",
                        " saved=",DoubleToString(saved_pts,2),"pts");
                  RemoveTrade(i);
                  continue;
               }
            }
            else if(!g_trades[i].tp1_hit)
            {
               // State 2: In profit, pre-TP1 -> move SL to breakeven
               double be = NormalizeDouble(g_trades[i].open_price, _Digits);
               // Only move SL if it improves (moves closer to price)
               bool improve = is_buy ? (be > g_trades[i].sl)
                                     : (be < g_trades[i].sl);
               if(improve && Trade.PositionModify(ticket, be, g_trades[i].tp2))
               {
                  g_trades[i].sl = be;
                  g_counter_exits++;
                  Print("[F] COUNTER-SIG BE  ticket=",ticket,
                        (is_buy?" SELL":"  BUY")," v=",counter_vol,
                        " profit=",DoubleToString(move,2),"pts",
                        " SL moved to BE=",DoubleToString(be,2));
               }
            }
            else
            {
               // State 3: Post-TP1 -> lock SL at TP1 level
               double lock = NormalizeDouble(g_trades[i].tp1, _Digits);
               bool improve = is_buy ? (lock > g_trades[i].sl)
                                     : (lock < g_trades[i].sl);
               if(improve && Trade.PositionModify(ticket, lock, g_trades[i].tp2))
               {
                  g_trades[i].sl = lock;
                  g_counter_exits++;
                  Print("[F] COUNTER-SIG LOCK ticket=",ticket,
                        (is_buy?" SELL":"  BUY")," v=",counter_vol,
                        " profit=",DoubleToString(move,2),"pts",
                        " SL locked at TP1=",DoubleToString(lock,2));
               }
            }
         }
      }
   }
}

//===================================================================
// REGIME DETECTION
//===================================================================
void DetectRegime()
{
   if(!InpRegime_Enable) return;

   // Need at least InpRegimeBars+2 M15 bars
   if(iBars(_Symbol,PERIOD_M1)  < InpRegimeBars+5) return;

   // --- Read EMA values from handles ---
   // Dynamic arrays required for ArraySetAsSeries (static arrays not allowed)
   double ema_f[], ema_s[], adx_buf[];
   ArrayResize(ema_f,  7);
   ArrayResize(ema_s,  1);
   ArrayResize(adx_buf,1);
   ArraySetAsSeries(ema_f,  true);
   ArraySetAsSeries(ema_s,  true);
   ArraySetAsSeries(adx_buf,true);
   if(CopyBuffer(g_h_ema_fast,0,0,7,ema_f)  < 7) return;
   if(CopyBuffer(g_h_ema_slow,0,0,1,ema_s)  < 1) return;
   if(CopyBuffer(g_h_adx,    0,0,1,adx_buf) < 1) return;

   double ema_fast  = ema_f[0];        // current M15 bar
   double ema_slow  = ema_s[0];
   double adx       = adx_buf[0];
   double slope     = ema_f[0] - ema_f[5];  // change over last 5 M15 bars

   // Cache for status log line and [H] price confirm filter
   g_last_adx     = adx;
   g_last_ema_gap = MathAbs(ema_fast - ema_slow);
   g_ema_fast_now = ema_fast;   // [H] cached EMA8 -- used in Execute() price confirm

   // --- EMA gap guard with hysteresis --------------------------------
   // Enter RANGE(conv): gap < InpEMA_MinGap
   // Exit  RANGE(conv): gap > InpEMA_MinGap + InpEMA_HystGap
   // Prevents flicker when gap oscillates right on the threshold
   double ema_gap     = MathAbs(ema_fast - ema_slow);
   double conv_exit   = InpEMA_MinGap + InpEMA_HystGap;  // e.g. 2.0 + 0.5 = 2.5

   if(g_in_conv)
   {
      // Already in RANGE(conv) -- only exit if gap clears the hysteresis band
      if(ema_gap < conv_exit)
      {
         // Still converged -- stay in RANGE(conv)
         MarketRegime prev = g_regime;
         g_regime     = REGIME_RANGE;
         g_regime_str = "RANGE(conv)";
         if(g_regime != prev && InpLog)
            Print("[REGIME] -> RANGE(conv)  EMA gap=",DoubleToString(ema_gap,2),
                  "pts  (hyst band: ",DoubleToString(InpEMA_MinGap,1),
                  "-",DoubleToString(conv_exit,1),")  ADX=",DoubleToString(adx,1));
         return;
      }
      // Gap cleared hysteresis -- exit RANGE(conv), fall through to trend/range logic
      g_in_conv = false;
      if(InpLog)
         Print("[REGIME] Exiting RANGE(conv)  gap=",DoubleToString(ema_gap,2),
               " > hyst exit=",DoubleToString(conv_exit,1));
   }
   else if(ema_gap < InpEMA_MinGap)
   {
      // Entering RANGE(conv) for the first time
      g_in_conv    = true;
      MarketRegime prev = g_regime;
      g_regime     = REGIME_RANGE;
      g_regime_str = "RANGE(conv)";
      if(g_regime != prev && InpLog)
         Print("[REGIME] -> RANGE(conv)  EMA gap=",DoubleToString(ema_gap,2),
               "pts < min ",DoubleToString(InpEMA_MinGap,1),
               "  ADX=",DoubleToString(adx,1));
      return;
   }

   // --- Trend detection ---
   if(adx >= InpADX_Trend && MathAbs(slope) >= InpTrendSlope)
   {
      MarketRegime prev = g_regime;
      g_regime = (ema_fast > ema_slow) ? REGIME_TREND_UP : REGIME_TREND_DN;

      if(g_regime != prev)
      {
         g_regime_str = (g_regime==REGIME_TREND_UP) ? "TREND UP" : "TREND DN";
         if(InpLog)
            Print("[REGIME] -> ",g_regime_str,
                  "  ADX=",DoubleToString(adx,1),
                  "  EMA",InpEMA_Fast,"=",DoubleToString(ema_fast,2),
                  "  EMA",InpEMA_Slow,"=",DoubleToString(ema_slow,2),
                  "  gap=",DoubleToString(ema_gap,2),
                  "  slope=",DoubleToString(slope,2),"pts");
      }
      return;
   }

   // --- Range / Breakout detection ---
   if(adx <= InpADX_Range)
   {
      // Find range high/low over last N M15 bars
      double rh = iHigh(_Symbol,PERIOD_M1,1);
      double rl = iLow (_Symbol,PERIOD_M1,1);
      for(int i=2; i<=InpRegimeBars; i++)
      {
         rh = MathMax(rh, iHigh(_Symbol,PERIOD_M1,i));
         rl = MathMin(rl, iLow (_Symbol,PERIOD_M1,i));
      }

      // ATR buffer for breakout detection (avoid false breaks)
      double m1_atr = 0;
      for(int i=1; i<=5; i++)
         m1_atr += iHigh(_Symbol,PERIOD_M1,i)-iLow(_Symbol,PERIOD_M1,i);
      m1_atr /= 5.0;
      double brk_buf = m1_atr * 0.20;

      double cur = iClose(_Symbol,PERIOD_M1,0);
      MarketRegime prev = g_regime;

      if(cur > rh + brk_buf)
      {
         g_regime     = REGIME_BREAKOUT_UP;
         g_regime_str = "BREAKOUT UP";
      }
      else if(cur < rl - brk_buf)
      {
         g_regime     = REGIME_BREAKOUT_DN;
         g_regime_str = "BREAKOUT DN";
      }
      else
      {
         g_regime     = REGIME_RANGE;
         g_regime_str = "RANGE";
      }

      if(g_regime != prev && InpLog)
         Print("[REGIME] -> ",g_regime_str,
               "  ADX=",DoubleToString(adx,1),
               "  range H=",DoubleToString(rh,2),
               " L=",DoubleToString(rl,2),
               "  cur=",DoubleToString(cur,2));
      return;
   }

   // --- Transition zone (ADX between InpADX_Range and InpADX_Trend) ---
   // Keep previous regime -- do not flip in ambiguous zone
}

//===================================================================
// HELPERS
//===================================================================

//===================================================================
// FH COMPLIANCE: CloseViaSL / CloseViaTP
// Instead of market-closing a trade, move SL to current price
// so the broker closes it via SL/TP hit on next tick.
// This satisfies prop firm rule: "every trade must close via SL or TP"
//===================================================================
bool CloseViaSL(ulong ticket, string reason)
{
   if(!PositionSelectByTicket(ticket)) return false;
   bool is_buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double cur  = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                        : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double tp   = PositionGetDouble(POSITION_TP);
   // Move SL to current price -- will be hit on next tick
   // Add 1 tick in correct direction to ensure it triggers
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   double new_sl = is_buy ? (cur - tick) : (cur + tick);
   new_sl = NormalizeDouble(new_sl, _Digits);
   if(Trade.PositionModify(ticket, new_sl, tp))
   {
      if(InpLog) Print("  [FH-SL] Moved SL to ",DoubleToString(new_sl,2),
                       " (will close via SL) -- reason: ",reason);
      return true;
   }
   return false;
}

bool CloseViaTP(ulong ticket, double tp_price, string reason)
{
   // Move SL just past TP so price hits TP first
   // Used by [B] approach -- instead of closing, ensure TP is hit
   if(!PositionSelectByTicket(ticket)) return false;
   bool is_buy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   double cur_sl = PositionGetDouble(POSITION_SL);
   double tick   = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   // Move SL very close to current price (behind price, not at TP)
   double cur = is_buy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                       : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double new_sl = is_buy ? (cur - tick) : (cur + tick);
   new_sl = NormalizeDouble(new_sl, _Digits);
   if(Trade.PositionModify(ticket, new_sl, tp_price))
   {
      if(InpLog) Print("  [FH-TP] Moved SL to ",DoubleToString(new_sl,2),
                       " TP=",DoubleToString(tp_price,2),
                       " (will close via TP) -- reason: ",reason);
      return true;
   }
   return false;
}

//===================================================================
// FUNDEDHIVE RISK MANAGER -- Helper Functions
//===================================================================

// Check if we are within InpFH_NewsBuffer minutes of a red news event
bool IsHighImpactNewsTime()
{
   if(!InpFH_Enable || InpFH_NewsBuffer <= 0) return false;
   datetime now   = TimeCurrent();
   datetime from  = now - (datetime)(InpFH_NewsBuffer * 60);
   datetime to    = now + (datetime)(InpFH_NewsBuffer * 60);
   MqlCalendarValue values[];
   int count = CalendarValueHistory(values, from, to, "USD", NULL);
   for(int i = 0; i < count; i++)
   {
      MqlCalendarEvent ev;
      if(CalendarEventById(values[i].event_id, ev))
         if(ev.importance == CALENDAR_IMPORTANCE_HIGH)
            return true;
   }
   return false;
}

// Update daily P&L -- call every tick
void FH_UpdatePnL()
{
   if(!InpFH_Enable) return;
   double balance  = AccountInfoDouble(ACCOUNT_BALANCE);
   double equity   = AccountInfoDouble(ACCOUNT_EQUITY);
   double used_bal = InpFH_Balance + g_fh_balance_adj;

   // Daily reset at new trading day
   MqlDateTime dt; TimeToStruct(TimeCurrent(), dt);
   MqlDateTime ld; TimeToStruct(g_fh_last_day,   ld);
   if(dt.day != ld.day || g_fh_last_day == 0)
   {
      g_fh_day_start_balance = balance;
      g_fh_daily_pnl         = 0;
      g_fh_daily_stopped     = false;
      g_fh_last_day          = TimeCurrent();
      if(InpLog) Print("[FH] New trading day -- daily limit reset. Balance=",
                       DoubleToString(balance,2));
   }

   // Today's realized + floating P&L
   double floating = equity - balance;
   g_fh_daily_pnl  = (balance - g_fh_day_start_balance) + floating;
   g_fh_total_pnl  = (balance - used_bal) + floating;

   // Check daily limit
   double daily_limit_usd = used_bal * InpFH_DailyLimit / 100.0;
   if(!g_fh_daily_stopped && g_fh_daily_pnl <= -daily_limit_usd)
   {
      g_fh_daily_stopped = true;
      Print("[FH] !!! DAILY LIMIT HIT: ",DoubleToString(g_fh_daily_pnl,2),
            "$ >= -",DoubleToString(daily_limit_usd,2),"$ (",InpFH_DailyLimit,"%) -- NO MORE TRADES TODAY");
   }

   // Check max loss
   double max_loss_usd = used_bal * InpFH_MaxLoss / 100.0;
   if(!g_fh_max_stopped && g_fh_total_pnl <= -max_loss_usd)
   {
      g_fh_max_stopped = true;
      Print("[FH] MAX LOSS HIT: ",DoubleToString(g_fh_total_pnl,2),
            "$ >= -",DoubleToString(max_loss_usd,2),"$ (",InpFH_MaxLoss,"%) -- EA STOPPED PERMANENTLY");
   }

   // Check target
   double target_usd = used_bal * FH_Target() / 100.0;
   if(!g_fh_target_hit && g_fh_total_pnl >= target_usd)
   {
      g_fh_target_hit = true;
      Print("[FH] >>> TARGET HIT: +",DoubleToString(g_fh_total_pnl,2),
            "$ >= +",DoubleToString(target_usd,2),"$ (",FH_Target(),"%) -- PHASE ",InpFH_Phase," COMPLETE!");
      if(InpFH_PauseOnTarget)
         Print("[FH] EA paused -- withdraw or confirm pass before resuming");
   }
}

//===================================================================
// [J] STRUCTURE ENGINE -- Phase 1
// Detects: Swing High/Low Revisit + Liquidity Sweep
//===================================================================
void DetectStructure()
{
   if(!InpStructEnable) return;

   int lookback = InpStructLookback;
   if(iBars(_Symbol, PERIOD_M1) < lookback + 3) return;

   // ── Find most recent swing high and swing low ────────────────────
   // Swing high: bar[i].high is higher than bar[i-1] AND bar[i+1]
   // Swing low:  bar[i].low  is lower  than bar[i-1] AND bar[i+1]
   // We look back InpStructLookback bars to find the most recent ones
   double found_high = 0, found_low = 999999;
   for(int i = 2; i <= lookback; i++)
   {
      double hi  = iHigh(_Symbol, PERIOD_M1, i);
      double hi1 = iHigh(_Symbol, PERIOD_M1, i-1); // one bar newer
      double hi2 = iHigh(_Symbol, PERIOD_M1, i+1); // one bar older
      double lo  = iLow (_Symbol, PERIOD_M1, i);
      double lo1 = iLow (_Symbol, PERIOD_M1, i-1);
      double lo2 = iLow (_Symbol, PERIOD_M1, i+1);

      // Swing high: higher than both neighbours
      if(hi > hi1 && hi > hi2)
         if(found_high == 0 || hi > found_high)
            found_high = hi;

      // Swing low: lower than both neighbours
      if(lo < lo1 && lo < lo2)
         if(found_low == 999999 || lo < found_low)
            found_low = lo;
   }

   // Store the found swing levels (fallback to recent bar if none found)
   if(found_high > 0)     g_last_swing_high = found_high;
   if(found_low < 999999) g_last_swing_low  = found_low;

   // ── Current price for proximity checks ──────────────────────────
   double cur_price  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double cur_bar_h  = iHigh (_Symbol, PERIOD_M1, 1); // last completed bar
   double cur_bar_l  = iLow  (_Symbol, PERIOD_M1, 1);
   double cur_bar_c  = iClose(_Symbol, PERIOD_M1, 1);

   // ── Structure 1: Swing Level Revisit ────────────────────────────
   // Price is currently within InpStructDist pts of a meaningful swing level
   // These are liquidity zones -- stops cluster here -> reversal more likely
   g_near_swing_high = (g_last_swing_high > 0 &&
                        MathAbs(cur_price - g_last_swing_high) <= InpStructDist);
   g_near_swing_low  = (g_last_swing_low < 999999 &&
                        MathAbs(cur_price - g_last_swing_low)  <= InpStructDist);

   // ── Structure 2: Liquidity Sweep ────────────────────────────────
   // Last completed bar briefly broke the swing level then rejected back
   // Classic stop-hunt pattern -> strong reversal signal
   // Sweep UP (bearish): bar wick above swing high, but close back below it
   g_sweep_up = (g_last_swing_high > 0 &&
                 cur_bar_h > g_last_swing_high + InpSweepMin &&  // broke above
                 cur_bar_c < g_last_swing_high);                  // closed back below

   // Sweep DOWN (bullish): bar wick below swing low, but close back above it
   g_sweep_down = (g_last_swing_low < 999999 &&
                   cur_bar_l < g_last_swing_low - InpSweepMin &&  // broke below
                   cur_bar_c > g_last_swing_low);                  // closed back above

   // ── Score Calculation ────────────────────────────────────────────
   // Points accumulate -- higher score = better trade location
   g_struct_sell_score = 0;
   g_struct_buy_score  = 0;

   // Swing level revisit scores
   if(g_near_swing_high) g_struct_sell_score += 2; // at resistance -> SELL location
   if(g_near_swing_low)  g_struct_buy_score  += 2; // at support    -> BUY  location

   // Liquidity sweep scores (highest value -- stop hunt confirmed)
   if(g_sweep_up)   g_struct_sell_score += 3; // swept stops above -> bears take over
   if(g_sweep_down) g_struct_buy_score  += 3; // swept stops below -> bulls take over

   // POC extension bonus (price far from value area = stretched)
   if(g_poc_price > 0 && g_poc_bars >= 10)
   {
      double dist = cur_price - g_poc_price;
      if(dist >  5.0) g_struct_sell_score += 1; // extended above POC -> mean reversion SELL
      if(dist < -5.0) g_struct_buy_score  += 1; // extended below POC -> mean reversion BUY
   }
}
void RecordClosedTrade(ulong ticket)
{
   if(!HistoryDealSelect(0)) HistorySelect(0,TimeCurrent());
   int    total=HistoryDealsTotal();
   double profit=0;
   for(int i=total-1; i>=0; i--)
   {
      ulong deal=HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(deal,DEAL_POSITION_ID)==(long)ticket)
      {
         profit += HistoryDealGetDouble(deal,DEAL_PROFIT);
         profit += HistoryDealGetDouble(deal,DEAL_SWAP);
         profit += HistoryDealGetDouble(deal,DEAL_COMMISSION);
      }
   }
   g_session_pnl += profit;
   g_total_trades++;
   if(profit>=0){ g_wins++;   g_gross_profit+=profit; }
   else         { g_losses++; g_gross_loss+=MathAbs(profit); }
}

void RemoveTrade(int idx)
{
   for(int i=idx; i<g_trade_cnt-1; i++) g_trades[i]=g_trades[i+1];
   g_trade_cnt--;
}

double CalcATRBuffer()
{
   double sum=0;
   for(int i=1; i<=5; i++) sum+=iHigh(_Symbol,PERIOD_M1,i)-iLow(_Symbol,PERIOD_M1,i);
   double buf=(sum/5.0)*InpATR_Mult;
   if(buf<InpMinBuffer) buf=InpMinBuffer;
   if(buf>InpMaxBuffer) buf=InpMaxBuffer;
   return NormalizeDouble(buf,_Digits);
}

double CalcATR5()
{
   double sum=0;
   for(int i=1; i<=5; i++) sum+=iHigh(_Symbol,PERIOD_M1,i)-iLow(_Symbol,PERIOD_M1,i);
   return NormalizeDouble(sum/5.0,_Digits);
}

bool ReadFootprint()
{
   if(!GlobalVariableCheck("FP_COUNT")) return false;
   g_bar_high=(double)GlobalVariableGet("FP_BAR_HIGH");
   g_bar_low =(double)GlobalVariableGet("FP_BAR_LOW");
   g_count   =(int)GlobalVariableGet("FP_COUNT");
   if(g_count<=0||g_count>MAX_LVL) return false;
   for(int d=0; d<g_count; d++)
   {
      string k=IntegerToString(d);
      g_price[d]=GlobalVariableGet("FP_P_"+k);
      g_ask  [d]=(long)GlobalVariableGet("FP_A_"+k);
      g_bid  [d]=(long)GlobalVariableGet("FP_B_"+k);
   }
   return true;
}

int FindLevel(double price,long &ask_out,long &bid_out)
{
   double tol=InpTickSz*0.49;
   for(int i=0; i<g_count; i++)
      if(MathAbs(g_price[i]-price)<tol)
      { ask_out=g_ask[i]; bid_out=g_bid[i]; return i; }
   ask_out=0; bid_out=0; return -1;
}

int SellSignalRows(int &max_vol, int min_vol=-1)
{
   if(min_vol < 0) min_vol = InpMinVol;  // default = entry threshold
   int rows=0; max_vol=0; g_imbalance_top=0;
   double p=NormalizeDouble(MathRound(g_bar_high/InpTickSz)*InpTickSz,2);
   double zh=0;
   for(int r=0; r<InpTopRows; r++)
   {
      double lvl=NormalizeDouble(p-r*InpTickSz,2);
      long av,bv;
      if(FindLevel(lvl,av,bv)<0) continue;
      if(InpLog && !g_ghost_mode) Print("  TOP[",r,"] ",DoubleToString(lvl,2)," bid=",bv," ask=",av);
      if(av>=min_vol && bv==0)
      { rows++; if((int)av>max_vol)max_vol=(int)av; if(zh==0)zh=lvl; }
      else break;
   }
   if(rows>0) g_imbalance_top=zh;
   return rows;
}

int BuySignalRows(int &max_vol, int min_vol=-1)
{
   if(min_vol < 0) min_vol = InpMinVol;  // default = entry threshold
   int rows=0; max_vol=0; g_imbalance_bot=0;
   double p=NormalizeDouble(MathRound(g_bar_low/InpTickSz)*InpTickSz,2);
   double zl=0;
   for(int r=0; r<InpTopRows; r++)
   {
      double lvl=NormalizeDouble(p+r*InpTickSz,2);
      long av,bv;
      if(FindLevel(lvl,av,bv)<0) continue;
      if(InpLog && !g_ghost_mode) Print("  BOT[",r,"] ",DoubleToString(lvl,2)," bid=",bv," ask=",av);
      if(bv>=min_vol && av==0)
      { rows++; if((int)bv>max_vol)max_vol=(int)bv; if(zl==0)zl=lvl; }
      else break;
   }
   if(rows>0) g_imbalance_bot=zl;
   return rows;
}

double CalcVWAP()
{
   // Primary: footprint-based session VWAP (actual GC futures contract volume)
   // Accumulated bar-by-bar from ClusterDelta bid+ask volumes
   if(g_fp_vwap > 0) return g_fp_vwap;

   // Fallback: tick-volume VWAP (used only before first footprint bar this session)
   double spv=0,sv=0;
   int bars=MathMin(390,iBars(_Symbol,PERIOD_M1)-1);
   for(int i=bars; i>=1; i--)
   {
      double h=iHigh(_Symbol,PERIOD_M1,i);
      double l=iLow (_Symbol,PERIOD_M1,i);
      double c=iClose(_Symbol,PERIOD_M1,i);
      double v=(double)iVolume(_Symbol,PERIOD_M1,i);
      spv+=(h+l+c)/3.0*v; sv+=v;
   }
   return (sv>0)?spv/sv:0;
}

int FindEqualLevels(ENUM_ORDER_TYPE dir,double entry,
                    double &levels[],double max_dist)
{
   #define EHL_MAX 100
   double cand[EHL_MAX]; int hits[EHL_MAX]; int nc=0;

   for(int i=1; i<=InpEHL_Bars && i<iBars(_Symbol,PERIOD_M1); i++)
   {
      double lvl=(dir==ORDER_TYPE_SELL)?iLow(_Symbol,PERIOD_M1,i)
                                       :iHigh(_Symbol,PERIOD_M1,i);
      if(dir==ORDER_TYPE_SELL){ if(lvl>=entry||entry-lvl>max_dist) continue; }
      else                    { if(lvl<=entry||lvl-entry>max_dist) continue; }

      bool found=false;
      for(int j=0; j<nc; j++)
         if(MathAbs(cand[j]-lvl)<=InpEHL_Tol)
         { hits[j]++; cand[j]=(cand[j]*(hits[j]-1)+lvl)/hits[j]; found=true; break; }
      if(!found && nc<EHL_MAX){ cand[nc]=lvl; hits[nc]=1; nc++; }
   }

   double qual[EHL_MAX]; int nq=0;
   for(int i=0; i<nc; i++)
      if(hits[i]>=InpEHL_MinHits){ qual[nq]=cand[i]; nq++; }

   for(int i=0; i<nq-1; i++)
      for(int j=i+1; j<nq; j++)
      {
         double di=MathAbs(qual[i]-entry), dj=MathAbs(qual[j]-entry);
         if(dj<di){ double t=qual[i]; qual[i]=qual[j]; qual[j]=t; }
      }

   ArrayResize(levels,nq);
   for(int i=0; i<nq; i++) levels[i]=qual[i];
   return nq;
}

//===================================================================
// EXECUTE
//===================================================================
void Execute(ENUM_ORDER_TYPE type,int rows,int max_vol)
{
   // ── FUNDEDHIVE GATES -- checked before everything else ──────────────────
   if(InpFH_Enable)
   {
      if(g_fh_max_stopped)
      { if(InpLog) Print("  SKIP: [FH] MAX LOSS -- EA permanently stopped"); return; }
      if(g_fh_daily_stopped)
      { if(InpLog) Print("  SKIP: [FH] DAILY LIMIT -- no more trades today"); return; }
      if(g_fh_target_hit && InpFH_PauseOnTarget)
      { if(InpLog) Print("  SKIP: [FH] TARGET HIT -- phase complete, EA paused"); return; }
      if(InpFH_Cooldown > 0 && g_fh_last_trade_time > 0)
      {
         int secs_since = (int)(TimeCurrent() - g_fh_last_trade_time);
         if(secs_since < InpFH_Cooldown)
         { g_fh_cooldown_blocks++;
           if(InpLog) Print("  SKIP: [FH] COOLDOWN ",secs_since,"s < ",InpFH_Cooldown,"s");
           return; }
      }
      if(IsHighImpactNewsTime())
      { g_fh_news_blocks++;
        if(InpLog) Print("  SKIP: [FH] NEWS -- high impact event within ",InpFH_NewsBuffer," min");
        return; }
   }

   if(OpenPositions()>=InpMaxPos)
   { if(InpLog && !g_ghost_mode) Print("  SKIP: max positions"); return; }

   //-- Layer 1: Regime filter -- direction aligned with M15 trend
   bool is_sell = (type == ORDER_TYPE_SELL);
   if(InpRegime_Enable)
   {
      // RANGE(conv) suspension -- block ALL new entries when EMAs converged
      if(InpConv_Disable && StringFind(g_regime_str,"conv") >= 0)
      {
         g_conv_blocks++;
         if(InpLog)
            Print("  SKIP: RANGE(conv) trading suspended  gap converged",
                  "  blocks ",(is_sell?"SELL":"BUY"));
         return;
      }

      bool blocked = false;
      if(g_regime == REGIME_TREND_UP && is_sell)
      {
         // [I] Momentum override: 3+ bearish candles + price below EMA8
         // Real momentum is bearish -- allow SELL despite TREND UP regime
         if(g_mom_override_sell)
         {
            if(InpLog && !g_ghost_mode)
               Print("  [I] L1 override: SELL allowed in TREND UP (bear momentum)");
         }
         else
            blocked = true;
      }
      else if(g_regime == REGIME_TREND_DN && !is_sell)
      {
         // [I] Momentum override: 3+ bullish candles + price above EMA8
         // Real momentum is bullish -- allow BUY despite TREND DN regime
         if(g_mom_override_buy)
         {
            if(InpLog && !g_ghost_mode)
               Print("  [I] L1 override: BUY allowed in TREND DN (bull momentum)");
         }
         else
            blocked = true;
      }
      else if(g_regime == REGIME_BREAKOUT_UP && is_sell)
         blocked = true;
      else if(g_regime == REGIME_BREAKOUT_DN && !is_sell)
         blocked = true;
      // REGIME_RANGE (non-conv): both directions allowed

      if(blocked)
      {
         g_regime_blocks++;
         if(InpLog && !g_ghost_mode)
            Print("  SKIP: L1 regime=",g_regime_str,
                  " blocks ",(is_sell?"SELL":"BUY"));
         return;
      }
   }

   //-- [G] REGIME-AWARE DELTA FILTER ─────────────────────────────────────
   // Only fires in TREND regime when delta confirms the regime against the signal
   // Data-backed rule (3 sessions Apr 20-23):
   //   TREND_UP + SELL signal + positive delta  -> sellers losing, trend continues UP  -> skip SELL
   //   TREND_DN + BUY  signal + negative delta  -> buyers losing, trend continues DOWN -> skip BUY
   // RANGE / RANGE(conv) / BREAKOUT: NEVER blocked -- absorption lives in these regimes
   // InpDelta_Observe=true: logs verdict but does NOT block (safe data collection mode)
   if(InpDelta_Enable && MathAbs(g_bar_delta) >= InpDelta_Threshold)
   {
      bool trend_up_blocks_sell = (g_regime == REGIME_TREND_UP  && is_sell  && g_bar_delta > 0);
      bool trend_dn_blocks_buy  = (g_regime == REGIME_TREND_DN  && !is_sell && g_bar_delta < 0);
      bool delta_would_block    = trend_up_blocks_sell || trend_dn_blocks_buy;

      if(delta_would_block)
      {
         string delta_verdict = StringFormat("[G] delta=%+d %s in %s confirms trend against %s",
                                             g_bar_delta,
                                             g_bar_delta>0?"(BUY pressure)":"(SELL pressure)",
                                             g_regime_str,
                                             is_sell?"SELL":"BUY");
         if(InpDelta_Observe)
         {
            // Observe mode: log the verdict but let the trade through
            g_delta_observe++;
            if(InpLog)
               Print("  [G] OBSERVE (would block): ",delta_verdict);
         }
         else
         {
            // Live mode: actually block the entry
            g_delta_blocks++;
            if(InpLog)
               Print("  SKIP: ",delta_verdict);
            return;
         }
      }
      else if(InpLog && !g_ghost_mode && InpDelta_Observe)
      {
         // Log when delta aligns with signal (positive confirmation)
         bool delta_confirms = (!is_sell && g_bar_delta > 0) || (is_sell && g_bar_delta < 0);
         if(delta_confirms)
            Print("  [G] delta=",g_bar_delta > 0 ? StringFormat("+%d",g_bar_delta)
                                                  : IntegerToString(g_bar_delta),
                  " confirms signal in ",g_regime_str);
      }
   }

   // ── THREE-TIER SIGNAL CLASSIFICATION ───────────────────────────────────
   // Based on 4,573-signal analysis across all sessions:
   //   Ultra (vol>=20):          69% win rate -> size up to InpUltraLot
   //   Strong (vol>=InpStrongVol/InpStrongVol_Buy): 57-79% -> InpStrongLot
   //   Normal (vol 3-19):        59-60% -> InpLot
   //
   // BUY strong threshold is LOWER (9) than SELL (10) because:
   //   BUY vol 9-17 = 71-79% win rate vs SELL vol 10-17 = 57-64%
   //   Absorption at lows on gold shows stronger reversal signal
   int strong_threshold = is_sell ? InpStrongVol : InpStrongVol_Buy;
   bool ultra  = (max_vol >= InpUltraVol);
   bool strong = !ultra && (max_vol >= strong_threshold);
   bool normal = !ultra && !strong;

   double rr2    = (ultra||strong) ? InpStrongRR : NormalRR(rows);
   double max_sl = (ultra||strong) ? InpMaxSL_Strong : InpMaxSL;
   double buffer = CalcATRBuffer();

   if(ultra) g_ultra_signals++;

   // ── FH RISK-BASED LOT SIZING ────────────────────────────────────────────
   // Lot = (Balance x Risk%) ÷ (SL_pts x $10/pt)
   // SL not yet computed -- use fixed lots, recalculate after SL known (see below)
   // Fixed fallback used when FH disabled
   double lot = ultra ? InpUltraLot : strong ? InpStrongLot : InpLot;
   double used_balance = InpFH_Balance + g_fh_balance_adj;
   double risk_pct = InpFH_Enable
                     ? (ultra ? InpFH_Risk_Ultra : strong ? InpFH_Risk_Strong : InpFH_Risk_Normal)
                     : 0.0; // 0 = use fixed lots above

   // ── ZONE PURITY CHECK ──────────────────────────────────────────────────
   // Pure zone: ALL zone rows have one side = 0 (bid=0 for SELL, ask=0 for BUY)
   // Mixed zone: any zone row has BOTH bid>0 AND ask>0 (partial imbalance)
   // Data: pure=61% win rate, mixed=58% -> reduce lot on mixed zones
   // Currently scaling lot -- collecting data for future hard filter decision
   g_zone_pure = true;
   if(InpPurityFactor < 1.0)
   {
      for(int pi = 0; pi < rows; pi++)
      {
         double zone_bid = (is_sell ? g_bid[pi] : g_bid[g_count-1-pi]);
         double zone_ask = (is_sell ? g_ask[pi] : g_ask[g_count-1-pi]);
         if(zone_bid > 0 && zone_ask > 0)
         {
            g_zone_pure = false;
            break;
         }
      }
      if(!g_zone_pure)
      {
         lot = NormalizeDouble(lot * InpPurityFactor, 2);
         if(lot < 0.01) lot = 0.01;  // floor at 0.01
         g_purity_reduced++;
         if(InpLog && !g_ghost_mode)
            Print("  [PURITY] mixed zone detected -- lot reduced to ",
                  DoubleToString(lot,2),
                  " (factor=",InpPurityFactor,")");
      }
   }

   // Log signal tier
   if(InpLog && !g_ghost_mode)
   {
      string tier_str = ultra  ? "ULTRA"  :
                        strong ? "STRONG" : "normal";
      string pure_str = g_zone_pure ? " [pure zone]" : " [mixed zone]";
      Print("  Signal tier: ",tier_str,
            " vol=",max_vol," lot=",DoubleToString(lot,2),pure_str);
   }

   //-- [H] PRICE vs EMA8 CONFIRMATION ────────────────────────────────────
   // Prevents buying into downmoves and selling into upmoves caused by EMA lag
   // EMA8 on M1 lags 1-3 bars -- price can cross against regime before EMAs catch up
   // Only applies in TREND regime -- RANGE has no directional bias to confirm
   // Example: TREND UP + BUY signal but price already 2pts below EMA8 -> skip
   //          This means trend is reversing -- EMAs haven't caught up yet
   if(InpPriceConfirm && InpRegime_Enable && g_ema_fast_now > 0)
   {
      double cur_price = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      bool in_trend    = (g_regime == REGIME_TREND_UP || g_regime == REGIME_TREND_DN);

      if(in_trend)
      {
         // BUY in TREND UP: price must be above EMA8 (with buffer allowance)
         // If price already below EMA8 -> trend reversing -> skip
         bool price_below_ema = (!is_sell && cur_price < g_ema_fast_now - InpPriceConfirmBuffer);

         // SELL in TREND DN: price must be below EMA8 (with buffer allowance)
         // If price already above EMA8 -> trend reversing -> skip
         bool price_above_ema = (is_sell  && cur_price > g_ema_fast_now + InpPriceConfirmBuffer);

         if(price_below_ema || price_above_ema)
         {
            g_price_confirm_blocks++;
            if(InpLog && !g_ghost_mode)
               Print("  SKIP: [H] price=",DoubleToString(cur_price,2),
                     (price_below_ema ? " below EMA8=" : " above EMA8="),
                     DoubleToString(g_ema_fast_now,2),
                     " by ",DoubleToString(MathAbs(cur_price-g_ema_fast_now),2),"pts",
                     " in ",g_regime_str," -- trend reversing, EMA lagging");
            return;
         }
      }
   }

   //-- [J] STRUCTURE ENGINE -- location/context filter ────────────────────
   // Score = how many structure points favour this signal direction
   // InpStructMinScore=0 -> observe only (logs, never blocks)
   // InpStructMinScore>0 -> requires minimum structure quality
   if(InpStructEnable)
   {
      int score = is_sell ? g_struct_sell_score : g_struct_buy_score;

      if(InpLog && !g_ghost_mode)
      {
         string struct_detail = "";
         if(is_sell)
         {
            if(g_near_swing_high) struct_detail += " [SwingHigh+2]";
            if(g_sweep_up)        struct_detail += " [Sweep+3]";
         }
         else
         {
            if(g_near_swing_low)  struct_detail += " [SwingLow+2]";
            if(g_sweep_down)      struct_detail += " [Sweep+3]";
         }
         double pdist = SymbolInfoDouble(_Symbol,SYMBOL_BID) - g_poc_price;
         if(g_poc_price>0 && ((is_sell && pdist>5) || (!is_sell && pdist<-5)))
            struct_detail += " [POCext+1]";
         Print("  [J] score=",score,
               struct_detail=="" ? " (no structure)" : struct_detail,
               InpStructMinScore>0 ? StringFormat(" min=%d",InpStructMinScore) : " [OBSERVE]");
      }

      if(InpStructMinScore > 0 && score < InpStructMinScore)
      {
         g_struct_blocks++;
         if(InpLog)
            Print("  SKIP: [J] structure score=",score,
                  " < min=",InpStructMinScore," -- no meaningful structure");
         return;
      }
   }

   bool apply_vwap = InpVWAP_Filter&&(strong?InpVWAP_Strong:true);
   if(apply_vwap)
   {
      double vwap=CalcVWAP();
      if(vwap>0)
      {
         double a=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
         double b=SymbolInfoDouble(_Symbol,SYMBOL_BID);
         double vd=(type==ORDER_TYPE_BUY)?(a-vwap):(vwap-b);
         if(vd>InpVWAP_ExtDist)
         {
            if(InpLog) Print("  SKIP: VWAP extended ",DoubleToString(vd,2),"pts ",
                             (type==ORDER_TYPE_BUY?"above":"below"),
                             " VWAP=",DoubleToString(vwap,2));
            return;
         }
      }
   }

   double ask=SymbolInfoDouble(_Symbol,SYMBOL_ASK);
   double bid=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double entry,sl,tp1,tp2,sl_dist;
   string tp_src="RR";

   if(type==ORDER_TYPE_BUY)
   {
      entry=ask;

      // SL: zone-based, capped by ATR if zone is far
      double zdist=entry-g_imbalance_bot;
      double slc=g_imbalance_bot-buffer;
      if(zdist>5.0)
      {
         double asl=entry-CalcATR5()*1.5;
         slc=MathMax(slc,asl);
         if(InpLog && !g_ghost_mode) Print("  SL ATR-capped zone=",DoubleToString(zdist,1),"pts");
      }
      sl=NormalizeDouble(MathMin(slc,entry-InpMinSL),_Digits);

      if(InpZoneProtect)
      {
         double mb=(max_vol>=strong_threshold||ultra)?InpBreachStrong:(max_vol>=6)?InpBreachMid:0.0;
         double br=g_imbalance_bot-entry;
         if(br>mb)
         { if(InpLog && !g_ghost_mode) Print("  SKIP: below zone breach=",DoubleToString(br,2)); return; }
      }
      if(max_vol<=5)
      {
         double zd=entry-g_imbalance_bot;
         if(zd>InpMaxZoneDist)
         { if(InpLog && !g_ghost_mode) Print("  SKIP: too far from zone ",DoubleToString(zd,2),"pts"); return; }
      }

      sl_dist=entry-sl;

      double el[]; int ne=FindEqualLevels(ORDER_TYPE_BUY,entry,el,InpEHL_MaxDist);
      double ev[]; int nv=0; ArrayResize(ev,ne);
      for(int i=0;i<ne;i++) if(el[i]-entry>=sl_dist*InpEHL_MinRR) ev[nv++]=el[i];

      if(nv>=2)      { tp1=NormalizeDouble(ev[0],_Digits); tp2=NormalizeDouble(ev[1],_Digits); tp_src=StringFormat("EHL(%d->%d)",ne,nv); }
      else if(nv==1) { tp1=NormalizeDouble(ev[0],_Digits); tp2=NormalizeDouble(entry+sl_dist*rr2,_Digits); tp_src="EHL+RR"; }
      else           { tp1=NormalizeDouble(entry+sl_dist*InpTP1_R,_Digits); tp2=NormalizeDouble(entry+sl_dist*rr2,_Digits); if(ne>0)tp_src=StringFormat("RR(EHL<1R %d)",ne); }
   }
   else
   {
      entry=bid;

      double zdist=g_imbalance_top-entry;
      double slc=g_imbalance_top+buffer;
      if(zdist>5.0)
      {
         double asl=entry+CalcATR5()*1.5;
         slc=MathMin(slc,asl);
         if(InpLog && !g_ghost_mode) Print("  SL ATR-capped zone=",DoubleToString(zdist,1),"pts");
      }
      sl=NormalizeDouble(MathMax(slc,entry+InpMinSL),_Digits);

      if(InpZoneProtect)
      {
         double mb=(max_vol>=strong_threshold||ultra)?InpBreachStrong:(max_vol>=6)?InpBreachMid:0.0;
         double br=entry-g_imbalance_top;
         if(br>mb)
         { if(InpLog && !g_ghost_mode) Print("  SKIP: above zone breach=",DoubleToString(br,2)); return; }
      }
      if(max_vol<=5)
      {
         double zd=g_imbalance_top-entry;
         if(zd>InpMaxZoneDist)
         { if(InpLog && !g_ghost_mode) Print("  SKIP: too far from zone ",DoubleToString(zd,2),"pts"); return; }
      }

      sl_dist=sl-entry;

      double el[]; int ne=FindEqualLevels(ORDER_TYPE_SELL,entry,el,InpEHL_MaxDist);
      double ev[]; int nv=0; ArrayResize(ev,ne);
      for(int i=0;i<ne;i++) if(entry-el[i]>=sl_dist*InpEHL_MinRR) ev[nv++]=el[i];

      if(nv>=2)      { tp1=NormalizeDouble(ev[0],_Digits); tp2=NormalizeDouble(ev[1],_Digits); tp_src=StringFormat("EHL(%d->%d)",ne,nv); }
      else if(nv==1) { tp1=NormalizeDouble(ev[0],_Digits); tp2=NormalizeDouble(entry-sl_dist*rr2,_Digits); tp_src="EHL+RR"; }
      else           { tp1=NormalizeDouble(entry-sl_dist*InpTP1_R,_Digits); tp2=NormalizeDouble(entry-sl_dist*rr2,_Digits); if(ne>0)tp_src=StringFormat("RR(EHL<1R %d)",ne); }
   }

   // Gates
   if(sl_dist<InpMinSL)
   { if(InpLog && !g_ghost_mode) Print("  SKIP: SL<min ",DoubleToString(sl_dist,2),"pts"); return; }
   if(sl_dist>max_sl)
   { if(InpLog && !g_ghost_mode) Print("  SKIP: SL>max ",DoubleToString(sl_dist,2),"pts"); return; }

   // ── FH: Recalculate lot now that SL distance is known ───────────────────
   if(InpFH_Enable && risk_pct > 0 && sl_dist > 0)
   {
      double risk_usd = used_balance * risk_pct / 100.0;
      double calc_lot = NormalizeDouble(risk_usd / (sl_dist * 10.0), 2);
      if(calc_lot < 0.01) calc_lot = 0.01;
      lot = calc_lot;
      if(InpLog && !g_ghost_mode)
         Print("  [FH] Risk-based lot: ",DoubleToString(risk_usd,2),
               "$ (",InpFH_Risk_Normal,"/",InpFH_Risk_Strong,"/",InpFH_Risk_Ultra,
               "%) / SL=",DoubleToString(sl_dist,2),"pts -> lot=",DoubleToString(lot,2));
   }

   // ── FH: RR Minimum check (Rule 5) ───────────────────────────────────────
   // Normal >= 1.8R, Strong/Ultra >= 2.0R
   double tp1d = MathAbs(tp1 - entry);
   double rr1  = (sl_dist > 0) ? tp1d / sl_dist : 0;
   double fh_min_rr = (ultra || strong) ? 2.0 : 1.8;
   if(InpFH_Enable && rr1 < fh_min_rr)
   {
      g_fh_rr_blocks++;
      if(InpLog) Print("  SKIP: [FH] RR=",DoubleToString(rr1,2),"R < min=",
                       DoubleToString(fh_min_rr,1),"R for ",
                       (ultra?"ULTRA":strong?"STRONG":"normal")," signal");
      return;
   }
   if(rr1<1.0)
   { if(InpLog && !g_ghost_mode) Print("  SKIP: RR=",DoubleToString(rr1,2),"R TP1=",DoubleToString(tp1d,2),"pts SL=",DoubleToString(sl_dist,2),"pts | ",tp_src); return; }

   if(InpLog && !g_ghost_mode)
      Print("  SL zone=",DoubleToString(type==ORDER_TYPE_BUY?g_imbalance_bot:g_imbalance_top,2),
            " buf=",DoubleToString(buffer,2),
            " SL=",DoubleToString(sl,2),
            " risk=",DoubleToString(sl_dist,2),"pts");

   string comment=StringFormat("FP_%s_%s",(type==ORDER_TYPE_BUY?"BUY":"SELL"),(strong?"STRONG":"normal"));
   bool ok=(type==ORDER_TYPE_BUY)?Trade.Buy(lot,_Symbol,entry,sl,tp2,comment)
                                 :Trade.Sell(lot,_Symbol,entry,sl,tp2,comment);
   if(ok)
   {
      ulong ticket=Trade.ResultOrder();
      Print("ENTRY ",(type==ORDER_TYPE_BUY?"BUY":"SELL"),
            " [",(strong?"STRONG":"normal"),"]",
            " vol=",max_vol,
            " entry=",DoubleToString(entry,_Digits),
            " SL=",DoubleToString(sl,_Digits),
            " TP1=",DoubleToString(tp1,_Digits),
            " TP2=",DoubleToString(tp2,_Digits),
            " risk=",DoubleToString(sl_dist,2),"pts",
            " RR1=",DoubleToString(rr1,2),"R",
            " RR2=",DoubleToString(rr2,1),
            " TP=",tp_src);

      if(g_trade_cnt<10)
      {
         g_trades[g_trade_cnt].ticket    =ticket;
         g_trades[g_trade_cnt].open_time =TimeCurrent();
         g_trades[g_trade_cnt].open_price=entry;
         g_trades[g_trade_cnt].sl        =sl;
         g_trades[g_trade_cnt].tp1       =tp1;
         g_trades[g_trade_cnt].tp2       =tp2;
         g_trades[g_trade_cnt].tp1_hit   =false;
         g_trades[g_trade_cnt].is_strong =strong;
         g_trades[g_trade_cnt].type      =(type==ORDER_TYPE_BUY)?0:1;
         g_trade_cnt++;
      }
      g_fh_last_trade_time = TimeCurrent();  // [FH] cooldown timer
   }
   else Print("FAILED err=",GetLastError()," ret=",Trade.ResultRetcode());
}

double NormalRR(int rows)
{ if(rows>=3)return InpRR_3; if(rows==2)return InpRR_2; return InpRR_1; }

int OpenPositions()
{
   int cnt=0;
   for(int i=PositionsTotal()-1; i>=0; i--)
      if(PositionGetSymbol(i)==_Symbol &&
         PositionGetInteger(POSITION_MAGIC)==InpMagic) cnt++;
   return cnt;
}

//===================================================================
// DASHBOARD
//===================================================================
void PanelLabel(string name,string text,int x,int y,
                color clr,int fs=9,string font="Consolas")
{
   string f=PANEL_PFX+name;
   if(ObjectFind(0,f)<0)
   {
      ObjectCreate(0,f,OBJ_LABEL,0,0,0);
      ObjectSetInteger(0,f,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,f,OBJPROP_ANCHOR,ANCHOR_LEFT_UPPER);
      ObjectSetInteger(0,f,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,f,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,f,OBJPROP_BACK,false);
   }
   ObjectSetString (0,f,OBJPROP_TEXT,     text);
   ObjectSetInteger(0,f,OBJPROP_XDISTANCE,x);
   ObjectSetInteger(0,f,OBJPROP_YDISTANCE,y);
   ObjectSetInteger(0,f,OBJPROP_COLOR,    clr);
   ObjectSetInteger(0,f,OBJPROP_FONTSIZE, fs);
   ObjectSetString (0,f,OBJPROP_FONT,     font);
}

void PanelRect(string name,int x,int y,int w,int h,color clr,int border=0)
{
   string f=PANEL_PFX+name;
   if(ObjectFind(0,f)<0)
   {
      ObjectCreate(0,f,OBJ_RECTANGLE_LABEL,0,0,0);
      ObjectSetInteger(0,f,OBJPROP_CORNER,CORNER_LEFT_UPPER);
      ObjectSetInteger(0,f,OBJPROP_SELECTABLE,false);
      ObjectSetInteger(0,f,OBJPROP_HIDDEN,true);
      ObjectSetInteger(0,f,OBJPROP_BACK,true);
   }
   ObjectSetInteger(0,f,OBJPROP_XDISTANCE,  x);
   ObjectSetInteger(0,f,OBJPROP_YDISTANCE,  y);
   ObjectSetInteger(0,f,OBJPROP_XSIZE,      w);
   ObjectSetInteger(0,f,OBJPROP_YSIZE,      h);
   ObjectSetInteger(0,f,OBJPROP_BGCOLOR,    clr);
   ObjectSetInteger(0,f,OBJPROP_BORDER_TYPE,border);
   ObjectSetInteger(0,f,OBJPROP_COLOR,      clrDimGray);
}

void DeletePanel(){ ObjectsDeleteAll(0,PANEL_PFX); ChartRedraw(0); }

void DrawGhostLabel()
{
   // Tiny corner label -- only visible indicator that Ghost mode is on
   // Top-right corner, unobtrusive, reminds you EA is running silently
   string name = "FP_GHOST_LBL";
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,    CORNER_RIGHT_UPPER);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, 120);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, 4);
   ObjectSetString (0, name, OBJPROP_TEXT,      "* GHOST");
   ObjectSetString (0, name, OBJPROP_FONT,      "Arial");
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  8);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clrDimGray);
   ObjectSetInteger(0, name, OBJPROP_BACK,      false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   ChartRedraw(0);
}


void DrawPanel()
{
   int x=InpPanelX, y=InpPanelY, px=x+10, w=230, h=480;

   PanelRect("BG",      x,y,  w,h+28, C'20,20,30',BORDER_FLAT);
   PanelRect("TITLE_BG",x,y,  w,22,   C'40,40,60',BORDER_FLAT);
   PanelLabel("TITLE","Project Pravali  v5.5",px,y+4,clrWhite,9);

   PanelRect("DIV1",x+5,y+80, w-10,1,C'50,50,70');
   PanelRect("DIV2",x+5,y+138,w-10,1,C'50,50,70');
   PanelRect("DIV3",x+5,y+242,w-10,1,C'50,50,70');
   PanelRect("DIV4",x+5,y+306,w-10,1,C'50,50,70');
   PanelRect("DIV5",x+5,y+350,w-10,1,C'50,50,70');
   PanelRect("DIV6",x+5,y+388,w-10,1,C'50,50,70');
   PanelRect("DIV7",x+5,y+428,w-10,1,C'50,50,70');
   PanelRect("DIV8",x+5,y+468,w-10,1,C'50,50,70');

   PanelLabel("HDR1","SESSION P&L",  px,y+26, clrSilver,8);
   PanelLabel("HDR2","TRADE STATS",  px,y+76, clrSilver,8);
   PanelLabel("HDR3","OPEN POSITION",px,y+146,clrSilver,8);
   PanelLabel("HDR4","EXIT ENGINE",  px,y+250,clrSilver,8);
   PanelLabel("HDR5","SETTINGS",     px,y+314,clrSilver,8);
   PanelLabel("HDR6","FOOTPRINT",    px,y+358,clrSilver,8);
   PanelLabel("HDR7","LIQUIDITY",    px,y+396,clrSilver,8);
   PanelLabel("HDR8","REGIME",       px,y+476,clrSilver,8);

   UpdatePanel();
   ChartRedraw(0);
}

void UpdatePanel()
{
   if(!InpShowPanel) return;
   int x=InpPanelX,y=InpPanelY,px=x+10,px2=x+130;

   //── P&L ──────────────────────────────────────────────────────────
   double fl=0;
   for(int i=0;i<g_trade_cnt;i++)
      if(PositionSelectByTicket(g_trades[i].ticket))
         fl+=PositionGetDouble(POSITION_PROFIT);
   double tot=g_session_pnl+fl;
   string ps=(tot>=0?"+":"")+DoubleToString(tot,2)+" USD";
   string fs2=(fl>=0?"+":"")+DoubleToString(fl,2)+" USD";
   PanelLabel("PNL_LBL","Total PnL",px, y+42,clrSilver,9);
   PanelLabel("PNL_VAL",ps,         px2,y+42,(tot>=0?clrLime:clrTomato),10);
   PanelLabel("FPL_LBL","Floating", px, y+56,clrSilver,9);
   PanelLabel("FPL_VAL",fs2,        px2,y+56,(fl>=0?clrAqua:clrOrange),9);
   double sp=SymbolInfoDouble(_Symbol,SYMBOL_ASK)-SymbolInfoDouble(_Symbol,SYMBOL_BID);
   color sc=(sp<=0.3)?clrLime:(sp<=0.6)?clrYellow:clrTomato;
   PanelLabel("SP_LBL","Spread",    px, y+68,clrSilver,9);
   PanelLabel("SP_VAL",DoubleToString(sp,2)+"pts",px2,y+68,sc,9);

   //── TRADE STATS ──────────────────────────────────────────────────
   double wr=(g_total_trades>0)?(double)g_wins/g_total_trades*100:0;
   double pf=(g_gross_loss>0)?g_gross_profit/g_gross_loss:0;
   PanelLabel("WT_LBL","Trades",       px, y+92, clrSilver,9);
   PanelLabel("WT_VAL",IntegerToString(g_total_trades),px2,y+92,clrWhite,9);
   PanelLabel("WW_LBL","Wins / Loss",  px, y+106,clrSilver,9);
   PanelLabel("WW_VAL",IntegerToString(g_wins)+" / "+IntegerToString(g_losses),px2,y+106,clrWhite,9);
   PanelLabel("WR_LBL","Win Rate",     px, y+120,clrSilver,9);
   PanelLabel("WR_VAL",DoubleToString(wr,1)+"%",px2,y+120,(wr>=50?clrLime:clrTomato),10);
   PanelLabel("PF_LBL","Profit Factor",px, y+134,clrSilver,9);
   PanelLabel("PF_VAL",(g_gross_loss>0)?DoubleToString(pf,2):"--",px2,y+134,clrWhite,9);

   //── OPEN POSITION ─────────────────────────────────────────────────
   if(OpenPositions()>0 && g_trade_cnt>0)
   {
      for(int i=0;i<g_trade_cnt;i++)
      {
         if(!PositionSelectByTicket(g_trades[i].ticket)) continue;
         double cur=PositionGetDouble(POSITION_PRICE_CURRENT);
         double prf=PositionGetDouble(POSITION_PROFIT);
         double op =g_trades[i].open_price;
         bool   ib =(g_trades[i].type==0);
         double mv =ib?cur-op:op-cur;
         int    mn =(int)((TimeCurrent()-g_trades[i].open_time)/60);
         string stg=g_trades[i].tp1_hit?"->TP2(trail)":"->TP1";
         string thesis=mv>0?"In profit":(mv<-InpThesisMinLoss?"THESIS CHECK":"Watching");
         color  tc  =mv>0?clrLime:(mv<-InpThesisMinLoss?clrOrange:clrSilver);

         PanelLabel("OP_DIR",(ib?"BUY":"SELL"),px,y+162,(ib?clrLime:clrTomato),10);
         PanelLabel("OP_STG",stg,              px2,y+162,clrSilver,9);
         PanelLabel("OP_E_L","Entry",          px, y+176,clrSilver,9);
         PanelLabel("OP_E_V",DoubleToString(op,2),px2,y+176,clrWhite,9);
         PanelLabel("OP_S_L","SL",             px, y+190,clrSilver,9);
         PanelLabel("OP_S_V",DoubleToString(g_trades[i].sl,2),px2,y+190,clrTomato,9);
         PanelLabel("OP_T_L","TP"+(g_trades[i].tp1_hit?"2":"1"),px,y+204,clrSilver,9);
         PanelLabel("OP_T_V",DoubleToString(g_trades[i].tp1_hit?g_trades[i].tp2:g_trades[i].tp1,2),px2,y+204,clrAqua,9);
         PanelLabel("OP_P_L","P&L",            px, y+218,clrSilver,9);
         PanelLabel("OP_P_V",(prf>=0?"+":"")+DoubleToString(prf,2)+" ("+IntegerToString(mn)+"m)",px2,y+218,(prf>=0?clrLime:clrTomato),9);
         PanelLabel("OP_TH", thesis,           px, y+232,tc,9);
         break;
      }
   }
   else
   {
      PanelLabel("OP_DIR","No open trade",px,y+162,clrDimGray,9);
      PanelLabel("OP_STG","",            px2,y+162,clrDimGray,9);
      PanelLabel("OP_E_L","Last signal:",px, y+176,clrSilver, 9);
      PanelLabel("OP_E_V",g_last_signal, px, y+190,clrYellow, 9);
      PanelLabel("OP_S_L","",            px, y+204,clrSilver, 9);
      PanelLabel("OP_S_V","",            px2,y+204,clrSilver, 9);
      PanelLabel("OP_T_L","",            px, y+218,clrSilver, 9);
      PanelLabel("OP_T_V","",            px2,y+218,clrSilver, 9);
      PanelLabel("OP_P_L","",            px, y+232,clrSilver, 9);
      PanelLabel("OP_P_V","",            px2,y+232,clrSilver, 9);
      PanelLabel("OP_TH", "",            px, y+244,clrSilver, 9);
   }

   //── EXIT ENGINE STATS ─────────────────────────────────────────────
   PanelLabel("EX1_L","[B] TP1 approach", px, y+264,clrSilver,9);
   PanelLabel("EX1_V",IntegerToString(g_tp1_closes),px2,y+264,(g_tp1_closes>0?clrLime:clrDimGray),9);
   PanelLabel("EX2_L","[B] TP2 approach", px, y+276,clrSilver,9);
   PanelLabel("EX2_V",IntegerToString(g_approach_exits),px2,y+276,(g_approach_exits>0?clrLime:clrDimGray),9);
   PanelLabel("EX3_L","[C] Trail stops",  px, y+288,clrSilver,9);
   PanelLabel("EX3_V","(broker SL)",      px2,y+288,clrDimGray,9);
   PanelLabel("EX4_L","[D] Decay exits",  px, y+300,clrSilver,9);
   PanelLabel("EX4_V",IntegerToString(g_momentum_exits),px2,y+300,(g_momentum_exits>0?clrAqua:clrDimGray),9);
   PanelLabel("EX5_L","[E] Thesis exits", px, y+312,clrSilver,9);
   PanelLabel("EX5_V",IntegerToString(g_thesis_exits),  px2,y+312,(g_thesis_exits>0?clrOrange:clrDimGray),9);
   PanelLabel("EX6_L","[F] Counter-sig",  px, y+324,clrSilver,9);
   PanelLabel("EX6_V",IntegerToString(g_counter_exits), px2,y+324,(g_counter_exits>0?clrMagenta:clrDimGray),9);
   PanelLabel("EX7_L","Timeouts",         px, y+336,clrSilver,9);
   PanelLabel("EX7_V",IntegerToString(g_timeouts),      px2,y+336,(g_timeouts>0?clrYellow:clrDimGray),9);

   //── SETTINGS ─────────────────────────────────────────────────────
   PanelLabel("ST1_L","Lot (N/S)",     px, y+364,clrSilver,9);
   PanelLabel("ST1_V",DoubleToString(InpLot,2)+" / "+DoubleToString(InpStrongLot,2),px2,y+364,clrWhite,9);
   PanelLabel("ST2_L","MaxSL (N/S)",   px, y+376,clrSilver,9);
   PanelLabel("ST2_V",DoubleToString(InpMaxSL,1)+" / "+DoubleToString(InpMaxSL_Strong,1)+"pts",px2,y+376,clrWhite,9);
   PanelLabel("ST3_L","Decay | Trail", px, y+388,clrSilver,9);
   PanelLabel("ST3_V",DoubleToString(InpDecayRatio,2)+" | "+IntegerToString(InpTrailBars)+"bars",px2,y+388,clrWhite,9);

   //── FOOTPRINT ────────────────────────────────────────────────────
   // g_fp_stale_bars = bars since FP_READY last changed (0=just updated)
   bool   fok = (g_fp_stale_bars < 3);
   string fs3 = fok ? "LIVE (stale="+IntegerToString(g_fp_stale_bars)+")"
                    : "STALE ("+IntegerToString(g_fp_stale_bars)+"bars)";
   PanelLabel("FP_L","ClusterDelta",px, y+402,clrSilver,9);
   PanelLabel("FP_V",fs3,          px2,y+402,(fok?clrLime:clrTomato),9);
   int sm=(int)((TimeCurrent()-g_session_start)/60);
   PanelLabel("SE_L","Session",    px, y+416,clrSilver,9);
   PanelLabel("SE_V",IntegerToString(sm)+"min | "+IntegerToString(g_total_trades)+" trades",px2,y+416,clrSilver,9);

   //── LIQUIDITY ────────────────────────────────────────────────────
   double vwap=CalcVWAP();
   double pn=SymbolInfoDouble(_Symbol,SYMBOL_BID);
   double vd=pn-vwap;
   bool bb=InpVWAP_Filter&&vd>InpVWAP_ExtDist;
   bool sb=InpVWAP_Filter&&vd<-InpVWAP_ExtDist;
   string vs=DoubleToString(vwap,2)+(vd>=0?" +":"  ")+DoubleToString(vd,2)+"pts";
   string vf=!InpVWAP_Filter?"OFF":bb?"BUY blocked":sb?"SELL blocked":"OK";
   color  vc=(MathAbs(vd)<=InpVWAP_ExtDist)?clrLime:(vd>0?clrTomato:clrOrange);
   // Show whether using FP VWAP or fallback tick VWAP
   string vwap_src = (g_fp_vwap > 0) ? "FP VWAP [CD]" : "VWAP (tick)";

   double eu[],ed[];
   int nu=FindEqualLevels(ORDER_TYPE_BUY, pn,eu,InpEHL_MaxDist);
   int nd=FindEqualLevels(ORDER_TYPE_SELL,pn,ed,InpEHL_MaxDist);
   string us=(nu>0)?DoubleToString(eu[0],2)+" (+"+DoubleToString(eu[0]-pn,1)+")":"none";
   string ds=(nd>0)?DoubleToString(ed[0],2)+" (-"+DoubleToString(pn-ed[0],1)+")":"none";

   PanelLabel("VW_L",vwap_src,  px, y+432,clrSilver,9);
   PanelLabel("VW_V",vs,        px2,y+432,vc,9);
   PanelLabel("VF_L","Filter",  px, y+444,clrSilver,9);
   PanelLabel("VF_V",vf,        px2,y+444,(InpVWAP_Filter?clrAqua:clrGray),9);
   PanelLabel("EU_L","EHL abv", px, y+456,clrSilver,9);
   PanelLabel("EU_V",us,        px2,y+456,clrAqua,  9);
   PanelLabel("ED_L","EHL blw", px, y+468,clrSilver,9);
   PanelLabel("ED_V",ds,        px2,y+468,clrOrange, 9);

   //── VOLUME PROFILE -- POC / VAH / VAL ─────────────────────────────
   // Observation only -- not yet used for trade logic
   // Colour logic:
   //   POC: white (neutral reference)
   //   VAH: tomato (price at/above VAH = overbought zone -> SELL bias)
   //   VAL: lime   (price at/below VAL = oversold zone  -> BUY  bias)
   //   If POC still building (<10 bars): grey
   bool poc_ready = (g_poc_price > 0 && g_poc_bars >= 10);
   color poc_col  = poc_ready ? clrWhite   : clrDimGray;
   color vah_col  = poc_ready ? clrTomato  : clrDimGray;
   color val_col  = poc_ready ? clrLime    : clrDimGray;

   string poc_val_str = poc_ready
                        ? DoubleToString(g_poc_price,2)
                          +" ("+DoubleToString(pn-g_poc_price,1)+"pts)"
                        : "building ("+IntegerToString(g_poc_bars)+"bars)";
   string vah_val_str = poc_ready
                        ? DoubleToString(g_vah_price,2)
                          +" (+"+DoubleToString(g_vah_price-pn,1)+"pts)"
                        : "--";
   string val_val_str = poc_ready
                        ? DoubleToString(g_val_price,2)
                          +" (-"+DoubleToString(pn-g_val_price,1)+"pts)"
                        : "--";

   PanelLabel("PC_L","POC",     px, y+480,clrSilver,9);
   PanelLabel("PC_V",poc_val_str,px2,y+480,poc_col, 9);
   PanelLabel("PH_L","VAH",     px, y+492,clrSilver,9);
   PanelLabel("PH_V",vah_val_str,px2,y+492,vah_col, 9);
   PanelLabel("PL_L","VAL",     px, y+504,clrSilver,9);
   PanelLabel("PL_V",val_val_str,px2,y+504,val_col, 9);

   //-- REGIME (Layer 1) -------------------------------------------- --------------------------------------------
   color rc;
   if(!InpRegime_Enable)                      rc = clrGray;
   else if(g_regime==REGIME_TREND_UP)         rc = clrLime;
   else if(g_regime==REGIME_TREND_DN)         rc = clrTomato;
   else if(g_regime==REGIME_RANGE)            rc = clrYellow;
   else if(g_regime==REGIME_BREAKOUT_UP)      rc = clrAqua;
   else                                       rc = clrOrange;
   // RANGE(conv) override -- distinct magenta so it's unmissable
   if(StringFind(g_regime_str,"conv") >= 0)   rc = clrMagenta;

   string regime_display = InpRegime_Enable ? g_regime_str : "DISABLED";
   string blocks_str     = "L1 blk="+IntegerToString(g_regime_blocks);
   string conv_blk_str   = "conv blk="+IntegerToString(g_conv_blocks);

   PanelLabel("RG_L","L1 Regime",    px, y+528,clrSilver,9);
   PanelLabel("RG_V",regime_display,  px2,y+528,rc,10);
   PanelLabel("RB_L","L1 Blocks",    px, y+540,clrSilver,9);
   PanelLabel("RB_V",blocks_str,      px2,y+540,(g_regime_blocks>0?clrOrange:clrDimGray),9);
   PanelLabel("CV_L","Conv Block",   px, y+552,clrSilver,9);
   PanelLabel("CV_V",conv_blk_str,    px2,y+552,(g_conv_blocks>0?clrMagenta:clrDimGray),9);

   // [G] Regime-Aware Delta Filter
   string dg_label = InpDelta_Observe ? "[G] Delta obs" : "[G] Delta blk";
   string dg_val   = InpDelta_Observe
                     ? IntegerToString(g_delta_observe)+" obs"
                     : IntegerToString(g_delta_blocks)+" blk";
   color  dg_col   = InpDelta_Observe
                     ? (g_delta_observe>0 ? clrAqua    : clrDimGray)
                     : (g_delta_blocks>0  ? clrTomato  : clrDimGray);
   PanelLabel("DG_L",dg_label,       px, y+564,clrSilver,9);
   PanelLabel("DG_V",dg_val,         px2,y+564,dg_col,9);

   // [H] Price vs EMA Confirmation
   string dh_val = InpPriceConfirm
                   ? IntegerToString(g_price_confirm_blocks)+" blk"
                   : "OFF";
   color  dh_col = InpPriceConfirm
                   ? (g_price_confirm_blocks>0 ? clrYellow : clrDimGray)
                   : clrGray;
   PanelLabel("DH_L","[H] Price/EMA", px, y+576,clrSilver,9);
   PanelLabel("DH_V",dh_val,          px2,y+576,dh_col,  9);

   // [I] Momentum Override
   string di_val = InpMomOverride
                   ? IntegerToString(g_mom_override_count)+" overrides"
                   : "OFF";
   color  di_col = InpMomOverride
                   ? (g_mom_override_count>0 ? clrAqua : clrDimGray)
                   : clrGray;
   // Show current state
   string di_state = "";
   if(g_mom_override_sell) di_state = " [SELL-]";
   else if(g_mom_override_buy) di_state = " [BUY+]";
   PanelLabel("DI_L","[I] Mom Ovrd",  px, y+588,clrSilver,9);
   PanelLabel("DI_V",di_val+di_state, px2,y+588,di_col,  9);

   // [J] Structure Engine
   string sell_struct = (g_near_swing_high ? "SH" : "") +
                        (g_sweep_up        ? "+SW" : "");
   string buy_struct  = (g_near_swing_low  ? "SL" : "") +
                        (g_sweep_down      ? "+SW" : "");
   string dj_val = InpStructEnable
                   ? StringFormat("S:%d B:%d%s blk=%d",
                                  g_struct_sell_score, g_struct_buy_score,
                                  (sell_struct!=""||buy_struct!="") ?
                                  " ["+sell_struct+(sell_struct!=""&&buy_struct!="?" ? "|" : "")+buy_struct+"]" : "",
                                  g_struct_blocks)
                   : "OFF";
   color dj_col = !InpStructEnable ? clrGray
                  : (g_sweep_up || g_sweep_down)        ? clrMagenta
                  : (g_near_swing_high || g_near_swing_low) ? clrAqua
                  : clrDimGray;
   PanelLabel("DJ_L","[J] Structure", px, y+600,clrSilver,9);
   PanelLabel("DJ_V",dj_val,          px2,y+600,dj_col,  9);

   // Ultra signals + zone purity stats
   string ultra_str = "ultra="+IntegerToString(g_ultra_signals)+
                      "  purity_red="+IntegerToString(g_purity_reduced);
   color ultra_col  = (g_ultra_signals>0) ? clrMagenta : clrDimGray;
   PanelLabel("UL_L","Ultra/Purity",  px, y+612,clrSilver,9);
   PanelLabel("UL_V",ultra_str,       px2,y+612,ultra_col,9);

   if(InpFH_Enable)
   {
      double used_bal  = InpFH_Balance + g_fh_balance_adj;
      double daily_lim = used_bal * InpFH_DailyLimit / 100.0;
      double max_lim   = used_bal * InpFH_MaxLoss    / 100.0;
      double target_usd  = used_bal * FH_Target()      / 100.0;
      double daily_pct = (daily_lim>0) ? g_fh_daily_pnl/daily_lim*100.0 : 0;
      double total_pct = (used_bal>0)  ? g_fh_total_pnl/used_bal*100.0  : 0;

      // Status color
      color fh_status_col = g_fh_max_stopped   ? clrRed    :
                            g_fh_daily_stopped  ? clrOrange :
                            g_fh_target_hit     ? clrLime   : clrAqua;
      string fh_status = g_fh_max_stopped  ? "*** MAX LOSS -- STOPPED ***" :
                         g_fh_daily_stopped ? "!!! DAILY LIMIT HIT !!!"  :
                         g_fh_target_hit    ? ">>> TARGET REACHED <<<"    : "SAFE";

      // Daily P&L color
      color dpnl_col = g_fh_daily_pnl >= 0 ? clrLime :
                       (-g_fh_daily_pnl > daily_lim*0.75) ? clrRed : clrOrange;
      // Total P&L color
      color tpnl_col = g_fh_total_pnl >= 0 ? clrLime :
                       (-g_fh_total_pnl > max_lim*0.75)   ? clrRed : clrOrange;

      string dpnl_str = StringFormat("%+.2f$ (%+.1f%% / -%.1f%%)",
                                     g_fh_daily_pnl, daily_pct, InpFH_DailyLimit);
      string tpnl_str = StringFormat("%+.2f$ (%+.2f%% / %.1f%%)",
                                     g_fh_total_pnl, total_pct, FH_Target());
      string bal_str  = StringFormat("%.0f$ (adj%+.0f)", used_bal, g_fh_balance_adj);
      string cd_str   = (g_fh_last_trade_time>0)
                        ? StringFormat("%ds cd | news=%d | rr=%d",
                                       (int)(TimeCurrent()-g_fh_last_trade_time),
                                       g_fh_news_blocks, g_fh_rr_blocks)
                        : "no trade yet";

      PanelLabel("FH_SEP","-- FUNDEDHIVE ---------",px,y+626,clrGray,8);
      PanelLabel("FH_ST_L","Status",        px, y+638,clrSilver,9);
      PanelLabel("FH_ST_V",fh_status,       px2,y+638,fh_status_col,9);
      PanelLabel("FH_BAL_L","Balance",      px, y+650,clrSilver,9);
      PanelLabel("FH_BAL_V",bal_str,        px2,y+650,clrWhite,9);
      PanelLabel("FH_DAY_L","Day P&L",      px, y+662,clrSilver,9);
      PanelLabel("FH_DAY_V",dpnl_str,       px2,y+662,dpnl_col,9);
      PanelLabel("FH_TOT_L","Total P&L",    px, y+674,clrSilver,9);
      PanelLabel("FH_TOT_V",tpnl_str,       px2,y+674,tpnl_col,9);
      PanelLabel("FH_TGT_L","Target",       px, y+686,clrSilver,9);
      PanelLabel("FH_TGT_V",StringFormat("Phase%d: %.0f$ (%.1f%%)",
                             InpFH_Phase,target_usd,FH_Target()),px2,y+686,clrYellow,9);
      PanelLabel("FH_CD_L","Cooldown/News", px, y+698,clrSilver,9);
      PanelLabel("FH_CD_V",cd_str,          px2,y+698,clrDimGray,9);

      // +/- Balance adjustment buttons
      if(ObjectFind(0,"FH_BTN_PLUS")<0)
      {
         ObjectCreate(0,"FH_BTN_PLUS",OBJ_BUTTON,0,0,0);
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_XDISTANCE,px2+90);
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_YDISTANCE,InpPanelY+y+650);
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_XSIZE,22);
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_YSIZE,14);
         ObjectSetString(0,"FH_BTN_PLUS",OBJPROP_TEXT,"+");
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_COLOR,clrWhite);
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_BGCOLOR,clrGreen);
         ObjectSetInteger(0,"FH_BTN_PLUS",OBJPROP_FONTSIZE,8);
      }
      if(ObjectFind(0,"FH_BTN_MINUS")<0)
      {
         ObjectCreate(0,"FH_BTN_MINUS",OBJ_BUTTON,0,0,0);
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_XDISTANCE,px2+114);
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_YDISTANCE,InpPanelY+y+650);
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_XSIZE,22);
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_YSIZE,14);
         ObjectSetString(0,"FH_BTN_MINUS",OBJPROP_TEXT,"-");
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_COLOR,clrWhite);
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_BGCOLOR,clrCrimson);
         ObjectSetInteger(0,"FH_BTN_MINUS",OBJPROP_FONTSIZE,8);
      }
   }

   ChartRedraw(0);
}
//+------------------------------------------------------------------+
