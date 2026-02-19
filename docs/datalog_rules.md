# Datalog Decision Rules

pg2une uses [Datalox](https://github.com/samrose/datalox) — a Datalog engine for Elixir — to make optimization decisions. Rules are defined in `priv/rules/pg2une.dl` and evaluated against facts asserted by various components.

## Fact Sources

| Fact | Asserted By | When |
|---|---|---|
| `metric_degraded(Metric)` | Anytune CUSUM detection | Every poll (15s dev / 60s prod) |
| `metric_value(Metric, Value)` | Anytune detection server | Every poll |
| `seasonal_expected(Metric, Expected)` | Anytune seasonal baseline | Every poll |
| `now(Timestamp)` | Anytune detection server | Every poll |
| `query_regression(QueryId, LoadType, Pct)` | Pg2une.QueryRegression | Every poll |
| `otava_change_point(Metric, Magnitude)` | Pg2une.PeriodicAnalyzer | Every 5 min |
| `usl_deviation(Deviation)` | Pg2une.PeriodicAnalyzer | Every 5 min |
| `prophet_forecast(Metric, Yhat, Lower, Upper)` | Pg2une.PeriodicAnalyzer | Every 30 min |
| `high_confidence()` | Pg2une.PeriodicAnalyzer | After E-Divisive/USL runs |

## Rules

### Action Selection

```datalog
% Query-only regressions without workload shift → optimize queries
should_optimize(queries) :-
    query_regression(_, same_load, _),
    not workload_shift().

% General metric degradation without query issues → optimize knobs
should_optimize(knobs) :-
    metric_degraded(_),
    not query_regression(_, _, _).

% Both metric degradation AND query regression → holistic optimization
should_optimize(holistic) :-
    metric_degraded(_),
    query_regression(_, _, _).
```

### Confidence Gating

```datalog
% Only act when confidence is high enough (score >= 0.30)
action_ready(Action) :-
    should_optimize(Action),
    high_confidence().
```

`high_confidence()` is asserted by `PeriodicAnalyzer` when the combined confidence score from CUSUM, E-Divisive, USL, and seasonal signals reaches 0.30. This prevents acting on transient noise.

### Cooldown

```datalog
% Suppress if optimized within last 5 minutes
suppress_action() :-
    last_optimization_time(T),
    now(Now),
    Now - T < 300.
```

Note: This rule depends on Datalox arithmetic support. As a safety net, `OptimizationTrigger` also enforces a 5-minute cooldown in Elixir.

### Final Trigger

```datalog
% Fire when ready and not suppressed
should_act(Action) :-
    action_ready(Action),
    not suppress_action().
```

This is the fact that `OptimizationTrigger` polls for every 60 seconds.

### Informational Rules

```datalog
% E-Divisive confirmed a significant change point (magnitude > 10%)
otava_confirmed(Metric) :-
    otava_change_point(Metric, Magnitude),
    Magnitude > 0.10.

% USL model shows system performing >15% below expected
usl_warning() :-
    usl_deviation(Dev),
    Dev < -0.15.
```

These rules are informational — they derive queryable facts but don't directly trigger optimization. They're useful for the `GET /api/analysis` endpoint to show human-readable status.

## Rule Evaluation Flow

```
Polling:
  metric_degraded("tps")        <- from CUSUM
  query_regression(42, "same_load", 35.0)  <- from QueryRegression

  should_optimize(holistic) fires (both degradation + regression)

Every 5 min:
  otava_change_point("tps", 0.35)  <- from E-Divisive
  usl_deviation(-0.18)             <- from USL model
  high_confidence()                <- from confidence calc (score = 0.45)

  action_ready(holistic) fires (should_optimize + high_confidence)

  should_act(holistic) fires (ready and not suppressed)

Every 60s:
  OptimizationTrigger detects should_act(holistic)
  -> DeploymentManager.start_optimization(:holistic)
```

## Querying Facts

You can query the current fact store state programmatically or via the API:

```elixir
# From Elixir
Anytune.query(:pg2une, {:should_act, [:_]})
#=> [{:should_act, ["knobs"]}]

Anytune.query(:pg2une, {:metric_degraded, [:_]})
#=> [{:metric_degraded, ["tps"]}]

Anytune.query(:pg2une, {:high_confidence, []})
#=> [{:high_confidence, []}]  or  []
```

```bash
# From the API
curl http://localhost:4080/api/analysis | jq
```
