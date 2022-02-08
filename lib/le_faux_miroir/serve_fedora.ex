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
    download(conn, path)
  end


  def download(conn, path) do
    {:ok, download_conn} = Mint.HTTP.connect(:http, "mirror.facebook.net", 80)
    IO.puts "/fedora/#{path}"
    {:ok, download_conn, request_ref} = Mint.HTTP.request(download_conn, "GET", "/fedora/#{path}", [], "")

    {%Plug.Conn{state: :chunked} = conn, download_conn} = get_chunk(conn, download_conn)
    conn
  end

  def handle_message({%Plug.Conn{state: :unset} = conn, download_conn}, {:status, request_ref, status_code = 200}) do
    IO.puts("status code: #{status_code}")
    IO.inspect download_conn
    {conn, download_conn}
  end

  def handle_message({%Plug.Conn{state: :unset} = conn, download_conn}, {:status, request_ref, status_code = 404}) do
    IO.puts("status code: #{status_code}")
    :notFound
  end
  
  def handle_message({%Plug.Conn{state: :unset} = conn, download_conn}, {:headers, request_ref, headers}) do
    conn = Plug.Conn.prepend_resp_headers(conn, headers)
    conn = Plug.Conn.send_chunked(conn, 200)
    {conn, download_conn}
  end

  def handle_message({%Plug.Conn{} = conn, download_conn}, {:ok, download_conn, responses}) do
    {conn, download_conn}
  end

  def handle_message({%Plug.Conn{state: :chunked} = conn, download_conn}, {:data, request_ref, binary}) do
    IO.puts("new chunk")
    {:ok, conn} = Plug.Conn.chunk(conn, binary)
    {conn, download_conn}
  end

  def handle_message({conn, download_conn}, {:done, request_ref}) do
    IO.puts("Done")
    Mint.HTTP.close(download_conn)
    {conn, download_conn}

  end
  def handle_message(:unknown) do
    IO.puts("Whoa")
  end
  
  def handle_responses(conn, download_conn, responses) do
    {%Plug.Conn{state: :chunked}, download_conn} = Enum.reduce(responses, {conn, download_conn}, &handle_message(&2, &1))
  end

  def get_chunk(conn, download_conn) do
    receive do
      message ->
        case Mint.HTTP.stream(download_conn, message) do
          :unknown ->
            IO.puts("unknown")
            get_chunk(conn, download_conn)
          {:ok, download_conn, responses} ->
            case handle_responses(conn, download_conn, responses) do
              {%Plug.Conn{state: :chunked} = conn, download_conn} ->
                get_chunk(conn, download_conn)
            end
        end
    end
  end
end
