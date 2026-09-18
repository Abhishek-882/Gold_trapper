# Gold Trapper (GT Prediction Advance v2.0)

Automated Expert Advisor for MetaTrader 5 trading **XAUUSD (Gold)** with multi-timeframe directional prediction, macro trend filters, support/resistance clustering, 24-hour range boundary protection, Level 1 trend-running trailing stops, and built-in offline news protection.

## Key Highlights

- **Zero External File Dependency**: All 93 high-impact news events across 2026 (FOMC, NFP, CPI, PCE, GDP, PPI, ISM PMI, Fed Speeches, Jackson Hole) and 12 high-risk trading dates are built directly into the EA binary (g_HardcodedNews[] & skipDates[]). The news filter operates out-of-the-box in Strategy Tester and Live charts without requiring 
ews.csv in MQL5/Files.
- **Level 1 Trend-Runner Trailing Execution**: Resolves premature broker TP conflicts; captures 35-pip initial profit, closes 50% partial volume, moves SL to Breakeven (+5 pips buffer), and trails extended trend runners.
- **Institutional Risk Preset**: Optimized preset reduces peak drawdown from \.5k down to < \ by disabling counter-trend cycles against the H4 200 EMA.

## Repository Structure

- `GT Prediction Advance v2.0.mq5`: Complete source code for the EA (MQL5) with embedded news events, skip dates, and enhanced runner trailing logic.
- `GT Prediction Advance v2.0.ex5`: Compiled binary, verified with 0 errors and 0 warnings on MetaEditor 64.
- `gold trapper v 2.0.set`: Baseline configuration preset.
- `gold trapper v 2.0 - recommended.set`: High-conviction recommended preset matching optimal risk parameters:
  - **MacroCounterTrendMode**: `1 (Disable Counter-Trend)`
  - **PredictionTimeframe**: `15 (PERIOD_M15)`
  - **EnableSRFilter**: `true (H1, 15 pips)`
  - **EnableFridayBasketRule**: `true (Level 8+, 20:00)`
  - **InitialTPPips**: `35.0 (.50) + Trail`
  - **InpPreferHardcodedNews**: `true` (built-in news calendar active)
- `news.csv`: High-impact economic news events calendar (optional, for custom external file overrides).
- `TREND_FILTERS_AND_ENTRY_SIGNAL_REPORT.md`: In-depth technical architecture report covering all trend filters, entry signal generation pipelines, and news filter mechanics.

## Installation & Setup

1. Copy `GT Prediction Advance v2.0.ex5` into your MT5 `MQL5\Experts\` folder.
2. Attach the EA to an **XAUUSD** chart (M1 or M15 timeframe).
3. In the EA input parameters dialog, click **Load** and select `gold trapper v 2.0 - recommended.set`.
4. Ensure **Algo Trading** is enabled in MT5.
5. *(Optional)* If you wish to use a custom news file, place `news.csv` in `MQL5\Files\` and set `InpPreferHardcodedNews = false`.