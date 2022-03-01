defmodule QueryPath do
  defstruct remote: nil, local: nil, local_tmp: nil
end

defmodule ServeFedora do
  require Logger
  import Plug.Conn

  def init(options) do
    # initialize options
    options
  end

  def construct_path(%{path_info: ["linux" | path_info]}) do
    Logger.info(path_info)

    remote_path =
      Enum.filter(path_info, fn x -> String.match?(x, ~r/^[A-Za-z\d][\d~A-Za-z_\.-]*$/) end)
      |> Enum.join("/")

    cache_directory = "/home/goneri/tmp/my-cache"

    local_path = "#{cache_directory}/#{remote_path}"

    prefix = for _ <- 1..20, into: "", do: <<Enum.random('0123456789abcdef')>>
    local_tmp_path = local_path <> prefix <> ".tmp"
    File.mkdir_p!(Path.dirname(local_path))

    Logger.info("Asking #{remote_path}")
    %QueryPath{remote: remote_path, local: local_path, local_tmp: local_tmp_path}
  end

  def find_remote_mirror(conn, path) do
    mirrors = [
      %{scheme: :http, address: "fedora.mirror.iweb.com", port: 80, base_dir: "/linux"},
      %{scheme: :http, address: "some-bad-mirror", port: 80, base_dir: "/"},
      %{scheme: :http, address: "mirror.facebook.net", port: 80, base_dir: "/fedora"},
      %{scheme: :http, address: "mirror.facebook.net", port: 80, base_dir: "/nowhere"},
      %{scheme: :https, address: "mirror.dst.ca", port: 443, base_dir: "/fedora"}
    ]

    mirror_used =
      Enum.find(
        mirrors,
        nil,
        fn x ->
          case Mint.HTTP.connect(x.scheme, x.address, x.port, timeout: 0.5, mode: :passive) do
            {:ok, download_conn} ->
              case fetch_and_send(conn, download_conn, x.base_dir, path) do
                :ok ->
                  Logger.info("File found on #{x.address}")
                  true

                _ ->
                  false
              end

            {:error, %Mint.TransportError{}} ->
              Logger.info("Cannot connect to #{x.address}")
              false
          end
        end
      )

    # NOTE: We never reach this part if everything went ok because
    # Plug will kill the process as soon as the data have been to the
    # client.
    case mirror_used do
      nil ->
        conn
        |> send_resp(404, "ahah lol!")
        |> halt

      mirror ->
        IO.inspect(mirror)
    end
  end

  def call(conn, _opts) do
    path = construct_path(conn)

    case File.stat(path.local) do
      {:ok, %File.Stat{ctime: ctime}} ->
        datetime = NaiveDateTime.from_erl!(ctime) |> DateTime.from_naive!("Etc/UTC")
        max_age = DateTime.add(datetime, 3600, :second)

        case Timex.compare(max_age, Timex.now()) do
          1 ->
            Logger.info("Send file #{path.local}")
            Plug.Conn.send_file(conn, 200, path.local)

          -1 ->
            find_remote_mirror(conn, path)
        end

      {:error, reason} ->
        Logger.info("Cannot find requested file in the local cache: #{reason}")
        find_remote_mirror(conn, path)
    end
  end

  def fetch_and_send(conn, download_conn, base_dir, path) do
    Logger.info("Openining #{path.local_tmp}")
    {:ok, fd} = File.open(path.local_tmp, [:write, :binary])

    file_writer = fn moar_content, expected_size ->
      :ok = IO.binwrite(fd, moar_content)
      {:ok, cur} = :file.position(fd, {:cur, 0})

      if cur == expected_size do
        :ok = File.close(fd)
        Logger.info("Final file: #{path.local}")
        :ok = File.rename(path.local_tmp, path.local)
      end
    end

    Logger.info("GET #{base_dir}/#{path.remote}")

    {:ok, download_conn, _request_ref} =
      Mint.HTTP.request(download_conn, "GET", "#{base_dir}/#{path.remote}", [], nil)

    get_chunk(conn, download_conn, file_writer)
  end

  def handle_message(
        {:ok, %Plug.Conn{} = conn, download_conn},
        _file_writer,
        {:done, _}
      ) do
    Logger.info("Done!")
    {:ok, conn, download_conn}
  end

  def handle_message(
        {:ok, %Plug.Conn{state: :unset} = conn, download_conn},
        _file_writer,
        {:status, _request_ref, status_code = 200}
      ) do
    Logger.info("status code: #{status_code}")
    {:ok, conn, download_conn}
  end

  def handle_message(
        {:ok, %Plug.Conn{state: :unset} = conn, download_conn},
        _file_writer,
        {:status, _request_ref, _status_code = 404}
      ) do
    Mint.HTTP.close(download_conn)
    {:notFound, conn, download_conn}
  end

  def handle_message(
        {:ok, %Plug.Conn{state: :unset} = conn, download_conn},
        _file_writer,
        {:headers, _request_ref, headers}
      ) do
    conn = Plug.Conn.prepend_resp_headers(conn, headers)
    conn = Plug.Conn.send_chunked(conn, 200)
    {:ok, conn, download_conn}
  end

  def handle_message(
        {:ok, %Plug.Conn{} = conn, download_conn},
        _file_writer,
        {:ok, download_conn, _responses}
      ) do
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
  def handle_message(
        {:ok, %Plug.Conn{state: :chunked} = conn, download_conn},
        file_writer,
        {:data, _request_ref, binary}
      ) do
    file_writer.(binary, content_lenght(conn))
    {:ok, conn} = Plug.Conn.chunk(conn, binary)
    {:ok, conn, download_conn}
  end

  def handle_message(
        {:done, %Plug.Conn{state: :unset} = conn, download_conn},
        _file_writer,
        _
      ) do
    Mint.HTTP.close(download_conn)
    {:done, conn, nil}
  end

  def handle_message(
        {:done, %Plug.Conn{state: :closed} = conn, download_conn},
        _file_writer,
        _
      ) do
    Mint.HTTP.close(download_conn)
    {:done, conn, nil}
  end

  def handle_message({:notFound, _conn, _}, _, _) do
    Logger.info("File not found on mirror.")
    {:notFound, nil, nil}
  end

  def content_lenght(%Plug.Conn{state: :chunked, resp_headers: resp_headers} = _conn) do
    resp_headers
    |> Enum.find(fn x -> elem(x, 0) == "content-length" end)
    |> elem(1)
    |> String.to_integer()
  end

  def handle_responses(conn, download_conn, file_writer, responses) do
    acc = {:ok, conn, download_conn}
    Enum.reduce(responses, acc, &handle_message(&2, file_writer, &1))
  end

  def get_chunk(conn, download_conn, file_writer) do
    case Mint.HTTP.recv(download_conn, 0, 1000) do
      {:ok, download_conn, responses} ->
        case handle_responses(conn, download_conn, file_writer, responses) do
          {:ok, %Plug.Conn{state: :chunked} = conn, download_conn} ->
            {:ok} = get_chunk(conn, download_conn, file_writer)

          {:notFound, _, _} ->
            :skip_this_mirror
        end

      {:error, _, %Mint.TransportError{reason: :timeout}} ->
        :skip_this_mirror
    end
  end
end
