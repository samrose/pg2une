# pg2une

PostgreSQL auto-tuner running on [mxc](https://github.com/samrose/mxc) microVMs.

pg2une continuously monitors a target PostgreSQL instance, detects performance degradation, and applies optimized configuration via safe blue-green deployments — without human intervention.

## How It Works

1. **Metrics polling** — Collects TPS, latency percentiles, connection counts, and buffer hit ratio from the target PostgreSQL every 60 seconds via `pg_stat_database`, `pg_stat_activity`, and `pg_stat_statements`.

2. **Workload classification** — Classifies the current workload as OLTP, OLAP, or Mixed based on observed metrics.

3. **Regression detection** — Uses CUSUM (cumulative sum) change detection for general metric degradation and per-query regression analysis against rolling baselines.

4. **Decision rules** — [Datalog rules](priv/rules/pg2une.dl) evaluated by [Datalox](https://github.com/samrose/datalox) determine what action to take:
   - Query-only regressions &rarr; optimize queries (indexes + hints)
   - General metric degradation &rarr; optimize knobs (PostgreSQL parameters)
   - Both signals &rarr; holistic optimization
   - Includes confidence gating and a 5-minute cooldown between runs

5. **Bayesian optimization** — [Anytune](https://github.com/samrose/anytune) (backed by scikit-optimize) searches for better PostgreSQL parameter settings within workload-aware ranges.

6. **Blue-green deployment** — Launches a canary PostgreSQL instance as an mxc microVM, then gradually shifts traffic through PgBouncer (5% &rarr; 25% &rarr; 50% &rarr; 100%) with 30-second stabilization at each step. Promotes the new config if performance improves, or rolls back if p99 latency increases >10% or TPS drops >10%.

## Requirements

- [Nix](https://nixos.org/) with flakes enabled (provides Erlang 27, Elixir 1.18, PostgreSQL 17, Python 3.12)
- Or manually: Erlang/OTP 27+, Elixir 1.18+, PostgreSQL 17+, Python 3.12+ with numpy, scikit-optimize, and prophet

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

### Running Tests

```bash
mix test
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

## REST API

The application exposes a REST API on port 8080.

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Health check |
| `GET` | `/api/status` | Deployment state and workload type |
| `GET` | `/api/metrics` | Latest metrics snapshot |
| `GET` | `/api/metrics/history?minutes=60` | Historical metrics snapshots |
| `GET` | `/api/config` | Current PostgreSQL configuration on target |
| `POST` | `/api/optimize` | Trigger optimization (`{"action": "knobs\|queries\|holistic"}`) |
| `GET` | `/api/optimizations?limit=20` | Optimization run history |
| `GET` | `/api/optimization/:id` | Details for a specific optimization run |
| `GET` | `/api/infrastructure` | Infrastructure status |
| `POST` | `/api/infrastructure` | Ensure microVM infrastructure is running |
| `POST` | `/api/ingest` | Push metrics (for in-VM agent mode) |

## Architecture

```
lib/
├── pg2une.ex                    # Public API facade
└── pg2une/
    ├── application.ex           # OTP supervision tree
    ├── config.ex                # Runtime config agent
    ├── repo.ex                  # Ecto repo (pg2une's own database)
    ├── router.ex                # Plug REST API
    ├── deployment_manager.ex    # Blue-green deployment FSM
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
| [anytune](https://github.com/samrose/anytune) | GitHub | Adaptive tuning: CUSUM detection, Bayesian optimization |
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
