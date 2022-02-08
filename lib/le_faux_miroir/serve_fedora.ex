defmodule ServeFedora do
  import Plug.Conn

  def init(options) do
    # initialize options
    options
  end

  def sanitized_path(%{path_info: ["linux" | path_info]}) do
    path = Enum.filter(path_info, fn(x) -> String.match?(x, ~r/^[A-Za-z\d][\dA-Za-z_\.-]*$/) end)
    |> Enum.join("/")
    "linux/" <> path
  end

  def call(conn, _opts) do
    path = sanitized_path(conn)
    mirrors = [
      %{scheme: :http, address: "some-bad-mirror", port: 80},
      %{scheme: :http, address: "mirror.facebook.net", port: 80}
    ]
    mirror_used = Enum.find(
      mirrors,
      nil,
      fn (x) ->
        IO.inspect(x)
        case Mint.HTTP.connect(x.scheme, x.address, x.port, timeout: 0.5) do
          {:ok, download_conn} ->
            case maybe_download(conn, download_conn, path) do
              :ok ->
                true
              _ -> false
            end
          {:error, %Mint.TransportError{}} ->
            IO.puts("Cannot connect to #{x.address}")
            false
        end
      end
    )
    case mirror_used do
      nil -> conn
      |> send_resp(404, "ahah lol!")
      |> halt
      mirror ->
        IO.inspect(mirror)
    end
  end

  def maybe_download(conn, download_conn, path) do
    # {:ok, download_conn} = Mint.HTTP.connect(:http, "mirror.facebook.net", 80)
    IO.puts "/fedora/#{path}"

    {:ok, download_conn, request_ref} = Mint.HTTP.request(download_conn, "GET", "/fedora/#{path}", [], nil)

    get_chunk(conn, download_conn)
  end

  def handle_message({:ok, %Plug.Conn{state: :unset} = conn, download_conn}, {:status, request_ref, status_code = 200}) do
    IO.puts("status code: #{status_code}")
    IO.inspect download_conn
    {:ok, conn, download_conn}
  end

  def handle_message({:ok, %Plug.Conn{state: :unset} = conn, download_conn}, {:status, request_ref, status_code = 404}) do
    IO.puts("status code: #{status_code}")
    Mint.HTTP.close(download_conn)
    {:notFound, conn, download_conn}
  end

  def handle_message({:ok, %Plug.Conn{state: :unset} = conn, download_conn}, {:headers, request_ref, headers}) do
    IO.inspect(request_ref)
    IO.inspect(download_conn)
    conn = Plug.Conn.prepend_resp_headers(conn, headers)
    conn = Plug.Conn.send_chunked(conn, 200)
    {:ok, conn, download_conn}
  end

  def handle_message({:ok, %Plug.Conn{} = conn, download_conn}, {:ok, download_conn, responses}) do
    {:ok, conn, download_conn}
  end

  def handle_message({:ok, %Plug.Conn{state: :chunked} = conn, download_conn}, {:data, request_ref, binary}) do
    {:ok, conn} = Plug.Conn.chunk(conn, binary)
    {:ok, conn, download_conn}
  end

  def handle_message({:ok, conn, download_conn}, {:done, request_ref}) do
    Mint.HTTP.close(download_conn)
    {:done, conn, download_conn}
  end

  def handle_message({:notFound, _, _}, _) do
    {:notFound, nil, nil}
  end

  def handle_message(:unknown) do
    IO.puts("Whoa")
  end

  def handle_responses(conn, download_conn, responses) do
    status = nil
    acc = {:ok, conn, download_conn}
    Enum.reduce(responses, acc, &handle_message(&2, &1))
  end

  def get_chunk(conn, download_conn) do
    receive do
      message ->
        case Mint.HTTP.stream(download_conn, message) do
          :unknown ->
            IO.inspect(message)
            get_chunk(conn, download_conn)
          {:ok, download_conn, responses} ->
            case handle_responses(conn, download_conn, responses) do
              {:ok, %Plug.Conn{state: :chunked} = conn, download_conn} ->
                get_chunk(conn, download_conn)
              {:notFound, nil, nil} ->
                :notFound
            end
        end
    end
  end
end
