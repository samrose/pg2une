# Prophet Anomaly Detection — Design

**Date:** 2026-03-07
**Branch:** tests-and-analyzer

## Problem

Prophet runs every 30 minutes and produces forecasts, but contributes nothing to the
decision pipeline due to two bugs:

1. **Wrong predicate name.** `run_prophet` asserts `{:prophet_forecast, [...]}` but
   `recalculate_confidence` queries `{:seasonal_expected, [...]}`. These never match.
   `seasonal_unexpected` is always `false`.

2. **No comparison.** Even if the predicate matched, the code stores a future forecast
   but never compares it against the current actual value. Anomaly detection requires
   checking whether the actual falls inside the model's predicted interval.

## Approach: Elixir-only fix

Use what `Anytune.forecast/3` already returns. The first entry in `result["forecast"]`
is the next 15-minute period — close enough to "now" to serve as the expected range.

## Changes

### `lib/pg2une/periodic_analyzer.ex`

**In `run_prophet/0`:** after getting the forecast, pull the latest actual via
`MetricsStore.recent_system_metrics(1)`. Compare the actual metric value against
`[yhat_lower, yhat_upper]` of the first forecast entry.

- If actual is outside the interval → assert `{:prophet_anomaly, [metric]}`
- If actual is inside → retract any existing `{:prophet_anomaly, [metric]}` fact

Continue asserting `prophet_forecast` facts (used by `/api/analysis`).

**In `recalculate_confidence/1`:** replace the `seasonal_expected` query with a direct
query for `{:prophet_anomaly, [:_]}` from the fact store.
`seasonal_unexpected = anomaly_facts != []`

### `priv/rules/pg2une.dl`

Add one derived rule so Prophet anomalies are visible in Datalog queries:

```datalog
% Prophet anomaly signal — metric outside its predicted interval
prophet_anomaly_detected() :- prophet_anomaly(_).
```

### `test/pg2une/periodic_analyzer_test.exs`

Add a `run_prophet` describe block covering:

1. Skips when fewer than 192 buckets
2. Asserts `prophet_anomaly` when actual is outside `[yhat_lower, yhat_upper]`
3. Retracts `prophet_anomaly` when actual is within bounds
4. Tolerates forecast errors without crashing
5. `recalculate_confidence` picks up `prophet_anomaly` facts and sets `seasonal_unexpected: true`

## What does not change

- `Anytune` dep — no API changes needed
- `Anytune.Detection.Confidence.calculate/1` — formula is unchanged, `seasonal_unexpected` signal already wired in
- All other modules
