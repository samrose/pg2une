# PostgreSQL Cluster Lifecycle with Rolling Node Replacement

## Problem

pg2une's direct mode applies ALTER SYSTEM SET to a live primary — effective for dev but risky in production. Config changes can degrade performance, and rollback requires another ALTER SYSTEM RESET cycle during which clients suffer. The canary mode skeleton exists but is stubbed: no real config application, no real traffic routing, no real promotion.

## Design

pg2une owns the full lifecycle of a PostgreSQL cluster running in mxc microVMs. When it formulates a performance improvement, it launches a new node as an async standby, validates it under real read traffic, and promotes it to primary via role swap. The cluster never leaves a safe state during the process.

## Cluster Topology

Default cluster: 3 mxc microVMs.

| Node | Role | NixOS Config | Resources |
|------|------|-------------|-----------|
| Primary | Writable, receives all writes | `postgres.nix` | 4 vCPU, 2048 MB |
| Sync Replica | Synchronous standby for HA | `postgres-replica.nix` | 4 vCPU, 2048 MB |
| PgBouncer | Connection pooling + read routing | `pgbouncer.nix` | 1 vCPU, 256 MB |

Replication: primary uses `synchronous_standby_names = 'FIRST 1 (*)'`. The sync replica confirms commits for data safety. When a canary joins, it streams asynchronously (no performance impact on the primary). WAL settings in postgres.nix: `max_wal_senders = 5`, `max_replication_slots = 5`, `wal_level = replica`.

### Node Model

```elixir
%Pg2une.ClusterManager.Node{
  id: "pg2une-primary-abc123",     # mxc workload ID
  role: :primary,                   # :primary | :sync_replica | :canary | :pgbouncer
  ip: "192.168.100.2",
  port: 5432,
  config_version: 1,               # bumped on each successful optimization
  status: :healthy,                 # :healthy | :syncing | :promoting | :draining | :down
  launched_at: ~U[2026-02-18 12:00:00Z]
}
```

## Optimization & Promotion Flow

### Phase 1: Prepare (0-60s)

pg2une detects `should_act(knobs)` via Datalox rules. DeploymentManager runs Bayesian optimizer (30 iterations via Anytune/scikit-optimize), producing a new config (e.g. `{work_mem: "32MB", random_page_cost: "1.3"}`).

### Phase 2: Launch Canary (60-120s)

1. `ClusterManager.launch_canary(config)` deploys a new VM using `postgres-replica.nix`
2. Wait for VM boot + PostgreSQL ready (`pg_isready`)
3. Configure async streaming replication from current primary (`primary_conninfo`)
4. Wait for replica to catch up (`replay_lag < 1MB`)
5. Apply optimized config via `ALTER SYSTEM SET` + `pg_reload_conf()` on canary

### Phase 3: Validate via Read Traffic (120-300s)

PgBouncer routes read queries to canary with graduated ramp-up:

| Step | Canary % | Duration | Gate |
|------|----------|----------|------|
| 1 | 5% | 30s | p99 latency < 120% of primary baseline |
| 2 | 25% | 30s | p99 latency < 120% of primary baseline |
| 3 | 50% | 60s | TPS >= 95% of baseline AND p99 < 115% of baseline |

If ANY gate fails: tear down canary, revert PgBouncer to 100% primary, record as `rolled_back`. The cluster never left a safe state — the canary was async, so removing it has zero impact on the primary or sync replica.

### Phase 4: Promote (300-330s)

1. PgBouncer: `PAUSE` all pools (queues in-flight transactions, <1s)
2. Ensure canary caught up: `replay_lag = 0`
3. `SELECT pg_promote()` on canary — canary becomes new primary
4. Reconfigure old primary: set `primary_conninfo` to point at new primary, restart as sync replica
5. PgBouncer: update backends (primary_ip = canary_ip, standby_ip = old_primary_ip)
6. PgBouncer: `RESUME` — traffic flows to new primary

### Phase 5: Cleanup (330-360s)

1. Tear down old sync replica VM (redundant — old primary took its role)
2. Update ClusterManager topology: primary = former canary, sync_replica = former primary
3. Record optimization result with `improvement_pct`
4. Bump `config_version`

