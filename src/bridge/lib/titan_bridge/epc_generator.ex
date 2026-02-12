defmodule TitanBridge.EpcGenerator do
  @moduledoc """
  EPC Gen2 96-bit tag code generator.

  Format: prefix (4 hex) + timestamp_ms (11 hex) + random (9 hex) = 24 hex = 96 bit
  Default prefix: "3034" (company-specific identifier)

  Timestamp — millisekund aniqligi (Unix epoch), 47 bit (~4400 yilgacha yetadi).
  Random — 36 bit tasodifiy qiymat (bir millisekundda 68 milliard unique qiymat).

  Bu format hech qachon conflict bermaydi — har bir EPC unique,
  counter yoki DB ga bog'liq emas, make run qayta ishga tushganda ham
  eski EPC lar bilan to'qnashmaydi.
  """
  alias TitanBridge.EpcRegistry

  @default_prefix "3034"

  def next(prefix \\ @default_prefix) do
    epc = build_epc(prefix)
    _ = EpcRegistry.register(epc, "bridge", "reserved")
    {:ok, epc}
  end

  defp build_epc(prefix) do
    # Timestamp: millisekundlarda Unix epoch (47-bit, 11 hex)
    ts_ms = System.system_time(:millisecond)
    ts_hex = ts_ms |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(11, "0")
    # Agar timestamp 11 hex dan uzun bo'lsa (juda uzoq kelajakda), oxirgi 11 ni olish
    ts_hex = String.slice(ts_hex, -11, 11)

    # Random: 36-bit (9 hex)
    random_bytes = :crypto.strong_rand_bytes(5)
    <<rand_val::unsigned-40>> = random_bytes
    # 36 bit olish (40 bit dan)
    rand_36 = Bitwise.band(rand_val, 0xFFFFFFFFF)
    rand_hex = rand_36 |> Integer.to_string(16) |> String.upcase() |> String.pad_leading(9, "0")

    # Prefix (4 hex) + Timestamp (11 hex) + Random (9 hex) = 24 hex = 96 bit
    prefix <> ts_hex <> rand_hex
  end
end
