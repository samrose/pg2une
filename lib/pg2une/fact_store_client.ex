defmodule Pg2une.FactStoreClient do
  @moduledoc "Behaviour for Anytune.FactStore calls used by PeriodicAnalyzer."

  @callback assert_fact(store :: atom(), fact :: tuple()) :: :ok

  @callback retract_fact(store :: atom(), fact :: tuple()) :: :ok

  @callback replace_facts(
              store :: atom(),
              predicate :: atom(),
              arity :: non_neg_integer(),
              new_facts :: list()
            ) :: :ok

  @callback query(store :: atom(), pattern :: tuple()) :: list()
end
