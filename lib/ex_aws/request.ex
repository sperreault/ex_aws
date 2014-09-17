defmodule ExAws.Request do
  @max_attempts 10

  def request(service, config, operation, data) do
    body = case data do
      [] -> "{}"
      _  -> Poison.encode!(data)
    end

    headers = headers(service, config, operation, body)
    request_and_retry(service, config, headers, body, {:attempt, 1})
  end

  def headers(service, config, operation, body) do
    conf = ExAws.Config.config_map(config)
    headers = [
      {'host', Map.get(conf, :"#{service}_host")},
      {'x-amz-target', operation |> String.to_char_list},
    ]

    host = Map.get(conf, :"#{service}_host") |> List.to_string
    region = case host |> String.split(".") do
      [_, value, _, _] -> value |> String.to_char_list
      _ -> 'us-east-1'
    end
    :erlcloud_aws.sign_v4(config, headers, body, region, service_name(service))
  end

  def service_name(:ddb), do: "dynamodb"
  def service_name(other), do: other |> Atom.to_string

  def request_and_retry(_, _, _, {:error, reason}), do: {:error, reason}

  def request_and_retry(service, config, headers, body, {:attempt, attempt}) do
    url = url(service, ExAws.Config.config_map(config))
    headers = [{'content-type', 'application/x-amz-json-1.0'} | headers] |> binary_headers

    case HTTPoison.post(url, body, headers) do
      %HTTPoison.Response{status_code: 200, body: body} ->
        case Poison.Parser.parse(body) do
          {:ok, result} -> {:ok, result}
          {:error, _}   -> {:error, body}
        end
      %HTTPoison.Response{status_code: status} = resp when status >= 400 and status < 500 ->
        case client_error(resp) do
          {:retry, reason} ->
            request_and_retry(service, config, headers, body, attempt_again?(attempt, reason))
          {:error, reason} -> {:error, reason}
        end
      %HTTPoison.Response{status_code: status, body: body} when status >= 500 ->
        reason = {:http_error, status, body}
        request_and_retry(service, config, headers, body, attempt_again?(attempt, reason))
      whoknows -> {:error, whoknows}
    end
  end

  def client_error(%HTTPoison.Response{status_code: status, body: body}) do
    case Poison.Parser.parse(body) do
      {:ok, %{"__type" => error_type, "Message" => message}} ->
        error_type
          |> String.split("#")
          |> fn
            [_, type] -> handle_aws_error(type, message)
            _         -> {:error, {:http_error, status, body}}
          end.()
      _ -> {:error, {:http_error, status, body}}
    end
  end

  def handle_aws_error("ProvisionedThroughputExceededException" = type, message) do
    {:retry, {type, message}}
  end

  def handle_aws_error("ThrottlingException" = type, message) do
    {:retry, {type, message}}
  end

  def handle_aws_error(type, message) do
    {:error, {type, message}}
  end

  def attempt_again?(attempt, reason) when attempt >= @max_attempts do
    {:error, reason}
  end

  def attempt_again?(attempt, _) do
    attempt |> backoff
    {:attempt, attempt + 1}
  end

  # TODO: make exponential
  def backoff(attempt) do
    :timer.sleep(attempt * 1000)
  end

  def binary_headers(headers) do
    headers |> Enum.map(fn({k, v}) -> {List.to_string(k), List.to_string(v)} end)
  end

  defp url(service, config) do
    [
      Map.get(config, :"#{service}_scheme"),
      Map.get(config, :"#{service}_host"),
      Map.get(config, :"#{service}_port") |> port
    ] |> Enum.join
  end

  defp port(80), do: ""
  defp port(p),  do: ":#{p}"
end