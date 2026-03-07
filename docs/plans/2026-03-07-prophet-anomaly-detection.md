# Prophet Anomaly Detection Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Wire Prophet's forecast intervals into actual anomaly detection so the `seasonal_unexpected` confidence signal fires correctly.

**Architecture:** In `run_prophet`, after getting the forecast, compare the most recent actual metric value against the first forecast period's `[yhat_lower, yhat_upper]`. Assert `prophet_anomaly(metric)` when actual is outside the interval, retract when inside. Fix `recalculate_confidence` to query `prophet_anomaly` facts instead of the non-existent `seasonal_expected` facts. Add one Datalog rule to expose the signal.

**Tech Stack:** Elixir/OTP, Mox for test doubles, ExUnit + Ecto SQL Sandbox, `nix develop -c mix test` to run tests.

---

### Task 1: Add `prophet_anomaly` fact helpers and `extract_metric_value/2`

**Files:**
- Modify: `lib/pg2une/periodic_analyzer.ex`

**Step 1: Read the file to understand current helper layout**

Open `lib/pg2une/periodic_analyzer.ex` and find the `# ── Fact Store Helpers ───` section (around line 259) and the `# ── Helpers ──` section (around line 281).

**Step 2: Add `assert_prophet_anomaly/1` and `retract_prophet_anomaly/1` after `assert_prophet_forecast/4`**

In the `# ── Fact Store Helpers ───` section, after the existing `assert_prophet_forecast/4` function, add:

```elixir
defp assert_prophet_anomaly(metric) do
  @fact_store.replace_facts(:pg2une_store, :"prophet_anomaly_#{metric}", 1, [{:prophet_anomaly, [metric]}])
end

defp retract_prophet_anomaly(metric) do
  @fact_store.replace_facts(:pg2une_store, :"prophet_anomaly_#{metric}", 1, [])
end
```

**Step 3: Add `extract_metric_value/2` (singular) after the existing `extract_metric_values/2` (plural) functions**

In the `# ── Helpers ──` section, after the four `extract_metric_values/2` clauses, add:

```elixir
defp extract_metric_value(snapshot, "tps"), do: (snapshot.tps || 0) / 1.0
defp extract_metric_value(snapshot, "latency_p99"), do: (snapshot.latency_p99 || 0) / 1.0
defp extract_metric_value(snapshot, "buffer_hit_ratio"), do: (snapshot.buffer_hit_ratio || 0) / 1.0
defp extract_metric_value(_snapshot, _), do: 0.0
```

**Step 4: Verify the file compiles**

```bash
nix develop -c mix compile --no-deps-check 2>&1
```

Expected: no errors.

**Step 5: Commit**

```bash
git add lib/pg2une/periodic_analyzer.ex
git commit -m "feat: add prophet_anomaly fact helpers and extract_metric_value/2"
```

---

### Task 2: Update `run_prophet` to assert/retract anomaly facts

**Files:**
- Modify: `lib/pg2une/periodic_analyzer.ex`

**Step 1: Find `run_prophet/0`**

It starts around line 184. The inner block after `assert_prophet_forecast(metric, yhat, lower, upper)` currently does nothing else.

**Step 2: Add the actual-vs-predicted comparison**

Replace the entire `run_prophet/0` function body. The key change is:
1. Capture `latest = List.last(buckets)` before the `Enum.each`
2. After `assert_prophet_forecast`, extract the actual value and compare against `[lower, upper]`

The updated `run_prophet/0`:

```elixir
@doc false
def run_prophet do
  snapshots = Pg2une.MetricsStore.recent_system_metrics(10_080)
  buckets = Pg2une.MetricsBucketer.bucket_to_15min(snapshots)

  if length(buckets) < @prophet_min_buckets do
    Logger.debug("PeriodicAnalyzer: Prophet skipped, only #{length(buckets)} 15-min buckets (need #{@prophet_min_buckets})")
    :ok
  else
    latest = List.last(buckets)

    Enum.each(@metrics_to_analyze, fn metric ->
      timestamps = Enum.map(buckets, fn b -> DateTime.to_iso8601(b.snapshot_time) end)
      values = extract_metric_values(buckets, metric)

      case @anytune.forecast(:pg2une, metric,
        timestamps: timestamps,
        values: values,
        periods: 96,
        freq: "15min"
      ) do
        {:ok, result} ->
          forecasts = result["forecast"] || []

          if forecasts != [] do
            next = List.first(forecasts)
            yhat = next["yhat"] || 0
            lower = next["yhat_lower"] || 0
            upper = next["yhat_upper"] || 0

            Logger.info("PeriodicAnalyzer: Prophet forecast for #{metric}: yhat=#{yhat}")
            assert_prophet_forecast(metric, yhat, lower, upper)

            actual = extract_metric_value(latest, metric)

            if actual < lower or actual > upper do
              Logger.info("PeriodicAnalyzer: Prophet anomaly for #{metric}: actual=#{actual} outside [#{lower}, #{upper}]")
              assert_prophet_anomaly(metric)
            else
              retract_prophet_anomaly(metric)
            end
          end

        {:error, reason} ->
          Logger.warning("PeriodicAnalyzer: Prophet failed for #{metric}: #{inspect(reason)}")
      end
    end)
  end
end
```