Final state: same 3 VMs (primary + sync replica + pgbouncer), but the primary has the optimized config.

## Architecture: ClusterManager GenServer

ClusterManager is a plain GenServer FSM — not driven by Datalox rules. Cluster orchestration is sequential state machine transitions with threshold guards, not multi-signal declarative reasoning. Datalox is the wrong tool for this.

However, ClusterManager **asserts health facts into Datalox** so the existing optimization rules can suppress actions during unhealthy states:

```datalog
suppress_action() :- cluster_unhealthy().
suppress_action() :- replication_lag_high().
```

### Public API

```elixir
defmodule Pg2une.ClusterManager do
  # Lifecycle
  deploy_cluster()              # Launch primary + sync replica + pgbouncer
  teardown_cluster()            # Stop all VMs
  topology()                    # Returns %{nodes: ..., primary_id: ..., ...}
  cluster_ready?()              # All nodes healthy, replication established

  # Optimization cycle
  launch_canary(config)         # Deploy async standby with optimized config
  canary_synced?()              # Check replay_lag < threshold
  promote_canary()              # pg_promote + role swap + pgbouncer update
  rollback_canary()             # Tear down canary, revert pgbouncer

  # Health
  node_health(node_id)          # pg_isready + replication lag
end
```

### State Machine

```
:uninitialized → deploy_cluster() → :deploying → :ready
:ready → launch_canary() → :optimizing → promote_canary() → :promoting → :ready
                                       → rollback_canary() → :ready
:ready → teardown_cluster() → :uninitialized
```

ClusterManager asserts `cluster_unhealthy()` into Datalox whenever status is not `:ready`, preventing optimization triggers from firing during transitions.

## PgBouncer Config Management

The existing `Pg2une.PgBouncer` module gets a real implementation:

1. `update_routing(pgbouncer_id, %{canary_ip: ip, canary_pct: 5})` generates new `pgbouncer.ini` with weighted backends
2. Pushes config to PgBouncer VM via `Mxc.Coordinator.exec_in_workload(pgbouncer_id, ...)`
3. Sends `SIGHUP` to reload: `kill -HUP $(cat /run/pgbouncer/pgbouncer.pid)`
4. During promotion: `PAUSE` pools, update backends, `RESUME`

## PgConnector Changes

Add `connect_to(ip, port)` variant so configs can be applied to a specific node (the canary) rather than just the default target.

## Module Changes

| Module | Change |
|--------|--------|
| **New:** `Pg2une.ClusterManager` | GenServer FSM, node tracking, health checks, deploy/promote/rollback |
| `Pg2une.DeploymentManager` | Canary pipeline delegates to ClusterManager |
| `Pg2une.PgBouncer` | Real config push via mxc exec + SIGHUP |
| `Pg2une.PgConnector` | Add `connect_to/2` for targeting specific nodes |
| `Pg2une.Router` | Add cluster API endpoints |
| `priv/rules/pg2une.dl` | Add `suppress_action() :- cluster_unhealthy().` |

## API Endpoints

| Endpoint | Description |
|----------|-------------|
| `GET /api/cluster` | Full cluster topology: nodes, roles, IPs, config versions, health |
| `POST /api/cluster/deploy` | Bootstrap a new cluster |
| `DELETE /api/cluster` | Teardown entire cluster |
| `GET /api/cluster/nodes/:id` | Specific node details + replication lag |

Existing `GET /api/infrastructure` and `POST /api/infrastructure` delegate to ClusterManager.

## Decisions Made

- **Topology:** Single primary + 1 sync replica + PgBouncer (3 VMs)
- **Canary replication:** Async (no perf impact during testing)
- **Validation:** Real read traffic via PgBouncer with graduated ramp-up
- **Promotion:** Role swap (promote canary, demote old primary to sync replica)
- **Routing:** PgBouncer in mxc VM (matches everything-in-VMs architecture)
- **Orchestration logic:** GenServer FSM (not Datalox rules — wrong tool for sequential state machines)
- **Datalox integration:** ClusterManager asserts health facts; optimization rules consume them to suppress actions during unhealthy states
- **Scope:** pg2une owns full cluster lifecycle (deploy, optimize, promote, teardown)
