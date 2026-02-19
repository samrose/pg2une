# Deployment Modes

`Pg2une.DeploymentManager` supports two deployment modes for applying optimized PostgreSQL configuration.

## Direct Mode (default)

**Use case:** Local development, single-instance PostgreSQL deployments.

In direct mode, configuration changes are applied directly to the target PostgreSQL via `ALTER SYSTEM SET` and activated with `pg_reload_conf()`. No microVMs, replicas, or PgBouncer are involved.

### Pipeline

```
capture_baseline
      |
      v
run_optimizer (30 iterations)
      |
      v
filter_restart_params
  - Queries pg_settings for context='postmaster' params
  - Drops shared_buffers, max_connections (require restart)
  - Only applies reload-safe params (work_mem, effective_cache_size, etc.)
  - Falls back to known-safe list if query fails
      |
      v
apply_config_direct
  - PgConnector.apply_config(filtered_config)
  - ALTER SYSTEM SET for each param
  - pg_reload_conf()
      |
      v
wait_and_validate_direct
  - Sleep 30 seconds for stabilization
  - Capture new metrics
  - Compare against baseline
      |
      +---> improved: keep config, record improvement_pct
      +---> regressed: PgConnector.rollback_config -> ALTER SYSTEM RESET + pg_reload_conf()
```

### Safety Guarantees

- **Restart-only params filtered:** Parameters like `shared_buffers` and `max_connections` that require a PostgreSQL restart are automatically excluded. Only reload-safe parameters are applied.
- **Automatic rollback:** If p99 latency increases >10% or TPS drops >10% after the 30-second stabilization period, all changes are reverted via `ALTER SYSTEM RESET`.
- **Fallback safe list:** If the restart-param query fails (e.g. connection issue), only a hard-coded list of known reload-safe params (`work_mem_mb`, `effective_cache_size_mb`, `maintenance_work_mem_mb`, `random_page_cost`) are applied.

### Configuration

```elixir
# config/dev.exs
config :pg2une, deployment_mode: :direct  # default
```

Or pass as init option:

```elixir
Pg2une.DeploymentManager.start_link(mode: :direct)
```

## Canary Mode

**Use case:** Production deployments with mxc microVM infrastructure.

In canary mode, a streaming replica is launched as a microVM, config is applied to the replica, and traffic is gradually shifted via PgBouncer to validate the new configuration under real load.

### Pipeline

```
capture_baseline
      |
      v
run_optimizer (30 iterations)
      |
      v
launch_canary
  - Deploy pg2une-postgres-replica microVM (4 vCPU, 2 GB)
  - Platform-aware: selects aarch64 or x86_64 config
      |
      v
apply_config_to_canary
  - ALTER SYSTEM on the canary replica
      |
      v
route_and_validate
  - Route 5% traffic to canary via PgBouncer, wait 30s, validate
  - Route 25%, wait 30s, validate
  - Route 50%, wait 30s, validate
  - Route 100%, wait 30s, validate
  - At each step: if regressed, halt immediately
      |
      +---> improved at all steps: promote (apply to primary, stop canary)
      +---> regressed at any step: rollback (route 100% to primary, stop canary)
```

### Configuration

```elixir
# config/prod.exs
config :pg2une, deployment_mode: :canary
```

## Improvement Calculation

When a direct-mode optimization succeeds, the improvement percentage is calculated as a weighted average:

```
improvement = (TPS_change * 0.6) + (latency_improvement * 0.4)
```

Where:
- `TPS_change = (new_tps - baseline_tps) / baseline_tps`
- `latency_improvement = -(new_p99 - baseline_p99) / baseline_p99` (negated because lower latency is better)

The result is stored as `improvement_pct` on the `OptimizationRun` record and exposed via `GET /api/optimizations`.

## Result Recording

Both modes record results to the `optimization_runs` table:

| Field | Description |
|---|---|
| `action` | `"knobs"`, `"queries"`, or `"holistic"` |
| `status` | `"promoted"` or `"rolled_back"` |
| `config` | Map of the optimized parameters that were applied |
| `baseline_metrics` | `%{tps, latency_p99, buffer_hit_ratio}` before optimization |
| `result_metrics` | `%{tps, latency_p99, buffer_hit_ratio}` after optimization (direct mode) |
| `improvement_pct` | Float percentage improvement (direct mode, promoted only) |
