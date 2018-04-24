defmodule CrawlerMain do
  require Logger
  require DownloadServer
  require Tools

  @timeout 1_000

  def main(args) do
    args
    |> parse_args
    |> process
  end

  def main() do
    main(System.argv())
  end

  defp parse_args(args) do
    case OptionParser.parse(args) do
      { _, [depth, fork_factor, start_url], _ } -> {:ok, elem(Integer.parse(depth),0), elem(Integer.parse(fork_factor), 0), start_url}
      { _, _, _ } -> {:help}
    end
  end

  defp process({:help}) do
    IO.puts "Usage: ./grepex depth fork-factor start-url"
    IO.puts "Runs a breadth-first-search starting for the <word> from the <start-url> up to a given <depth>."
    IO.puts "For each page a maximum <fork-factor> links per page are followed"
    IO.puts "The sequence of links followed is printed for each downloaded page"
    IO.puts "Example ./crawler 3 2 http://www.bbc.com/news"
  end

  defp process({:ok, depth, fork_factor, start_url}) do
    Logger.info "[#{inspect self()}] Starting crawling with depth=#{inspect depth}, fork_factor=#{inspect fork_factor}, start_url=#{start_url}"
    download(start_url)

    wait_for_response(%{
      :depth => depth,
      :fork_factor => fork_factor,
      :in_progress =>%{start_url => [start_url]},
      :downloaded => %{}
    })
  end

  defp wait_for_response(args) do
    receive do
      {:page_ok, url, status, content_type, content} ->
        handle_page_ok(args, url, status, content_type, content)
        |> wait_for_response()

      {:page_error, url, reason} ->
        handle_page_error(args, url, reason)
        |> wait_for_response()
    after
      @timeout -> handle_giveup(args)
    end
  end

  defp handle_giveup(%{in_progress: in_progress, downloaded: downloaded}) do
    IO.puts "*** Timeout expired."
    IO.puts "*** Downloads in progress: #{inspect in_progress}"
    IO.puts "*** Downloaded:"

    Tools.render_results(downloaded)
    |> Enum.each(&IO.puts/1)

    IO.puts "*** Exit. "
  end

  defp handle_page_error(%{in_progress: in_progress} = args, url, reason) do
      Logger.warn "[#{inspect self()}] Error while requested page #{url}. Reason: #{inspect reason}"

      args
      |> Map.put( :in_progress, Map.delete(in_progress, url))
  end

  defp handle_page_ok(args, current_url, status, content_type, content) do
    Logger.info "[#{inspect self()}] #{current_url} Enter handle_page_ok. status=#{status}, content_type=#{content_type}"
    Logger.debug "[#{inspect self()}] #{current_url} handle_page_ok: args=#{inspect args}"

    %{in_progress: in_progress, downloaded: downloaded, fork_factor: fork_factor, depth: depth}  = args

    current_path = in_progress[current_url]

    new_downloaded = Map.put(downloaded, current_url, current_path)

    urls =
      if String.starts_with?(content_type, "text/html") do
        Tools.extract_urls(content)
        |> Enum.take_random(fork_factor)
        |> MapSet.new
      else
        MapSet.new []
      end

    Logger.debug "[#{inspect self()}] #{current_url} handle_page_ok: urls=#{inspect urls}"

    new_jobs =
      if Enum.count(current_path) < depth do
        urls
        |> Enum.filter(fn url -> not(Map.has_key?(new_downloaded, url)) end)
        |> Enum.filter(fn url -> not(Map.has_key?(in_progress, url)) end)
        |> Enum.reduce(%{},fn (url, acc) -> Map.put(acc, url, [url | current_path]) end)
      else
        %{}
      end

    Map.keys(new_jobs)
    |> Enum.each(&download/1)

    new_in_progress =
      in_progress
      |> Map.delete(current_url)
      |> Map.merge(new_jobs)


    new_args =
      args
      |> Map.put( :downloaded, new_downloaded)
      |> Map.put( :in_progress, new_in_progress)


    Logger.debug "[#{inspect self()}] #{current_url} DONE. new_args=#{inspect new_args}"

    new_args
  end

  defp download(url) do
    # DownloadServer.get(url, self())
    node =
      [Node.self() | Node.list()]
      |> Enum.take_random(1)
      |> Enum.at(0)

    :rpc.call(:"#{node}", DownloadServer, :get, [url, self()])
  end
end
