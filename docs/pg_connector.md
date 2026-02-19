# PgConnector

`Pg2une.PgConnector` centralizes all `ALTER SYSTEM` interaction with the target PostgreSQL instance. It translates pg2une's internal parameter names (e.g. `shared_buffers_mb`) to PostgreSQL GUC names (`shared_buffers`) and handles the full lifecycle of config changes.

## Connection Management

PgConnector opens a **short-lived Postgrex connection** for each operation using the target URL from `Pg2une.Config.target_url()`. The connection is opened at the start of each function call and closed in an `after` block, ensuring no long-lived connections are held.

The connection URL parsing reuses the same pattern as `MetricsPoller.connect/1`, extracting hostname, port, username, password, and database from a standard PostgreSQL URL.

## Parameter Name Mapping

| pg2une key | PostgreSQL GUC | Requires Restart? |
|---|---|---|
| `shared_buffers_mb` | `shared_buffers` | Yes (postmaster) |
| `effective_cache_size_mb` | `effective_cache_size` | No (user) |
| `work_mem_mb` | `work_mem` | No (user) |
| `maintenance_work_mem_mb` | `maintenance_work_mem` | No (user) |
| `random_page_cost` | `random_page_cost` | No (user) |
| `max_connections` | `max_connections` | Yes (postmaster) |

Parameters ending in `_mb` are automatically formatted with an `MB` suffix (e.g. value `32` becomes `'32MB'`).

## Functions

### `apply_config(config_map)`

Applies configuration changes to the target PostgreSQL:

1. Filters `config_map` to only known parameter keys
2. For each parameter: runs `ALTER SYSTEM SET <guc_name> = '<value>'`
3. Calls `SELECT pg_reload_conf()` to activate changes
4. Returns `{:ok, %{"key" => "formatted_value"}}` on success

If any `ALTER SYSTEM SET` fails, the function throws immediately (no partial application) and returns `{:error, {:alter_failed, param_name, reason}}`.

Unknown keys in the config map are silently ignored.

### `rollback_config(config_map)`

Reverts configuration changes:

1. For each known parameter in `config_map`: runs `ALTER SYSTEM RESET <guc_name>`
2. Calls `SELECT pg_reload_conf()` to activate the reset
3. Returns `:ok`

Individual RESET failures are logged as warnings but do not halt the rollback — the function always attempts to reset all parameters and reload.

### `read_current_config(param_list)`

Reads current values from the target PostgreSQL:

1. For each known parameter name in `param_list`: runs `SHOW <guc_name>`
2. Returns `{:ok, %{"key" => "current_value_string"}}`

Values are returned as strings exactly as PostgreSQL reports them (e.g. `"512MB"`, `"1.1"`).

### `params_requiring_restart(config_map)`

Identifies which parameters in the config map require a PostgreSQL restart (not just a reload):

1. Collects all PG GUC names from the config map
2. Queries `pg_settings WHERE context = 'postmaster'` to find which require restart
3. Maps back to pg2une key names
4. Returns `{:ok, ["shared_buffers_mb", "max_connections"]}` etc.

This is used by `DeploymentManager` in direct mode to filter out restart-only parameters, ensuring that only reload-safe parameters are applied via `ALTER SYSTEM SET` + `pg_reload_conf()`.

## Usage

```elixir
# Apply config
{:ok, applied} = Pg2une.PgConnector.apply_config(%{
  "work_mem_mb" => 32,
  "random_page_cost" => 1.5
})
# applied => %{"work_mem_mb" => "32MB", "random_page_cost" => "1.5"}

# Read current values
{:ok, config} = Pg2une.PgConnector.read_current_config(["work_mem_mb", "random_page_cost"])
# config => %{"work_mem_mb" => "32MB", "random_page_cost" => "1.5"}

# Check which params need restart
{:ok, restart_keys} = Pg2une.PgConnector.params_requiring_restart(%{
  "shared_buffers_mb" => 512,
  "work_mem_mb" => 32
})
# restart_keys => ["shared_buffers_mb"]

# Rollback
:ok = Pg2une.PgConnector.rollback_config(%{"work_mem_mb" => 32, "random_page_cost" => 1.5})
```
