defmodule Pg2une.PeriodicAnalyzerTest do
  use ExUnit.Case

  test "confidence calculation with no signals returns low score" do
    signals = %{
      cusum_degradation_count: 0,
      usl_deviation: 0.0,
      otava_confirms: false,
      seasonal_unexpected: false
    }

    score = Anytune.Detection.Confidence.calculate(signals)
    assert score < 0.30
  end

  test "confidence calculation with cusum degradations" do
    signals = %{
      cusum_degradation_count: 2,
      usl_deviation: 0.0,
      otava_confirms: false,
      seasonal_unexpected: false
    }

    score = Anytune.Detection.Confidence.calculate(signals)
    # 2 * 0.15 = 0.30, should meet threshold
    assert score >= 0.30
  end

  test "confidence calculation with multiple signals" do
    signals = %{
      cusum_degradation_count: 1,
      usl_deviation: -0.20,
      otava_confirms: true,
      seasonal_unexpected: true
    }

    score = Anytune.Detection.Confidence.calculate(signals)
    # 0.15 + 0.15 + 0.15 + 0.10 = 0.55
    assert score >= 0.50
  end

  test "confidence calculation caps at 1.0" do
    signals = %{
      cusum_degradation_count: 10,
      usl_deviation: -0.50,
      otava_confirms: true,
      seasonal_unexpected: true
    }

    score = Anytune.Detection.Confidence.calculate(signals)
    assert score <= 1.0
  end

  test "usl_deviation above threshold does not contribute" do
    signals = %{
      cusum_degradation_count: 0,
      usl_deviation: 0.10,
      otava_confirms: false,
      seasonal_unexpected: false
    }

    score = Anytune.Detection.Confidence.calculate(signals)
    assert score == 0.0
  end
end
