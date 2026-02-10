defmodule TitanBridge.EpcGeneratorTest do
  use ExUnit.Case, async: false

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TitanBridge.Repo)
  end

  test "next/0 generates a 96-bit (24 hex chars) EPC with even-length hex" do
    {:ok, epc} = TitanBridge.EpcGenerator.next()
    assert is_binary(epc)
    assert String.length(epc) == 24
    assert rem(String.length(epc), 2) == 0
  end
end
