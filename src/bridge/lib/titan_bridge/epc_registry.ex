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

  @doc """
  Faqat yangi EPC ni yozadi. Dublikat bo'lsa hech narsa qilmaydi.
  Soniyasiga 20+ marta bir xil EPC kelishi mumkin — faqat birinchisi yoziladi.
  Qaytaradi:
    {:ok, :new}    — yangi EPC, birinchi marta ko'rildi
    {:ok, :exists} — allaqachon mavjud, skip
  """
  def register_once(epc, source \\ "rfid") when is_binary(epc) do
    if exists?(epc) do
      {:ok, :exists}
    else
      case Repo.insert(
        %EpcRecord{epc: epc, source: source, status: "scanned"},
        on_conflict: :nothing,
        conflict_target: :epc
      ) do
        {:ok, _} -> {:ok, :new}
        _ -> {:ok, :exists}
      end
    end
  end

  def mark_submitted(epc) when is_binary(epc) do
    register(epc, "rfid", "submitted")
  end

  def exists?(epc) when is_binary(epc) do
    Repo.get(EpcRecord, epc) != nil
  end
end