**Step 3: Compile**

```bash
nix develop -c mix compile --no-deps-check 2>&1
```

Expected: no errors.

**Step 4: Commit**

```bash
git add lib/pg2une/periodic_analyzer.ex
git commit -m "feat: compare actuals against prophet forecast interval, assert prophet_anomaly"
```

---

### Task 3: Fix `recalculate_confidence` to use `prophet_anomaly` facts

**Files:**
- Modify: `lib/pg2une/periodic_analyzer.ex`

**Step 1: Find `recalculate_confidence/1`**

Around line 224. There are three lines to replace:

```elixir
# THESE THREE LINES ARE THE BUG:
seasonal_facts = @anytune.query(:pg2une, {:seasonal_expected, [:_, :_]})
metric_values = @anytune.query(:pg2une, {:metric_value, [:_, :_]})
seasonal_unexpected = check_seasonal_unexpected(metric_values, seasonal_facts)
```

**Step 2: Replace those three lines with**

```elixir
prophet_anomaly_facts = @fact_store.query(:pg2une_store, {:prophet_anomaly, [:_]})
seasonal_unexpected = prophet_anomaly_facts != []
```

**Step 3: Delete `check_seasonal_unexpected/2`**

Find and delete the entire private function `check_seasonal_unexpected/2` (around line 288). It is now dead code and will cause a compiler warning.

**Step 4: Compile**

```bash
nix develop -c mix compile --no-deps-check 2>&1
```

Expected: no errors, no unused function warnings.

**Step 5: Commit**

```bash
git add lib/pg2une/periodic_analyzer.ex
git commit -m "fix: wire recalculate_confidence to prophet_anomaly facts, remove dead check_seasonal_unexpected"
```

---

### Task 4: Add Datalog rule for `prophet_anomaly_detected`

**Files:**
- Modify: `priv/rules/pg2une.dl`

**Step 1: Open the file**

It's at `priv/rules/pg2une.dl`. It currently ends with `usl_warning/0`.

**Step 2: Append at the end**

```datalog
% Prophet anomaly signal — metric's actual value outside its predicted interval
prophet_anomaly_detected() :- prophet_anomaly(_).
```

**Step 3: Compile**

```bash
nix develop -c mix compile --no-deps-check 2>&1
```

Expected: no errors.

**Step 4: Commit**

```bash
git add priv/rules/pg2une.dl
git commit -m "feat: add prophet_anomaly_detected datalog rule"
```

---

### Task 5: Write failing tests for `run_prophet`

**Files:**
- Modify: `test/pg2une/periodic_analyzer_test.exs`

**Step 1: Read the existing test file**

Open `test/pg2une/periodic_analyzer_test.exs`. Find the end of the `run_usl` describe block (around line 213). Add the new describe block after it, before `# ── Confidence calculation`.

**Step 2: Add test helpers**

At the bottom of the file, inside the `# ── Helpers ──` comment, add a second insert helper for 15-minute-spaced snapshots (needed because Prophet needs 192+ distinct 15-min buckets):

```elixir
defp insert_system_snapshots_15min(count) do
  base = DateTime.utc_now() |> DateTime.add(-(count * 15 * 60), :second)

  for i <- 0..(count - 1) do
    ts = DateTime.add(base, i * 15 * 60, :second)

    %Pg2une.Schemas.SystemSnapshot{}
    |> Pg2une.Schemas.SystemSnapshot.changeset(%{
      "snapshot_time" => ts,
      "tps" => 800.0,
      "latency_p99" => 10.0,
      "buffer_hit_ratio" => 0.95,
      "conn_active" => 10
    })
    |> Pg2une.Repo.insert!()
  end
end
```

**Step 3: Add the `run_prophet` describe block**

Add this block after the `run_usl` describe block:

