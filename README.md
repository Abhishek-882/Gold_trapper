# Gold Trapper (GT Prediction Advance v2.0)

Automated Expert Advisor for MetaTrader 5 trading **XAUUSD (Gold)** with multi-timeframe directional prediction, macro trend filters, support/resistance clustering, 24-hour range boundary protection, and Level 1 trend-running trailing stops.

## Repository Structure

- `GT Prediction Advance v2.0.mq5`: Complete source code for the EA (MQL5), updated with seamless Level 1 Trend-Runner trailing execution.
- `GT Prediction Advance v2.0.ex5`: Compiled binary, verified with 0 errors and 0 warnings on MetaEditor 64.
- `gold trapper v 2.0.set`: Baseline original configuration preset.
- `gold trapper v 2.0 - recommended.set`: High-conviction recommended preset matching optimal risk parameters:
  - **MacroCounterTrendMode**: `1 (Disable Counter-Trend)`
  - **PredictionTimeframe**: `15 (PERIOD_M15)`
  - **EnableSRFilter**: `true (H1, 15 pips)`
  - **EnableFridayBasketRule**: `true (Level 8+, 20:00)`
  - **InitialTPPips**: `35.0 (.50) + Trail`
- `news.csv`: High-impact economic news events calendar for offline & live news filtering.
- `TREND_FILTERS_AND_ENTRY_SIGNAL_REPORT.md`: In-depth technical architecture report covering all trend filters and entry signal generation pipelines.

## Installation & Setup

1. Copy `GT Prediction Advance v2.0.ex5` (or `.mq5`) into your MT5 `MQL5\Experts\` folder.
2. Copy `news.csv` into your MT5 `MQL5\Files\` folder.
3. Attach the EA to an **XAUUSD** chart (M1 or M15 timeframe).
4. In the EA input parameters dialog, click **Load** and select `gold trapper v 2.0 - recommended.set`.
5. Ensure **Algo Trading** is enabled in MT5.