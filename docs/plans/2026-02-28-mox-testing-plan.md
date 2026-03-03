# Mox Testing Infrastructure Plan

**Goal:** Add Mox-based unit tests for `PeriodicAnalyzer` so the Anytune ML pipeline and FactStore interactions can be tested without running Python workers or a live Datalox instance.

**Status: IMPLEMENTED — pending `mix deps.get` and test run inside Nix devshell.**

---

## What Was Changed

### Step 1 — `mix.exs` ✅
Added `{:mox, "~> 1.0", only: :test}` to deps.

### Step 2 — Behaviour modules ✅

**`lib/pg2une/anytune_client.ex`**
Defines `Pg2une.AnytuneClient` behaviour with callbacks matching the `Anytune.*` functions used by PeriodicAnalyzer:
- `usl/3`
- `edivisive/3`
- `forecast/3`
- `query/2`

**`lib/pg2une/fact_store_client.ex`**
Defines `Pg2une.FactStoreClient` behaviour with callbacks matching the `Anytune.FactStore.*` functions used by PeriodicAnalyzer:
- `assert_fact/2`
- `retract_fact/2`
- `replace_facts/4`
- `query/2`

### Step 3 — `lib/pg2une/metrics_bucketer.ex` ✅
Extracted `bucket_to_15min/1` from `PeriodicAnalyzer` (was private) into a standalone public module `Pg2une.MetricsBucketer`. This makes the bucketing logic directly unit-testable without touching the GenServer. `PeriodicAnalyzer.run_prophet/0` now delegates to `Pg2une.MetricsBucketer.bucket_to_15min/1`.

### Step 4 — `test/support/mocks.ex` ✅
Declares the two Mox mocks (compiled into the test environment via `elixirc_paths(:test)`):
```elixir
Mox.defmock(Pg2une.MockAnytuneClient, for: Pg2une.AnytuneClient)
Mox.defmock(Pg2une.MockFactStoreClient, for: Pg2une.FactStoreClient)
```

### Step 5 — `config/test.exs` ✅
Added:
```elixir
config :pg2une,
  anytune_client: Pg2une.MockAnytuneClient,
  fact_store_client: Pg2une.MockFactStoreClient
```

### Step 6 — `lib/pg2une/periodic_analyzer.ex` ✅
- Added two compile-time module attributes at the top:
  ```elixir
  @anytune Application.compile_env(:pg2une, :anytune_client, Anytune)
  @fact_store Application.compile_env(:pg2une, :fact_store_client, Anytune.FactStore)
  ```
- Replaced all `Anytune.edivisive/usl/forecast/query` calls with `@anytune.*`
- Replaced all `Anytune.FactStore.*` calls with `@fact_store.*`
- Changed `defp run_edivisive`, `defp run_usl`, `defp run_prophet` to `def` with `@doc false`
- Removed the private `bucket_to_15min/1` (now in `MetricsBucketer`)

In production the defaults (`Anytune` and `Anytune.FactStore`) are used unchanged. In test, the Mox mocks are injected via config.

### Step 7 — `test/pg2une/periodic_analyzer_test.exs` ✅
Rewritten with three test groups:

**`MetricsBucketer.bucket_to_15min/1`** — 5 pure unit tests (no DB, no Mox):
- empty input
- single snapshot in its own bucket
- averaging within same 15-min window
- separate buckets across window boundary
- ascending sort order
- nil field handling (zero substitution)

**`run_edivisive/1`** — 4 Mox pipeline tests (Ecto sandbox + Mox):
- skip when < 20 snapshots (no mock expectations → any Anytune call would fail the test)
- assert change point fact when significant changes detected
- retract stale facts when no significant changes
- tolerate edivisive errors and continue with other metrics

**`run_usl/1`** — 3 Mox pipeline tests (Ecto sandbox + Mox):
- skip when < 5 snapshots
- update `usl_params` and `last_usl_deviation` on success; verify `replace_facts` called with correct deviation
- return unchanged state when fit fails

**Confidence calculation** — 5 tests carried over from original file (no DB or Mox, call `Anytune.Detection.Confidence.calculate/1` directly).

---

## To Complete

Run inside the Nix devshell:

```bash
nix develop -c mix deps.get
nix develop -c mix test test/pg2une/periodic_analyzer_test.exs
```

If `mix test` fails because the Ecto sandbox DB doesn't have the `system_snapshots` table (e.g. migrations haven't been run in test env yet):

```bash
nix develop -c mix ecto.create --quiet
nix develop -c mix ecto.migrate --quiet
nix develop -c mix test
```

---

## Architecture Notes

- **No mock for `MetricsStore`** — the pipeline tests seed real rows into the Ecto sandbox DB and let `MetricsStore.recent_system_metrics/1` query them normally. This keeps the test realistic while still mocking the expensive Python-backed Anytune calls.
- **`recalculate_confidence` is called inside `run_edivisive` and `run_usl`** — tests stub `MockAnytuneClient.query` (returns `[]`) and `MockFactStoreClient.replace_facts` (returns `:ok`) to satisfy these internal calls without asserting on them.
- **`@anytune` / `@fact_store` are resolved at compile time** via `Application.compile_env/3`. If the config key is absent (e.g. in prod where it is intentionally not set), the real modules are used as defaults.
