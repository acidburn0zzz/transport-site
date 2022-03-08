defmodule TransportWeb.ValidationController do
  use TransportWeb, :controller
  alias DB.{Repo, Validation}
  alias Transport.DataVisualization
  import TransportWeb.ResourceView, only: [issue_type: 1]

  def validate(%Plug.Conn{} = conn, %{"upload" => %{"url" => url, "type" => "gbfs"} = params}) do
    %Validation{
      on_the_fly_validation_metadata: build_metadata(params),
      date: DateTime.utc_now() |> DateTime.to_string()
    }
    |> Repo.insert!()

    redirect(conn, to: gbfs_analyzer_path(conn, :index, url: url))
  end

  def validate(%Plug.Conn{} = conn, %{"upload" => %{"file" => %{path: file_path}, "type" => type}}) do
    if is_valid_type?(type) do
      metadata = build_metadata(type)
      upload_to_s3(file_path, Map.fetch!(metadata, "filename"))

      validation = %Validation{on_the_fly_validation_metadata: metadata} |> Repo.insert!()
      dispatch_validation_job(validation)
      redirect(conn, to: validation_path(conn, :show, validation.id, token: Map.fetch!(metadata, "secret_url_token")))
    else
      conn |> bad_request()
    end
  end

  def validate(conn, _) do
    conn |> bad_request()
  end

  def show(%Plug.Conn{} = conn, %{} = params) do
    token = params["token"]

    case Repo.get(Validation, params["id"]) do
      nil ->
        not_found(conn)

      %Validation{on_the_fly_validation_metadata: %{"secret_url_token" => expected_token}}
      when expected_token != token ->
        unauthorized(conn)

      %Validation{on_the_fly_validation_metadata: %{"state" => "completed", "type" => "gtfs"}} = validation ->
        current_issues = Validation.get_issues(validation, params)

        issue_type =
          case params["issue_type"] do
            nil -> issue_type(current_issues)
            issue_type -> issue_type
          end

        conn
        |> assign(:validation_id, params["id"])
        |> assign(:other_resources, [])
        |> assign(:issues, Scrivener.paginate(current_issues, make_pagination_config(params)))
        |> assign(:validation_summary, Validation.summary(validation))
        |> assign(:severities_count, Validation.count_by_severity(validation))
        |> assign(:metadata, validation.on_the_fly_validation_metadata)
        |> assign(:data_vis, data_vis(validation, issue_type))
        |> assign(:token, token)
        |> render("show.html")

      # Handles waiting for validation to complete, errors and
      # validation for schemas
      _ ->
        live_render(conn, TransportWeb.Live.OnDemandValidationLive,
          session: %{
            "validation_id" => params["id"],
            "current_url" => validation_path(conn, :show, params["id"], token: token)
          }
        )
    end
  end

  defp data_vis(%Validation{} = validation, issue_type) do
    data_vis = validation.data_vis[issue_type]
    has_features = DataVisualization.has_features(data_vis["geojson"])

    case {has_features, Jason.encode(data_vis)} do
      {false, _} -> nil
      {true, {:ok, encoded_data_vis}} -> encoded_data_vis
      _ -> nil
    end
  end

  defp filepath(type) do
    cond do
      type == "tableschema" -> Ecto.UUID.generate() <> ".csv"
      type in ["jsonschema", "gtfs"] -> Ecto.UUID.generate()
    end
  end

  defp dispatch_validation_job(%Validation{id: id, on_the_fly_validation_metadata: metadata}) do
    oban_args = Map.merge(%{"id" => id}, metadata)
    oban_args |> Transport.Jobs.OnDemandValidationJob.new() |> Oban.insert!()
  end

  def select_options do
    schemas =
      transport_schemas()
      |> Enum.map(fn {k, v} -> {Map.fetch!(v, "title"), k} end)
      |> Enum.sort_by(&elem(&1, 0))

    [{"GTFS", "gtfs"}, {"GBFS", "gbfs"}] ++ schemas
  end

  def is_valid_type?(type), do: type in (select_options() |> Enum.map(&elem(&1, 1)))

  defp upload_to_s3(file_path, path) do
    Transport.S3.upload_to_s3!(:on_demand_validation, File.read!(file_path), path)
  end

  defp build_metadata(%{"url" => url, "type" => "gbfs"}) do
    %{"type" => "gbfs", "state" => "submitted", "feed_url" => url}
  end

  defp build_metadata(type) do
    metadata =
      case type do
        "gtfs" -> %{"type" => "gtfs"}
        schema_name -> %{"schema_name" => schema_name, "type" => schema_type(schema_name)}
      end

    path = filepath(metadata["type"])

    Map.merge(
      metadata,
      %{
        "state" => "waiting",
        "filename" => path,
        "permanent_url" => Transport.S3.permanent_url(:on_demand_validation, path),
        "secret_url_token" => Ecto.UUID.generate()
      }
    )
  end

  defp schema_type(schema_name), do: transport_schemas()[schema_name]["schema_type"]

  defp transport_schemas, do: Transport.Shared.Schemas.Wrapper.transport_schemas()

  defp not_found(%Plug.Conn{} = conn) do
    conn
    |> put_status(:not_found)
    |> put_view(TransportWeb.ErrorView)
    |> render(:"404")
  end

  defp unauthorized(%Plug.Conn{} = conn) do
    conn
    |> put_status(:unauthorized)
    |> put_view(TransportWeb.ErrorView)
    |> render(:"401")
  end

  defp bad_request(%Plug.Conn{} = conn) do
    conn
    |> put_status(:bad_request)
    |> put_view(ErrorView)
    |> render("400.html")
  end
end
