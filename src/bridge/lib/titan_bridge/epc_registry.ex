defmodule TitanBridge.EpcRegistry do
  @moduledoc """
  Local EPC tag registry — tracks which codes have been used/reserved.

  Table: lce_epc_registry (epc, source, status, timestamps)
  Uses ON CONFLICT upsert — same EPC can be re-registered with new status.
  """
  alias TitanBridge.Repo
  alias TitanBridge.Cache.EpcRegistry, as: EpcRecord

  def register(epc, source \\ "bridge", status \\ "reserved") when is_binary(epc) do
    Repo.insert(%EpcRecord{epc: epc, source: source, status: status},
      on_conflict: {:replace, [:source, :status, :updated_at]},
      conflict_target: :epc
    )
  end

  def exists?(epc) when is_binary(epc) do
    Repo.get(EpcRecord, epc) != nil
  end
end
