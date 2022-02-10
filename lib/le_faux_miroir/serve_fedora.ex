defmodule ServeFedora do
  require Logger
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
        case Mint.HTTP.connect(x.scheme, x.address, x.port, timeout: 0.5, mode: :passive) do
          {:ok, download_conn} ->
            case maybe_download(conn, download_conn, path) do
              :ok ->
                true
              _ -> false
            end
          {:error, %Mint.TransportError{}} ->
            Logger.info("Cannot connect to #{x.address}")
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
    cache_directory = "/home/goneri/tmp/my-cache"
    final_path = cache_directory <> path
    temp_path = cache_directory <> path <> ".temp" # TODO UNSAFE

    {:ok, fd} = File.open(temp_path, [:write, :binary])
    file_writer = fn(moar_content, expected_size) ->
      :ok = IO.binwrite fd, moar_content
      {:ok, cur} = :file.position(fd, {:cur, 0})
      if cur == expected_size do
        :ok = File.close(fd)
        Logger.info("Final file: #{final_path}")
        :ok = File.rename(temp_path, final_path)
      end
    end

    {:ok, download_conn, request_ref} = Mint.HTTP.request(download_conn, "GET", "/fedora/#{path}", [], nil)
    get_chunk(conn, download_conn, file_writer)
  end

  def handle_message({:ok, %Plug.Conn{state: :unset} = conn, download_conn}, file_writer, {:status, request_ref, status_code = 200}) do
    Logger.info("status code: #{status_code}")
    {:ok, conn, download_conn}
  end

  def handle_message({:ok, %Plug.Conn{state: :unset} = conn, download_conn}, file_writer, {:status, request_ref, status_code = 404}) do
    Mint.HTTP.close(download_conn)
    {:notFound, conn, download_conn}
  end

  def handle_message({:ok, %Plug.Conn{state: :unset} = conn, download_conn}, file_writer, {:headers, request_ref, headers}) do
    conn = Plug.Conn.prepend_resp_headers(conn, headers)
    conn = Plug.Conn.send_chunked(conn, 200)
    {:ok, conn, download_conn}
  end

  def handle_message({:ok, %Plug.Conn{} = conn, download_conn}, file_writer, {:ok, download_conn, responses}) do
    {:ok, conn, download_conn}
  end

  @doc """
  resp_headers has the following format:
  [
  {"date", "Thu, 10 Feb 2022 01:50:17 GMT"},
  {"server", "Apache"},
  {"last-modified", "Sat, 25 Dec 2021 00:21:48 GMT"},
  {"accept-ranges", "bytes"},
  {"content-length", "6244442"},
  {"connection", "close"},
  {"content-type", "application/x-redhat-package-manager"},
  {"cache-control", "max-age=0, private, must-revalidate"}
  ]
  """
  def handle_message({:ok, %Plug.Conn{state: :chunked} = conn, download_conn}, file_writer, {:data, request_ref, binary}) do
    file_writer.(binary, content_lenght(conn))
    {:ok, conn} = Plug.Conn.chunk(conn, binary)
    {:ok, conn, download_conn}
  end

  @doc """
  We actually never reach this step because the client will disconnect before
  and trigger the destruction of the process.
  """
  def handle_message({:ok, conn, download_conn}, file_writer, {:done, request_ref}) do
    Mint.HTTP.close(download_conn)
    {:done, conn, download_conn}
  end

  def content_lenght(%Plug.Conn{state: :chunked, resp_headers: resp_headers} = conn) do
    resp_headers
    |>Enum.find(fn (x) -> elem(x, 0) == "content-length" end)
    |>elem(1)
    |>String.to_integer
  end

  def handle_message({:notFound, _, _}, _) do
    {:notFound, nil, nil}
  end

  def handle_responses(conn, download_conn, file_writer, responses) do
    status = nil
    acc = {:ok, conn, download_conn}
    Enum.reduce(responses, acc, &handle_message(&2, file_writer, &1))
  end

  def get_chunk(conn, download_conn, file_writer) do
    {:ok, download_conn, responses} = Mint.HTTP.recv(download_conn, 0, 1000)
    case handle_responses(conn, download_conn, file_writer, responses) do
      {:ok, %Plug.Conn{state: :chunked} = conn, download_conn} ->
        {:ok} = get_chunk(conn, download_conn, file_writer)
      {:notFound, nil, nil} ->
        :notFound
    end
  end
end
