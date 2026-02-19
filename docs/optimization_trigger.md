# Optimization Trigger

`Pg2une.OptimizationTrigger` is a GenServer that closes the autonomous loop by polling the Datalox fact store for actionable signals and triggering optimization without human intervention.

## How It Works

Every 60 seconds, OptimizationTrigger:

1. **Queries** `Anytune.query(:pg2une, {:should_act, [:_]})` to check if the Datalog rule `should_act(Action)` has fired
2. If no results: does nothing
3. If results: extracts the action (`:knobs`, `:queries`, or `:holistic`) and checks guards:
   - **Idle check:** Is `DeploymentManager.status()` idle? If busy, skips.
   - **Cooldown check:** Has at least 5 minutes (300 seconds) elapsed since the last trigger? If not, skips.
4. If both guards pass: spawns a `Task` to call `DeploymentManager.start_optimization(action)` asynchronously and records `last_trigger` timestamp.

## Why Async?

The optimization call is spawned as a `Task` rather than called synchronously because `DeploymentManager.start_optimization/1` is a blocking GenServer call with a 5-minute timeout (direct mode includes a 30-second sleep). Running it in a Task prevents the trigger's poll loop from being blocked.

## Cooldown

The cooldown is enforced in Elixir using `System.monotonic_time(:second)`, not via Datalog. While the Datalog rules include a `suppress_action()` rule based on `last_optimization_time`, Datalox may not support the arithmetic required (`Now - T < 300`). The Elixir-side cooldown provides reliable protection against optimization storms.

| Parameter | Value |
|---|---|
| Poll interval | 60 seconds |
| Cooldown | 300 seconds (5 minutes) |

## State

```elixir
%{last_trigger: integer | nil}
```

`last_trigger` is the monotonic time (in seconds) of the most recent optimization trigger. Set to `nil` on startup, meaning the first poll can trigger immediately if conditions are met.

## Integration

OptimizationTrigger sits at the end of the detection pipeline:

```
MetricsPoller (every 15s)
    |
    v
Anytune CUSUM -> metric_degraded facts
QueryRegression -> query_regression facts
    |
    v
PeriodicAnalyzer (every 5 min)
    |
    v
E-Divisive, USL -> high_confidence fact
    |
    v
Datalog rules -> should_act(Action) fact
    |
    v
OptimizationTrigger (every 60s) -> DeploymentManager.start_optimization
```

## Supervision

OptimizationTrigger is started after DeploymentManager in the supervision tree, ensuring the manager is available when triggers fire. If it crashes, the `one_for_one` supervisor restarts it and it resumes polling after the next 60-second interval.
