# REST API Reference

pg2une exposes a REST API via Plug/Cowboy. Default port is 4080 in dev, 8080 in prod.

All responses are JSON with `Content-Type: application/json`.

## Endpoints

### GET /

Health check.

**Response:**
```json
{"status": "ok", "app": "pg2une"}
```

---

### GET /api/status

Current deployment state and workload classification.

**Response:**
```json
{
  "status": "idle",
  "workload_type": "oltp"
}
```

`status` values: `"idle"`, `"capturing_baseline:knobs"`, `"running_optimizer:knobs"`, `"applying_config:knobs"`, `"validating:knobs"`, etc.

`workload_type` values: `"oltp"`, `"olap"`, `"mixed"`

---

### GET /api/metrics

Latest metrics snapshot from the most recent poll.

**Response:**
```json
{
  "metrics": {
    "tps": 1200.0,
    "conn_active": 15,
    "conn_idle": 5,
    "buffer_hit_ratio": 0.985,
    "temp_bytes": 0,
    "latency_p50": 0.5,
    "latency_p95": 2.3,
    "latency_p99": 8.1
  }
}
```

Returns `null` if no metrics have been collected yet.

---

### GET /api/metrics/history

Historical metrics snapshots.

**Query params:**
- `minutes` (default: `60`) — how far back to look

**Response:**
```json
{
  "snapshots": [
    {
      "snapshot_time": "2026-02-18T12:00:00.000000Z",
      "tps": 1200.0,
      "latency_p99": 8.1,
      "buffer_hit_ratio": 0.985,
      "conn_active": 15
    }
  ]
}
```

---

### GET /api/config

Current PostgreSQL configuration on the target instance. Values are read live via `SHOW` commands through `PgConnector`.

**Response:**
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

Returns `{"config": {}}` if the target PostgreSQL is unreachable.

---

### GET /api/analysis

Current state of all detection signals from the Datalox fact store. This is the primary observability endpoint for understanding what pg2une's detection pipeline is seeing.

**Response:**
```json
{
  "analysis": {
    "cusum_degradations": [
      {"predicate": "cusum_degradation", "args": ["tps", 4.2]}
    ],
    "otava_change_points": [
      {"predicate": "otava_change_point", "args": ["tps", 0.35]}
    ],
    "prophet_forecasts": [
      {"predicate": "prophet_forecast", "args": ["tps", 1250.0, 1100.0, 1400.0]}
    ],
    "usl_deviation": [
      {"predicate": "usl_deviation", "args": [-0.12]}
    ],
    "high_confidence": true,
    "should_act": [
      {"predicate": "should_act", "args": ["knobs"]}
    ],
    "metric_values": [
      {"predicate": "metric_value", "args": ["tps", 1200.0]},
      {"predicate": "metric_value", "args": ["latency_p99", 8.1]},
      {"predicate": "metric_value", "args": ["buffer_hit_ratio", 0.985]}
    ]
  }
}
```

**Fields:**
| Field | Description |
|---|---|
| `cusum_degradations` | Metrics with active CUSUM degradation alerts |
| `otava_change_points` | E-Divisive detected change points with magnitude |
| `prophet_forecasts` | Prophet time-series predictions (yhat, lower, upper bounds) |
| `usl_deviation` | Current deviation from USL scalability model (negative = below expected) |
| `high_confidence` | Boolean — whether combined confidence score >= 0.30 |
| `should_act` | Active optimization triggers (means the system will or has just triggered optimization) |
| `metric_values` | Current metric values as seen by the detection engine |

---

### POST /api/optimize

Manually trigger an optimization run.

**Request body (optional):**
```json
{"action": "knobs"}
```

`action` values: `"knobs"` (PostgreSQL parameters), `"queries"` (indexes + hints), `"holistic"` (both). Defaults to `"holistic"`.

**Response (200):**
```json
{
  "result": {
    "status": "promoted",
    "config": {"work_mem_mb": "32MB", "random_page_cost": "1.3"},
    "improvement_pct": 12.5
  }
}
```

**Response (409 — busy):**
```json
{"error": "{:busy, :validating}"}
```

---

### GET /api/optimizations

Optimization run history with full details.

**Query params:**
- `limit` (default: `20`) — maximum number of results

**Response:**
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

**Fields:**
| Field | Description |
|---|---|
| `config` | The optimized parameters that were applied |
| `baseline_metrics` | Average metrics before optimization (last 2 min) |
| `result_metrics` | Average metrics after optimization (post-stabilization) |
| `improvement_pct` | Weighted improvement (60% TPS + 40% latency). `null` for rolled-back runs |
| `status` | `"promoted"` (config kept) or `"rolled_back"` (config reverted) |

---

### GET /api/optimization/:id

Full details for a specific optimization run.

**Response (200):**
```json
{
  "optimization": {
    "id": 1,
    "action": "knobs",
    "status": "promoted",
    "config": {"work_mem_mb": "32MB"},
    "baseline_metrics": {"tps": 1000.0, "latency_p99": 12.5, "buffer_hit_ratio": 0.95},
    "result_metrics": {"tps": 1150.0, "latency_p99": 10.2, "buffer_hit_ratio": 0.97},
    "improvement_pct": 16.36,
    "deployment_state": null,
    "canary_workload_id": null,
    "inserted_at": "2026-02-18T12:00:00Z",
    "updated_at": "2026-02-18T12:01:00Z"
  }
}
```

**Response (404):**
```json
{"error": "not found"}
```

---

### GET /api/infrastructure

Infrastructure status (microVM workloads).

**Response:**
```json
{"infrastructure": "idle"}
```

---

### POST /api/infrastructure

Ensure microVM infrastructure is running (primary PG + PgBouncer).

**Response (200):**
```json
{"status": "ok"}
```

---

### POST /api/ingest

Push metrics directly (for in-VM agent mode).

**Request body:**
```json
{
  "tps": 1200.0,
  "conn_active": 15,
  "buffer_hit_ratio": 0.985,
  "latency_p99": 8.1
}
```

**Response (200):**
```json
{"status": "ok"}
```
