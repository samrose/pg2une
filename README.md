# pg2une

PostgreSQL auto-tuner running on [mxc](https://github.com/samrose/mxc) microVMs.

pg2une continuously monitors a target PostgreSQL instance, detects performance degradation using multiple statistical methods, and applies optimized configuration autonomously — without human intervention.

## How It Works

1. **Metrics polling** — Collects TPS, latency percentiles, connection counts, and buffer hit ratio from the target PostgreSQL every 15 seconds (dev) or 60 seconds (prod) via `pg_stat_database`, `pg_stat_activity`, and `pg_stat_statements`.

2. **Workload classification** — Classifies the current workload as OLTP, OLAP, or Mixed based on observed metrics (TPS, connection counts, latency, temp bytes).

3. **Real-time detection (CUSUM)** — On every poll, [Anytune](https://github.com/samrose/anytune) runs cumulative sum (CUSUM) change detection on each metric and asserts `metric_degraded` facts to the Datalox fact store.

4. **Per-query regression detection** — Compares each query's current execution time against a 6-hour rolling baseline. Flags regressions when execution time increases >20% at similar call volume. Asserts `query_regression` facts.

5. **Periodic deep analysis** — The `PeriodicAnalyzer` runs heavier ML analysis on accumulated history:
   - **E-Divisive (Otava)** every 5 minutes — change point detection across TPS, p99 latency, and buffer hit ratio. Asserts `otava_change_point(Metric, Magnitude)` facts.
   - **USL (Universal Scalability Law)** every 5 minutes — fits a scalability model to concurrency/throughput data and checks how far current performance deviates from the model. Asserts `usl_deviation(Dev)` facts.
   - **Prophet** every 30 minutes — time-series forecasting for trend prediction. Asserts `prophet_forecast(Metric, Yhat, Lower, Upper)` facts.
   - **Confidence recalculation** — after each E-Divisive or USL run, combines all signals (CUSUM count, E-Divisive confirmation, USL deviation, seasonal unexpectedness) into a single confidence score. If score >= 0.30, asserts `high_confidence()`.

6. **Decision rules** — [Datalog rules](priv/rules/pg2une.dl) evaluated by [Datalox](https://github.com/samrose/datalox) determine what action to take:
   - Query-only regressions &rarr; `should_optimize(queries)` — optimize indexes + hints
   - General metric degradation &rarr; `should_optimize(knobs)` — optimize PostgreSQL parameters
   - Both signals &rarr; `should_optimize(holistic)` — full optimization
   - Confidence gating: `action_ready(Action)` requires `should_optimize(Action)` AND `high_confidence()`
   - Cooldown: `suppress_action()` prevents re-optimization within 5 minutes
   - Final trigger: `should_act(Action)` fires when ready and not suppressed

7. **Automatic triggering** — The `OptimizationTrigger` polls the fact store for `should_act(Action)` every 60 seconds. When it fires, it checks that the DeploymentManager is idle, enforces a 5-minute cooldown in Elixir, then triggers optimization.

8. **Bayesian optimization** — [Anytune](https://github.com/samrose/anytune) (backed by scikit-optimize) searches for better PostgreSQL parameter settings within workload-aware ranges across 30 iterations.

9. **Config application** — Two deployment modes:
   - **Direct mode** (default for local dev) — applies `ALTER SYSTEM SET` directly to the target PostgreSQL via `PgConnector`, calls `pg_reload_conf()`, waits 30 seconds for stabilization, then validates. Automatically filters out parameters that require a restart (e.g. `shared_buffers`, `max_connections`).
   - **Canary mode** (production) — launches a canary PostgreSQL replica as an mxc microVM, gradually shifts traffic through PgBouncer (5% &rarr; 25% &rarr; 50% &rarr; 100%) with 30-second stabilization at each step.
   - In both modes: promotes the new config if performance improves, or rolls back (`ALTER SYSTEM RESET` + `pg_reload_conf()`) if p99 latency increases >10% or TPS drops >10%.

## End-to-End Flow

```
process-compose up
        |
        v
MetricsPoller polls every 15s
        |
        +---> Anytune.ingest -> CUSUM -> metric_degraded facts
        +---> QueryRegression -> query_regression facts
        |
        v  (after 5 min)
PeriodicAnalyzer runs E-Divisive -> otava_change_point facts
PeriodicAnalyzer fits USL model  -> usl_deviation fact
PeriodicAnalyzer recalculates    -> high_confidence (if score >= 0.30)
        |
        v
Datalog: metric_degraded + high_confidence -> should_act(knobs)
        |
        v
OptimizationTrigger detects should_act
        |
        v
DeploymentManager (direct mode):
  1. Capture baseline metrics
  2. Bayesian optimization (30 iterations)
  3. Filter restart-only params
  4. ALTER SYSTEM SET via PgConnector
  5. pg_reload_conf()
  6. Wait 30s stabilization
  7. Capture post-change metrics
  8. Compare: improved -> keep config | regressed -> ALTER SYSTEM RESET
        |
        v  (after 30 min)
PeriodicAnalyzer runs Prophet -> trend predictions
        |
        v
GET /api/analysis  -> full detection state
GET /api/optimizations -> real improvement percentages
```

## Requirements

- [Nix](https://nixos.org/) with flakes enabled (provides Erlang 27, Elixir 1.18, PostgreSQL 17, Python 3.12)
- Or manually: Erlang/OTP 27+, Elixir 1.18+, PostgreSQL 17+, Python 3.12+ with numpy, scikit-optimize, prophet, otava, scipy, and pandas

## Getting Started

### Using Nix (recommended)

```bash
nix develop
mix setup
mix run --no-halt
```

### Using process-compose (fully automated)

```bash
nix develop
process-compose up
```

This initializes a local PostgreSQL data directory in `.pg_data/`, runs migrations, and starts the application. The startup order is: `postgres-init` &rarr; `postgres` &rarr; `db-setup` &rarr; `app`.

### Verifying It Works

After `process-compose up`, wait 5+ minutes for metrics to accumulate, then:

```bash
# Check detection signals
curl http://localhost:4080/api/analysis | jq

# Trigger an optimization manually
curl -X POST http://localhost:4080/api/optimize -H 'Content-Type: application/json' -d '{"action":"knobs"}'

# Check that config was actually changed
curl http://localhost:4080/api/config | jq

# See optimization results with improvement percentages
curl http://localhost:4080/api/optimizations | jq
```

### Running Tests

```bash
mix test

# Run integration tests (requires a running PostgreSQL)
mix test --include integration
```

## Configuration

### Environment Variables (production)

| Variable | Required | Description |
|---|---|---|
| `DATABASE_URL` | Yes | pg2une's own database connection URL |
| `TARGET_POSTGRES_URL` | Yes | The PostgreSQL instance to tune |
| `MXC_COORDINATOR` | No | mxc coordinator URL (default: `http://localhost:4000`) |
| `POOL_SIZE` | No | Database connection pool size (default: `10`) |

### Application Config

| Key | Default | Description |
|---|---|---|
| `:target_url` | `nil` | Target PostgreSQL connection URL |
| `:mxc_coordinator` | `http://localhost:4000` | mxc coordinator URL |
| `:poll_interval` | `60_000` | Metrics polling interval in milliseconds |
| `:total_ram_mb` | `4096` | Total RAM available for scoring calculations |
| `:port` | `8080` | HTTP API listen port |
| `:deployment_mode` | `:direct` | Deployment mode: `:direct` or `:canary` |

## REST API

The application exposes a REST API (port 4080 in dev, 8080 in prod).

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Health check |
| `GET` | `/api/status` | Deployment state and workload type |
| `GET` | `/api/metrics` | Latest metrics snapshot |
| `GET` | `/api/metrics/history?minutes=60` | Historical metrics snapshots |
| `GET` | `/api/config` | Current PostgreSQL configuration on target (live from `SHOW`) |
| `GET` | `/api/analysis` | Detection state: CUSUM, E-Divisive, USL, Prophet, confidence |
| `POST` | `/api/optimize` | Trigger optimization (`{"action": "knobs\|queries\|holistic"}`) |
| `GET` | `/api/optimizations?limit=20` | Optimization history with config, metrics, improvement_pct |
| `GET` | `/api/optimization/:id` | Full details for a specific optimization run |
| `GET` | `/api/infrastructure` | Infrastructure status |
| `POST` | `/api/infrastructure` | Ensure microVM infrastructure is running |
| `POST` | `/api/ingest` | Push metrics (for in-VM agent mode) |

### GET /api/analysis

Returns the current state of all detection signals from the Datalox fact store:

```json
{
  "analysis": {
    "cusum_degradations": [{"predicate": "cusum_degradation", "args": ["tps", 4.2]}],
    "otava_change_points": [{"predicate": "otava_change_point", "args": ["tps", 0.35]}],
    "prophet_forecasts": [{"predicate": "prophet_forecast", "args": ["tps", 1250.0, 1100.0, 1400.0]}],
    "usl_deviation": [{"predicate": "usl_deviation", "args": [-0.12]}],
    "high_confidence": true,
    "should_act": [{"predicate": "should_act", "args": ["knobs"]}],
    "metric_values": [{"predicate": "metric_value", "args": ["tps", 1200.0]}]
  }
}
```

### GET /api/config

Returns the current value of all tunable PostgreSQL parameters, read live from the target instance:

```json
{
  "config": {
    "shared_buffers_mb": "512MB",
    "effective_cache_size_mb": "1536MB",
    "work_mem_mb": "16MB",
    "maintenance_work_mem_mb": "256MB",
    "random_page_cost": "1.1",
    "max_connections": "100"
  }
}
```

### GET /api/optimizations

Returns optimization history including the config that was applied, baseline and result metrics, and the calculated improvement percentage:

```json
{
  "optimizations": [
    {
      "id": 1,
      "action": "knobs",
      "status": "promoted",
      "config": {"work_mem_mb": "32MB", "random_page_cost": "1.3"},
      "baseline_metrics": {"tps": 1000.0, "latency_p99": 12.5, "buffer_hit_ratio": 0.95},
      "result_metrics": {"tps": 1150.0, "latency_p99": 10.2, "buffer_hit_ratio": 0.97},
      "improvement_pct": 16.36,
      "created_at": "2026-02-18T12:00:00Z"
    }
  ]
}
```

## Architecture

```
lib/
├── pg2une.ex                    # Public API facade
└── pg2une/
    ├── application.ex           # OTP supervision tree
    ├── config.ex                # Runtime config agent
    ├── repo.ex                  # Ecto repo (pg2une's own database)
    ├── router.ex                # Plug REST API
    ├── pg_connector.ex          # ALTER SYSTEM interaction with target PG
    ├── deployment_manager.ex    # Optimization orchestrator (direct + canary modes)
    ├── periodic_analyzer.ex     # E-Divisive, USL, Prophet analysis on schedule
    ├── optimization_trigger.ex  # Polls fact store, triggers optimization autonomously
    ├── metrics_poller.ex        # Polls target PostgreSQL for metrics
    ├── metrics_store.ex         # Persists and queries metrics history
    ├── workload_detector.ex     # OLTP/OLAP/Mixed classification
    ├── scorer.ex                # Scores configurations 0.0–1.0
    ├── tunable.ex               # Anytune.Tunable behaviour for PostgreSQL
    ├── index_analyzer.ex        # Index candidate generation from pg_qualstats
    ├── hint_analyzer.ex         # pg_hint_plan candidate generation
    ├── query_regression.ex      # Per-query regression detection
    ├── pgbouncer.ex             # PgBouncer config and traffic routing
    └── schemas/                 # Ecto schemas for snapshots, observations, runs
```

### Key Modules

#### PgConnector (`lib/pg2une/pg_connector.ex`)

Centralizes all `ALTER SYSTEM` interaction with the target PostgreSQL. Opens a short-lived Postgrex connection for each operation.

| Function | Description |
|---|---|
| `apply_config(config_map)` | Translates pg2une keys to PG GUC names, runs `ALTER SYSTEM SET` for each, then `pg_reload_conf()` |
| `rollback_config(config_map)` | Runs `ALTER SYSTEM RESET` for each parameter, then `pg_reload_conf()` |
| `read_current_config(param_list)` | Runs `SHOW` for each parameter, returns current values |
| `params_requiring_restart(config_map)` | Queries `pg_settings WHERE context = 'postmaster'` to identify params needing restart |
| `param_mapping()` | Returns the `%{"pg2une_key" => "pg_guc_name"}` mapping |

Parameter name mapping:

| pg2une key | PostgreSQL GUC |
|---|---|
| `shared_buffers_mb` | `shared_buffers` |
| `effective_cache_size_mb` | `effective_cache_size` |
| `work_mem_mb` | `work_mem` |
| `maintenance_work_mem_mb` | `maintenance_work_mem` |
| `random_page_cost` | `random_page_cost` |
| `max_connections` | `max_connections` |

#### DeploymentManager (`lib/pg2une/deployment_manager.ex`)

Orchestrates the full optimization pipeline. Supports two modes configured via `:deployment_mode`:

**Direct mode** (`:direct`, default) — for local dev and single-instance deployments:
1. Captures baseline metrics (average of last 2 minutes)
2. Runs Bayesian optimizer (30 iterations via scikit-optimize)
3. Filters out restart-only parameters (`shared_buffers`, `max_connections`)
4. Applies reload-safe parameters via `PgConnector.apply_config/1`
5. Waits 30 seconds for stabilization
6. Captures post-change metrics and compares against baseline
7. If improved: keeps config, records `improvement_pct` (weighted: 60% TPS + 40% latency)
8. If regressed (p99 > +10% or TPS < -10%): runs `PgConnector.rollback_config/1`

**Canary mode** (`:canary`) — for production with mxc microVMs:
1. Same baseline capture and optimizer
2. Launches a canary PostgreSQL replica microVM
3. Applies config to canary
4. Gradually routes traffic through PgBouncer (5% &rarr; 25% &rarr; 50% &rarr; 100%)
5. Validates at each step; rolls back immediately on regression
6. Promotes or rolls back

#### PeriodicAnalyzer (`lib/pg2une/periodic_analyzer.ex`)

GenServer that runs heavy ML analysis on accumulated metrics history. This is the critical bridge between raw metric collection and the Datalog decision rules — without it, `high_confidence()` is never asserted and `should_act` never fires.

| Analysis | Schedule | Min. Data Points | Facts Asserted |
|---|---|---|---|
| E-Divisive (Otava) | Every 5 min | 20 | `otava_change_point(Metric, Magnitude)` |
| USL | Every 5 min | 5 | `usl_deviation(Deviation)` |
| Prophet | Every 30 min | 24 | `prophet_forecast(Metric, Yhat, Lower, Upper)` |
| Confidence | After E-Divisive/USL | — | `high_confidence()` if score >= 0.30 |

Confidence scoring combines:
- CUSUM degradation count: `min(count * 0.15, 0.30)`
- USL deviation < -0.15: `+0.15`
- E-Divisive confirmation: `+0.15`
- Seasonal unexpectedness: `+0.10`

#### OptimizationTrigger (`lib/pg2une/optimization_trigger.ex`)

GenServer that polls `Anytune.query(:pg2une, {:should_act, [:_]})` every 60 seconds. When the Datalog rule fires:
1. Checks that DeploymentManager is idle
2. Enforces 5-minute cooldown (tracked via monotonic clock in Elixir)
3. Spawns a Task to call `DeploymentManager.start_optimization(action)`

### Datalog Decision Rules (`priv/rules/pg2une.dl`)

```datalog
% Query-level problems → optimize queries
should_optimize(queries) :- query_regression(_, same_load, _), not workload_shift().

% General metric degradation → optimize knobs
should_optimize(knobs) :- metric_degraded(_), not query_regression(_, _, _).

% Both signals → full holistic optimization
should_optimize(holistic) :- metric_degraded(_), query_regression(_, _, _).

% Confidence gating
action_ready(Action) :- should_optimize(Action), high_confidence().

% Cooldown (5 minutes)
suppress_action() :- last_optimization_time(T), now(Now), Now - T < 300.

% Final trigger
should_act(Action) :- action_ready(Action), not suppress_action().

% Informational: E-Divisive confirmed significant change
otava_confirmed(Metric) :- otava_change_point(Metric, Magnitude), Magnitude > 0.10.

% Informational: USL model shows underperformance
usl_warning() :- usl_deviation(Dev), Dev < -0.15.
```

### Supervision Tree

```
Pg2une.Supervisor (one_for_one)
├── Pg2une.Repo                  # Database connection pool
├── Pg2une.Config                # Runtime config agent
├── Pg2une.WorkloadDetector      # Workload classification
├── Anytune (:pg2une)            # Detection + optimization engine
├── Pg2une.MetricsPoller         # Polls target PG for metrics
├── Pg2une.PeriodicAnalyzer      # E-Divisive, USL, Prophet analysis
├── Pg2une.IndexAnalyzer         # Index candidate generation
├── Pg2une.HintAnalyzer          # Hint candidate generation
├── Pg2une.DeploymentManager     # Optimization orchestrator
├── Pg2une.OptimizationTrigger   # Autonomous optimization trigger
└── Plug.Cowboy                  # HTTP API server
```

### MicroVM Definitions

```
priv/nix/
├── postgres.nix          # Primary PostgreSQL 17 (4 vCPUs, 2048 MB)
├── postgres-replica.nix  # Canary streaming replica
└── pgbouncer.nix         # PgBouncer traffic router (1 vCPU, 256 MB)
```

## Dependencies

| Package | Source | Purpose |
|---|---|---|
| [anytune](https://github.com/samrose/anytune) | GitHub | Adaptive tuning: CUSUM detection, E-Divisive, USL, Prophet, Bayesian optimization |
| [mxc](https://github.com/samrose/mxc) | GitHub | MicroVM orchestration |
| [datalox](https://github.com/samrose/datalox) | GitHub | Datalog rules engine |
| [postgrex](https://hex.pm/packages/postgrex) | Hex | PostgreSQL driver |
| [ecto_sql](https://hex.pm/packages/ecto_sql) | Hex | Database ORM and migrations |
| [plug_cowboy](https://hex.pm/packages/plug_cowboy) | Hex | HTTP server |
| [jason](https://hex.pm/packages/jason) | Hex | JSON encoding/decoding |

Python dependencies (installed automatically via Nix dev shell):
- numpy
- scikit-optimize
- prophet
- otava (E-Divisive change point detection)
- scipy (USL model fitting)
- pandas (Prophet data frames)
