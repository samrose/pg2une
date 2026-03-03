defmodule Pg2une.AnytuneClient do
  @moduledoc "Behaviour for Anytune analytics calls used by PeriodicAnalyzer."

  @callback usl(name :: atom(), action :: atom(), params :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback edivisive(name :: atom(), metric :: String.t(), values :: list()) ::
              {:ok, map()} | {:error, term()}

  @callback forecast(name :: atom(), metric :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback query(name :: atom(), pattern :: tuple()) :: list()
end
