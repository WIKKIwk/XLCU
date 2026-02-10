ExUnit.start()

# Tests should not rely on external OS child apps (zebra/rfid). CI sets
# LCE_CHILDREN_MODE=off, but keep this as a safe default for local runs too.
System.put_env("LCE_CHILDREN_MODE", System.get_env("LCE_CHILDREN_MODE") || "off")

Ecto.Adapters.SQL.Sandbox.mode(TitanBridge.Repo, :manual)

