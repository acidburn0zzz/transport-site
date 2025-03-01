defmodule Transport.Jobs.OnDemandValidationJob do
  @moduledoc """
  Job in charge of validating a file that has been stored
  on Cellar and tracked by a `DB.MultiValidation` row.

  It validates the file and stores the result in the database.
  """
  use Oban.Worker, tags: ["validation"], max_attempts: 5, queue: :on_demand_validation
  require Logger
  import Ecto.Changeset
  import Ecto.Query
  alias DB.{MultiValidation, Repo}
  alias Shared.Validation.JSONSchemaValidator.Wrapper, as: JSONSchemaValidator
  alias Shared.Validation.TableSchemaValidator.Wrapper, as: TableSchemaValidator
  alias Transport.DataVisualization
  alias Transport.Validators.GTFSRT
  alias Transport.Validators.GTFSTransport
  @download_timeout_ms 10_000

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"id" => multivalidation_id, "state" => "waiting"} = payload}) do
    changes =
      try do
        perform_validation(payload)
      rescue
        e -> %{oban_args: %{"state" => "error", "error_reason" => inspect(e)}}
      end

    validation = %{oban_args: oban_args} = MultiValidation |> preload(:metadata) |> Repo.get!(multivalidation_id)

    # update oban_args with validator output
    oban_args = Map.merge(oban_args, changes.oban_args)
    changes = changes |> Map.put(:oban_args, oban_args)

    {metadata, changes} = Map.pop(changes, :metadata)

    validation
    |> change(changes)
    |> put_assoc(:metadata, %{
      metadata: metadata
    })
    |> Repo.update!()

    if Map.has_key?(payload, "filename") do
      Transport.S3.delete_object!(:on_demand_validation, payload["filename"])
    end

    :ok
  end

  defp perform_validation(%{"type" => "gtfs", "permanent_url" => url}) do
    validator = GTFSTransport.validator_name()

    case GTFSTransport.validate(url) do
      {:error, msg} ->
        %{oban_args: %{"state" => "error", "error_reason" => msg}, validator: validator}

      {:ok, %{"validations" => validation, "metadata" => metadata}} ->
        %{
          result: validation,
          metadata: metadata,
          data_vis: DataVisualization.validation_data_vis(validation),
          validator: validator,
          command: GTFSTransport.command(url),
          validated_data_name: url,
          max_error: GTFSTransport.get_max_severity_error(validation),
          oban_args: %{
            "state" => "completed"
          }
        }
    end
  end

  defp perform_validation(%{
         "type" => "tableschema",
         "permanent_url" => url,
         "schema_name" => schema_name
       }) do
    validator = "validata"

    case TableSchemaValidator.validate(schema_name, url) do
      nil ->
        %{oban_args: %{"state" => "error", "error_reason" => "could not perform validation"}, validator: validator}

      # https://github.com/etalab/transport-site/issues/2390
      # validator name should come from validator module, when it is properly extracted
      validation ->
        %{oban_args: %{"state" => "completed"}, result: validation, validator: validator}
    end
  end

  defp perform_validation(%{
         "type" => "jsonschema",
         "permanent_url" => url,
         "schema_name" => schema_name
       }) do
    # https://github.com/etalab/transport-site/issues/2390
    # validator name should come from validator module, when it is properly extracted
    validator = "ExJsonSchema"

    case JSONSchemaValidator.validate(
           JSONSchemaValidator.load_jsonschema_for_schema(schema_name),
           url
         ) do
      nil ->
        %{
          oban_args: %{
            "state" => "error",
            "error_reason" => "could not perform validation"
          },
          validator: validator
        }

      validation ->
        %{oban_args: %{"state" => "completed"}, result: validation, validator: validator}
    end
  end

  defp perform_validation(%{
         "type" => "gtfs-rt",
         "gtfs_url" => gtfs_url,
         "gtfs_rt_url" => gtfs_rt_url,
         "id" => id
       }) do
    {gtfs_path, gtfs_rt_path} = {filename(id, "gtfs"), filename(id, "gtfs-rt")}

    result =
      [download_from_url(gtfs_url, gtfs_path), download_from_url(gtfs_rt_url, gtfs_rt_path)]
      |> process_download()

    remove_files([gtfs_path, gtfs_rt_path, gtfs_rt_result_path(gtfs_rt_path)])

    result
    |> Map.merge(%{validated_data_name: gtfs_rt_url, secondary_validated_data_name: gtfs_url})
  end

  defp normalize_download(result) do
    case result do
      {:error, reason} -> {:error, %{"state" => "error", "error_reason" => reason}}
      {:ok, path, _} -> {:ok, path}
    end
  end

  defp remove_files(paths) do
    paths |> Enum.each(&File.rm(&1))
    paths |> Enum.each(&File.rmdir(Path.dirname(&1)))
  end

  defp process_download([{:ok, gtfs_path}, {:ok, gtfs_rt_path}]) do
    run_save_gtfs_rt_validation(gtfs_path, gtfs_rt_path)
  end

  defp process_download(results) do
    {_, oban_args} = results |> Enum.find(fn {k, _} -> k !== :ok end)
    %{oban_args: oban_args}
  end

  @spec run_save_gtfs_rt_validation(binary(), binary(), ignore_shapes: boolean()) :: map()
  defp run_save_gtfs_rt_validation(gtfs_path, gtfs_rt_path, opts \\ []) do
    opts = Keyword.validate!(opts, ignore_shapes: false)
    ignore_shapes = Keyword.fetch!(opts, :ignore_shapes)
    validator_args = GTFSRT.validator_arguments(gtfs_path, gtfs_rt_path, opts)

    case GTFSRT.run_validator(validator_args) do
      {:ok, _} ->
        case GTFSRT.convert_validator_report(gtfs_rt_result_path(gtfs_rt_path), opts) do
          {:ok, validation} ->
            # https://github.com/etalab/transport-site/issues/2390
            # to do: transport-tools version when available
            %{
              oban_args: %{"state" => "completed"},
              result: validation,
              validator: GTFSRT.validator_name(),
              command: inspect(validator_args)
            }

          :error ->
            %{
              oban_args: %{
                "state" => "error",
                "error_reason" => "Could not run validator. Please provide a GTFS and a GTFS-RT."
              }
            }
        end

      {:error, reason} ->
        if not ignore_shapes and String.contains?(reason, "java.lang.OutOfMemoryError") do
          run_save_gtfs_rt_validation(gtfs_path, gtfs_rt_path, ignore_shapes: true)
        else
          %{oban_args: %{"state" => "error", "error_reason" => inspect(reason)}}
        end
    end
  end

  def filename(validation_id, format) when format in ["gtfs", "gtfs-rt"] do
    folder = System.tmp_dir!() |> Path.join("validation_#{validation_id}_gtfs_rt")
    File.mkdir_p!(folder)
    extension = Map.fetch!(%{"gtfs" => "zip", "gtfs-rt" => "bin"}, format)
    Path.join([folder, "file.#{extension}"])
  end

  def gtfs_rt_result_path(gtfs_rt_path) do
    # https://github.com/MobilityData/gtfs-realtime-validator/blob/master/gtfs-realtime-validator-lib/README.md#output
    gtfs_rt_path <> ".results.json"
  end

  defp download_from_url(url, path) do
    result =
      case get_request(url) do
        {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
          Logger.debug("Saving #{url} to #{path}")
          File.write!(path, body)
          {:ok, path, body}

        {:ok, %HTTPoison.Response{status_code: status}} ->
          {:error, "Got a non 200 status: #{status} when downloading #{url}"}

        {:error, %HTTPoison.Error{reason: reason}} ->
          {:error, "Got an error: #{reason} when downloading #{url}"}
      end

    normalize_download(result)
  end

  defp get_request(url) do
    Transport.Shared.Wrapper.HTTPoison.impl().get(url, [],
      follow_redirect: true,
      recv_timeout: @download_timeout_ms,
      timeout: @download_timeout_ms
    )
  end
end