```elixir
# ── run_prophet/0 ────────────────────────────────────────────────────

describe "run_prophet/0" do
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Pg2une.Repo)
    :ok
  end

  test "skips when fewer than 192 15-min buckets available" do
    # Only insert 10 snapshots (< 192 buckets needed)
    insert_system_snapshots(10)
    # No mock expectations — any call would fail the test
    assert PeriodicAnalyzer.run_prophet() == :ok
  end

  test "asserts prophet_anomaly when actual is below yhat_lower" do
    insert_system_snapshots_15min(200)

    stub(Pg2une.MockAnytuneClient, :forecast, fn :pg2une, "latency_p99", _opts ->
      {:ok, %{"forecast" => [%{"yhat" => 10.0, "yhat_lower" => 8.0, "yhat_upper" => 12.0}]}}
    end)
    stub(Pg2une.MockAnytuneClient, :forecast, fn :pg2une, "buffer_hit_ratio", _opts ->
      {:ok, %{"forecast" => [%{"yhat" => 0.95, "yhat_lower" => 0.90, "yhat_upper" => 1.0}]}}
    end)
    stub(Pg2une.MockFactStoreClient, :assert_fact, fn :pg2une_store, _ -> :ok end)
    stub(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store, _key, _arity, _facts -> :ok end)

    # TPS actual is 800.0; forecast interval is [900.0, 1100.0] → anomaly
    expect(Pg2une.MockAnytuneClient, :forecast, fn :pg2une, "tps", _opts ->
      {:ok, %{"forecast" => [%{"yhat" => 1000.0, "yhat_lower" => 900.0, "yhat_upper" => 1100.0}]}}
    end)
    expect(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store,
                                                          :prophet_anomaly_tps, 1,
                                                          [{:prophet_anomaly, ["tps"]}] ->
      :ok
    end)

    PeriodicAnalyzer.run_prophet()
  end

  test "retracts prophet_anomaly when actual is within yhat bounds" do
    insert_system_snapshots_15min(200)

    stub(Pg2une.MockAnytuneClient, :forecast, fn :pg2une, "latency_p99", _opts ->
      {:ok, %{"forecast" => [%{"yhat" => 10.0, "yhat_lower" => 8.0, "yhat_upper" => 12.0}]}}
    end)
    stub(Pg2une.MockAnytuneClient, :forecast, fn :pg2une, "buffer_hit_ratio", _opts ->
      {:ok, %{"forecast" => [%{"yhat" => 0.95, "yhat_lower" => 0.90, "yhat_upper" => 1.0}]}}
    end)
    stub(Pg2une.MockFactStoreClient, :assert_fact, fn :pg2une_store, _ -> :ok end)

    # TPS actual is 800.0; forecast interval is [700.0, 900.0] → within bounds
    expect(Pg2une.MockAnytuneClient, :forecast, fn :pg2une, "tps", _opts ->
      {:ok, %{"forecast" => [%{"yhat" => 800.0, "yhat_lower" => 700.0, "yhat_upper" => 900.0}]}}
    end)
    # replace_facts called with empty list → retract
    expect(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store,
                                                          :prophet_anomaly_tps, 1,
                                                          [] ->
      :ok
    end)
    stub(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store, _key, _arity, _facts -> :ok end)

    PeriodicAnalyzer.run_prophet()
  end

  test "tolerates forecast errors without crashing" do
    insert_system_snapshots_15min(200)

    # All three metrics fail
    stub(Pg2une.MockAnytuneClient, :forecast, fn :pg2une, _metric, _opts ->
      {:error, :timeout}
    end)

    assert PeriodicAnalyzer.run_prophet() == :ok
  end
end
```

**Step 4: Run these new tests to confirm they fail** (because the implementation isn't done yet — we've already done it, so they should pass, but verify)

```bash
nix develop -c mix test test/pg2une/periodic_analyzer_test.exs --no-start 2>&1
```

Expected: all tests pass. If any fail, read the error and fix.

**Step 5: Commit**

```bash
git add test/pg2une/periodic_analyzer_test.exs
git commit -m "test: add run_prophet anomaly detection tests"
```

---

### Task 6: Write failing tests for `recalculate_confidence` with `prophet_anomaly`

**Files:**
- Modify: `test/pg2une/periodic_analyzer_test.exs`

**Step 1: Find the existing `confidence calculation` describe block**

Around line 216. There are existing tests covering cusum, usl, etc. Add a new test covering the prophet_anomaly path.

**Step 2: Add one test inside the existing `confidence calculation` describe block**

```elixir
test "seasonal_unexpected is true when prophet_anomaly facts exist" do
  # prophet_anomaly facts for tps exist
  signals = %{
    cusum_degradation_count: 0,
    usl_deviation: 0.0,
    otava_confirms: false,
    seasonal_unexpected: true
  }
  score = Anytune.Detection.Confidence.calculate(signals)
  # 0 + 0 + 0 + 0.10 = 0.10
  assert_in_delta score, 0.10, 0.001
end
```

