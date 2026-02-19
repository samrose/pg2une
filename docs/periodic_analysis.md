# Periodic Analysis

`Pg2une.PeriodicAnalyzer` is a GenServer that runs heavy ML analysis on accumulated metrics history and bridges the gap between raw metric collection and the Datalog decision engine.

Without PeriodicAnalyzer, `high_confidence()` is never asserted and the `should_act(Action)` rule never fires — meaning no autonomous optimization can happen.

## Analysis Methods

### E-Divisive Change Point Detection (every 5 minutes)

Uses the [Otava](https://pypi.org/project/otava/) library (via `Anytune.edivisive/3`) to detect statistically significant change points in time series data.

**Metrics analyzed:** `tps`, `latency_p99`, `buffer_hit_ratio`

**Minimum data:** 20 data points (at 15s polling in dev, this is ~5 minutes)

**Process:**
1. Fetches last 30 minutes of system snapshots from MetricsStore
2. For each metric, extracts the time series and calls `Anytune.edivisive(:pg2une, metric, values)`
3. Filters results for significant change points (magnitude > 0.10)
4. Asserts `otava_change_point(Metric, MaxMagnitude)` facts to the Datalox fact store
5. Retracts change point facts for metrics where no significant change was detected

**Datalox fact:** `{:otava_change_point, [metric_name, magnitude]}`

The Datalog rule `otava_confirmed(Metric)` fires when a change point has magnitude > 0.10.

### USL Scalability Modeling (every 5 minutes)

Fits the [Universal Scalability Law](https://en.wikipedia.org/wiki/Neil_J._Gunther#Universal_Scalability_Law) model to observed concurrency/throughput data via `Anytune.usl/3`.

**Minimum data:** 5 data points

**Process:**
1. Fetches last 30 minutes of system snapshots
2. Extracts `conn_active` (concurrency) and `tps` (throughput) vectors
3. Calls `Anytune.usl(:pg2une, :fit, %{"concurrency" => [...], "throughput" => [...]})` to fit the USL model and get parameters (alpha, beta, max_throughput)
4. Calls `Anytune.usl(:pg2une, :deviation, ...)` with the latest data point to check how far actual performance deviates from the model
5. Asserts `usl_deviation(deviation)` fact

**Datalox fact:** `{:usl_deviation, [deviation_float]}`

A negative deviation means the system is performing below the model's prediction. The Datalog rule `usl_warning()` fires when deviation < -0.15 (15% below expected).

### Prophet Time-Series Forecasting (every 30 minutes)

Uses [Prophet](https://facebook.github.io/prophet/) (via `Anytune.forecast/3`) for time-series forecasting with trend and seasonality decomposition.

**Metrics analyzed:** `tps`, `latency_p99`, `buffer_hit_ratio`

**Minimum data:** 24 data points

**Process:**
1. Fetches last 6 hours of system snapshots (wider window for trend detection)
2. For each metric, extracts ISO 8601 timestamps and values
3. Calls `Anytune.forecast(:pg2une, metric, timestamps: [...], values: [...], periods: 24, freq: "H")`
4. Asserts `prophet_forecast(Metric, Yhat, Lower, Upper)` with the next-period prediction and confidence interval

**Datalox fact:** `{:prophet_forecast, [metric_name, yhat, yhat_lower, yhat_upper]}`

Prophet forecasts are informational — they don't directly trigger optimization but contribute to the overall analysis picture visible via `GET /api/analysis`.

## Confidence Recalculation

After each E-Divisive or USL run, PeriodicAnalyzer recalculates the overall detection confidence by combining multiple signals:

| Signal | Weight | Description |
|---|---|---|
| CUSUM degradation count | `min(count * 0.15, 0.30)` | Number of metrics with CUSUM degradation alerts |
| USL deviation < -0.15 | `+0.15` | Performance significantly below scalability model |
| E-Divisive confirms | `+0.15` | At least one change point detected with magnitude > 0.10 |
| Seasonal unexpected | `+0.10` | Current metric values >30% outside seasonal expected range |

**Maximum confidence:** 1.0

**Threshold for `high_confidence()`:** 0.30

When confidence >= 0.30, the fact `high_confidence()` is asserted. This unblocks the Datalog rule:

```datalog
action_ready(Action) :- should_optimize(Action), high_confidence().
```

When confidence drops below 0.30, `high_confidence()` is retracted, which prevents `should_act` from firing.

### Example Confidence Scenarios

| Scenario | Score | Triggers? |
|---|---|---|
| 1 metric with CUSUM alert | 0.15 | No |
| 2 metrics with CUSUM alerts | 0.30 | Yes |
| 1 CUSUM + E-Divisive confirms | 0.30 | Yes |
| 1 CUSUM + USL below expected | 0.30 | Yes |
| All signals active | 0.70 | Yes |

## Seasonal Unexpectedness Check

PeriodicAnalyzer also checks whether current metric values deviate significantly from seasonal baselines (maintained by Anytune's built-in seasonal detection):

1. Queries `metric_value` and `seasonal_expected` facts from the fact store
2. For each metric, calculates: `deviation = |value - expected| / |expected|`
3. If any metric deviates by more than 30%, marks `seasonal_unexpected: true`

## State

PeriodicAnalyzer maintains minimal state between runs:

```elixir
%{
  usl_params: %{alpha: float, beta: float, max_throughput: float} | nil,
  last_change_points: %{"metric_name" => magnitude},
  last_usl_deviation: float | nil
}
```

This state is used for confidence recalculation but is not persisted — if the process restarts, it rebuilds state on the next analysis cycle.
