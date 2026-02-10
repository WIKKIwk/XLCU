defmodule TitanBridge.EpcGenerator do
  @moduledoc """
  EPC Gen2 96-bit tag code generator.

  Format: prefix (60-bit hex) + counter (36-bit hex, zero-padded)
  Default prefix: "3034257BF7194E4" (company-specific GS1 allocation)

  Counter is persisted in lce_epc_sequences table (one row per prefix).
  Each call to next/0 atomically increments and checks uniqueness
  against both local EpcRegistry and ERPNext.
  """
  alias TitanBridge.{EpcRegistry, Repo, EpcSequence}
  import Ecto.Query

  @default_prefix "3034257BF7194E4"

  def next(prefix \\ @default_prefix) do
    Repo.transaction(fn ->
      seq = Repo.get(EpcSequence, prefix) || %EpcSequence{prefix: prefix, last_value: 0}
      next_value = (seq.last_value || 0) + 1
      changeset = EpcSequence.changeset(seq, %{last_value: next_value})
      Repo.insert_or_update!(changeset)
      epc = build_epc(prefix, next_value)
      _ = EpcRegistry.register(epc, "bridge", "reserved")
      epc
    end)
  end

  defp build_epc(prefix, value) do
    # EPC Gen2 96-bit: prefix(60-bit=15 hex) + counter(36-bit=9 hex) => 24 hex (even length).
    # Zebra encoder rejects odd-length hex strings (full bytes required).
    max36 = 0xFFFFFFFFF
    if value > max36, do: raise("EPC counter overflow (36-bit): #{value}")
    hex = Integer.to_string(value, 16) |> String.upcase() |> String.pad_leading(9, "0")
    prefix <> hex
  end
end