**Step 3: Add a test for `run_edivisive` (confidence path) that verifies `prophet_anomaly` facts are queried**

Add a new describe block testing the `recalculate_confidence` integration. Since `recalculate_confidence` is private, we test it via `run_edivisive` (which calls it) and verify that `prophet_anomaly` facts correctly influence whether `high_confidence` is asserted:

```elixir
describe "recalculate_confidence picks up prophet_anomaly" do
  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Pg2une.Repo)
    :ok
  end

  test "asserts high_confidence when prophet_anomaly fact exists alongside cusum" do
    insert_system_snapshots(25)

    # CUSUM has 2 degradations (score: 0.30) + prophet anomaly (score: +0.10) = 0.40 → high_confidence
    expect(Pg2une.MockAnytuneClient, :edivisive, 3, fn :pg2une, _metric, _values ->
      {:ok, %{"change_points" => []}}
    end)
    stub(Pg2une.MockAnytuneClient, :query, fn :pg2une, {:cusum_degradation, [:_, :_]} ->
      [{:cusum_degradation, ["tps", 4.2]}, {:cusum_degradation, ["latency_p99", 3.8]}]
    end)
    # prophet_anomaly fact exists for tps
    stub(Pg2une.MockFactStoreClient, :query, fn :pg2une_store, {:prophet_anomaly, [:_]} ->
      [{:prophet_anomaly, ["tps"]}]
    end)
    stub(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store, _pred, _arity, _facts -> :ok end)

    # Expect high_confidence to be asserted (score >= 0.30)
    expect(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store, :high_confidence, 0,
                                                          [{:high_confidence, []}] ->
      :ok
    end)

    PeriodicAnalyzer.run_edivisive(initial_state())
  end

  test "does not assert high_confidence when no prophet_anomaly and no other signals" do
    insert_system_snapshots(25)

    expect(Pg2une.MockAnytuneClient, :edivisive, 3, fn :pg2une, _metric, _values ->
      {:ok, %{"change_points" => []}}
    end)
    stub(Pg2une.MockAnytuneClient, :query, fn :pg2une, {:cusum_degradation, [:_, :_]} -> [] end)
    stub(Pg2une.MockFactStoreClient, :query, fn :pg2une_store, {:prophet_anomaly, [:_]} -> [] end)

    # Expect high_confidence to be retracted (score < 0.30)
    expect(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store, :high_confidence, 0, [] ->
      :ok
    end)
    stub(Pg2une.MockFactStoreClient, :replace_facts, fn :pg2une_store, _pred, _arity, _facts -> :ok end)

    PeriodicAnalyzer.run_edivisive(initial_state())
  end
end
```

**Step 4: Run the full test suite**

```bash
nix develop -c mix test test/pg2une/periodic_analyzer_test.exs --no-start 2>&1
```

Expected: all tests pass.

**Step 5: Run the full suite to check nothing regressed**

```bash
nix develop -c mix test --no-start 2>&1
```

Expected: all tests pass.

**Step 6: Commit**

```bash
git add test/pg2une/periodic_analyzer_test.exs
git commit -m "test: verify recalculate_confidence uses prophet_anomaly facts for seasonal_unexpected"
```

---

### Task 7: Final verification

**Step 1: Run the full test suite one more time cleanly**

```bash
nix develop -c mix test 2>&1
```

Expected: all tests pass, no warnings.

**Step 2: Verify the Datalog rule file is syntactically correct**

```bash
nix develop -c mix compile 2>&1
```

Expected: clean.

**Step 3: Confirm the three bugs are gone**

Check:
1. `recalculate_confidence` no longer queries `seasonal_expected` — grep for it:
   ```bash
   grep -n "seasonal_expected" lib/pg2une/periodic_analyzer.ex
   ```
   Expected: no output.

2. `prophet_anomaly` facts are asserted in `run_prophet`:
   ```bash
   grep -n "prophet_anomaly" lib/pg2une/periodic_analyzer.ex
   ```
   Expected: lines for `assert_prophet_anomaly`, `retract_prophet_anomaly`, and the `if actual < lower` branch.

3. Datalog rule exists:
   ```bash
   grep -n "prophet_anomaly" priv/rules/pg2une.dl
   ```
   Expected: `prophet_anomaly_detected() :- prophet_anomaly(_).`

**Step 4: Final commit if any loose files**

```bash
git status
```

If clean, done. If not, commit any remaining changes.
