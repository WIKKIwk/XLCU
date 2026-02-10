defmodule TitanBridge.Vault do
  @moduledoc """
  Cloak encryption vault — AES-256-GCM for database field encryption.

  Used by `TitanBridge.Encrypted.Binary` Ecto type to encrypt sensitive
  fields (erp_token, telegram_token) at rest in PostgreSQL.

  Key source:
  - Production: `CLOAK_KEY` env var (base64-encoded 32-byte key)
  - Development: random key generated on each start (data not portable)
  """
  use Cloak.Vault, otp_app: :titan_bridge

  @impl GenServer
  def init(config) do
    config =
      Keyword.put(config, :ciphers,
        default: {
          Cloak.Ciphers.AES.GCM,
          tag: "AES.GCM.V1", key: decode_env!("CLOAK_KEY"), iv_length: 12
        }
      )

    {:ok, config}
  end

  defp decode_env!(env_var) do
    case System.get_env(env_var) do
      nil ->
        if production?() do
          raise "#{env_var} environment variable is required in production"
        else
          :crypto.strong_rand_bytes(32)
        end

      "" ->
        :crypto.strong_rand_bytes(32)

      val ->
        Base.decode64!(val)
    end
  end

  defp production? do
    Application.get_env(:titan_bridge, :env) == :prod or
      System.get_env("MIX_ENV") == "prod"
  end
end
