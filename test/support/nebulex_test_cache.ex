defmodule Commanded.Middleware.Uniqueness.NebulexTestCache do
  use Nebulex.Cache,
    otp_app: :commanded_uniqueness_middleware,
    adapter: Nebulex.Adapters.Local
end
