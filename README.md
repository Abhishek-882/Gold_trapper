# Gold Trapper (GT Prediction Advance v2.0)

Automated Expert Advisor for MetaTrader 5 trading **XAUUSD (Gold)** with multi-timeframe directional prediction, macro trend filters, support/resistance clustering, 24-hour range boundary protection, Level 1 trend-running trailing stops, and built-in offline news protection.

## Key Highlights

- **Zero External File Dependency**: All 93 high-impact news events across 2026 (FOMC, NFP, CPI, PCE, GDP, PPI, ISM PMI, Fed Speeches, Jackson Hole) and 12 high-risk trading dates are built directly into the EA binary (g_HardcodedNews[] & skipDates[]). The news filter operates out-of-the-box in Strategy Tester and Live charts without requiring 
ews.csv in MQL5/Files.
- **Level 1 Trend-Runner Trailing Execution**: Resolves premature broker TP conflicts; captures 35-pip initial profit, closes 50% partial volume, moves SL to Breakeven (+5 pips buffer), and trails extended trend runners.
- **Institutional Risk Preset**: Optimized preset reduces peak drawdown from \.5k down to < \ by disabling counter-trend cycles against the H4 200 EMA.

## Repository Structure

- `GT Prediction BB Alert v3.0.mq5` & `GT Prediction BB Alert v3.0.ex5`: **NEW v3.0 Release**. Uses confirmed closed-bar arrows from `BB_Alert Arrows_` (centering swing extreme) as the sole main entry signal, with legacy indicator filters disabled. 100% embedded calculation (no external indicator file needed).
- `gold trapper v 3.0 - bb alert.set`: Dedicated preset for v3.0 (`EnableBBAlertSignal = true`, `InpBBSignalBar = 1`, all legacy indicators = `false`, with 2026 hardcoded news and skip dates retained).
- `GT Prediction Advance v2.0.mq5` & `GT Prediction Advance v2.0.ex5`: Complete source code and compiled binary for v2.0 EA with embedded news events, skip dates, and enhanced runner trailing logic.
- `gold trapper v 2.0.set`: Baseline configuration preset.
- `gold trapper v 2.0 - recommended.set`: High-conviction recommended preset matching optimal risk parameters:
  - **MacroCounterTrendMode**: `1 (Disable Counter-Trend)`
  - **PredictionTimeframe**: `15 (PERIOD_M15)`
  - **EnableSRFilter**: `true (H1, 15 pips)`
  - **EnableFridayBasketRule**: `true (Level 8+, 20:00)`
  - **InitialTPPips**: `35.0 ($3.50) + Trail`
  - **InpPreferHardcodedNews**: `true` (built-in news calendar active)
- `news.csv`: High-impact economic news events calendar (optional, for custom external file overrides).
- `TREND_FILTERS_AND_ENTRY_SIGNAL_REPORT.md`: In-depth technical architecture report covering all trend filters, entry signal generation pipelines, and news filter mechanics.

## Installation & Setup

### For v3.0 (BB Alert Main Entry):
1. Copy `GT Prediction BB Alert v3.0.ex5` into your MT5 `MQL5\Experts\` folder.
2. Attach the EA to an **XAUUSD** chart (M1, M5, or M15).
3. In the Inputs tab, click **Load** and select `gold trapper v 3.0 - bb alert.set`.
4. Ensure **Algo Trading** is enabled in MT5.

### For v2.0 (Multi-Filter Prediction):
1. Copy `GT Prediction Advance v2.0.ex5` into your MT5 `MQL5\Experts\` folder.
2. Attach the EA to an **XAUUSD** chart (M1 or M15).
3. In the Inputs tab, click **Load** and select `gold trapper v 2.0 - recommended.set`.
4. Ensure **Algo Trading** is enabled in MT5.