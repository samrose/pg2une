defmodule Pg2une.MetricsBucketer do
  @moduledoc "Groups minute-level snapshots into 15-minute buckets for Prophet forecasting."

  @doc """
  Aggregates snapshots into 15-minute time buckets by averaging field values.

  Returns buckets sorted ascending by snapshot_time. Nil field values are
  treated as zero when averaging.
  """
  def bucket_to_15min(snapshots) do
    snapshots
    |> Enum.group_by(fn s ->
      unix = DateTime.to_unix(s.snapshot_time)
      DateTime.from_unix!(div(unix, 900) * 900)
    end)
    |> Enum.map(fn {bucket_time, group} ->
      count = length(group)
      avg = fn field -> Enum.sum(Enum.map(group, &((Map.get(&1, field) || 0) * 1.0))) / count end
      %{
        snapshot_time: bucket_time,
        tps: avg.(:tps),
        latency_p99: avg.(:latency_p99),
        buffer_hit_ratio: avg.(:buffer_hit_ratio),
        conn_active: round(avg.(:conn_active))
      }
    end)
    |> Enum.sort_by(& &1.snapshot_time, DateTime)
  end
end
