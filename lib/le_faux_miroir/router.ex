defmodule MyRouter do
  use Plug.Router

  plug(:match)
  plug(:dispatch)

  get "/hello" do
    send_resp(conn, 200, "world")
  end

  forward("/fedora", to: ServeFedora)

  match _ do
    send_resp(conn, 404, "oops")
  end
end
