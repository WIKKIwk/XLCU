defmodule TitanBridge.Encrypted.Binary do
  @moduledoc """
  Ecto type that transparently encrypts/decrypts binary data via Vault.

  Usage in schema:
      field :erp_token, TitanBridge.Encrypted.Binary

  DB column must be `:binary` (bytea). See migration 20260207080000.
  """
  use Cloak.Ecto.Binary, vault: TitanBridge.Vault
end
