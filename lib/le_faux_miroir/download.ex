# defmodule Mix.Tasks.Hello do
#  @shortdoc ~S("Example mix task for showing hello world")
#  use Mix.Task
#  alias HTTPoison.{AsyncHeaders, AsyncRedirect, AsyncResponse, AsyncStatus, AsyncChunk, AysncEnd}
#  def run(_) do
#  download("#{URL}", "#{SAVE_TO_PATH}")
#  end
#  def download(url, path) do
#    HTTPoison.start()
#    {:ok, file} = File.open("path/filename", [:write, :exclusive])
#    with {:ok, %HTTPoison.AsyncResponse{id: ref}} <- HTTPoison.get(url, ["Accept": "application/octet-stream"],
#                  [follow_redirect: true, stream_to: self(), recv_timeout: 5 * 60 * 1000]) do
#      write_data(ref, file, path)
#    else
#      error ->
#        File.close(file)
#        File.rm_rf!("path/filename")
#    end
#  end
#  defp write_data(ref, file, path) do
#    receive do
#      %AsyncStatus{code: 200} ->
#        write(ref, file, path)
#      %AsyncStatus{code: error_code} ->
#        File.close(file)
#      %AsyncRedirect{headers: headers, to: to, id: ^ref} ->
#        download(to, path)
#      %AsyncChunk{chunk: chunk, id: ^ref} ->
#        IO.binwrite(file, chunk)
#        write(ref, file, path)
#      %AsyncEnd{id: ^ref} ->
#        File.close(file)
#    end
#  end
# end
