defmodule DB.Resource do
  @moduledoc """
  Resource model
  """
  use Ecto.Schema
  use TypedEctoSchema
  alias DB.{Dataset, LogsValidation, Repo, ResourceUnavailability, Validation}
  alias Shared.Validation.JSONSchemaValidator.Wrapper, as: JSONSchemaValidator
  alias Shared.Validation.TableSchemaValidator.Wrapper, as: TableSchemaValidator
  alias Transport.DataVisualization
  alias Transport.Shared.Schemas.Wrapper, as: Schemas
  import Ecto.{Changeset, Query}
  import TransportWeb.Router.Helpers, only: [resource_url: 3]
  require Logger

  typed_schema "resource" do
    # real url
    field(:url, :string)
    field(:format, :string)
    field(:last_import, :string)
    field(:title, :string)
    field(:metadata, :map)
    field(:last_update, :string)
    # stable data.gouv.fr url if exists, else (for ODS gtfs as csv) it's the real url
    field(:latest_url, :string)
    field(:is_available, :boolean, default: true)
    field(:content_hash, :string)

    field(:is_community_resource, :boolean)

    # the declared official schema used by the resource
    field(:schema_name, :string)
    field(:schema_version, :string)

    # only relevant for community resources, name of the owner or the organization that published the resource
    field(:community_resource_publisher, :string)
    field(:description, :string)

    # some community resources have been generated from another dataset (like the generated NeTEx / GeoJson)
    field(:original_resource_url, :string)

    # Id of the datagouv resource. Note that several resources can have the same datagouv_id
    # because one datagouv resource can be a CSV linking to several transport.data.gouv's resources
    # (this is done for OpenDataSoft)
    field(:datagouv_id, :string)

    # we add 2 fields, that are already in the metadata json, in order to be able to add some indices
    field(:start_date, :date)
    field(:end_date, :date)

    field(:filesize, :integer)
    # Can be `remote` or `file`. `file` are for files uploaded and hosted
    # on data.gouv.fr
    field(:filetype, :string)
    # The resource's type on data.gouv.fr
    # https://github.com/opendatateam/udata/blob/fab505fd9159c6a9f63e3cb55f0d6479b7ca91e2/udata/core/dataset/models.py#L89-L96
    # Example: `main`, `documentation`, `api`, `code` etc.
    field(:type, :string)
    field(:display_position, :integer)

    belongs_to(:dataset, Dataset)
    # validation v1, to be deleted later
    # https://github.com/etalab/transport-site/issues/2390
    has_one(:validation, Validation, on_replace: :delete)
    has_many(:validations, DB.MultiValidation)
    has_many(:resource_metadata, DB.ResourceMetadata)

    has_many(:logs_validation, LogsValidation, on_replace: :delete, on_delete: :delete_all)

    has_many(:resource_unavailabilities, ResourceUnavailability,
      on_replace: :delete,
      on_delete: :delete_all
    )

    has_many(:resource_history, DB.ResourceHistory)
  end

  def base_query, do: from(r in DB.Resource, as: :resource)

  def join_dataset_with_resource(query) do
    query
    |> join(:inner, [dataset: d], r in DB.Resource, on: d.id == r.dataset_id, as: :resource)
  end

  def filter_on_resource_id(query, resource_id) do
    query
    |> where([resource: r], r.id == ^resource_id)
  end

  def filter_on_dataset_id(query, dataset_id) do
    query
    |> where([resource: r], r.dataset_id == ^dataset_id)
  end

  defp gtfs_validator, do: Shared.Validation.GtfsValidator.Wrapper.impl()

  @spec endpoint() :: binary()
  def endpoint, do: Application.fetch_env!(:transport, :gtfs_validator_url) <> "/validate"

  @doc """
  Determines if a validation is needed. We need to validate a resource if:
  - we forced the validation process
  - the resource is a gbfs
  - for GTFS resources: the content hash changed since the last validation or it was never validated
  - the resource has a JSON Schema schema set

  ## Examples

    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha",
    ...> validation: %Validation{validation_latest_content_hash: "a_sha"}}, false)
    {false, "content hash has not changed"}
    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha",
    ...> validation: %Validation{validation_latest_content_hash: "a_sha"}}, true)
    {true, "forced validation"}
    iex> Resource.needs_validation(%Resource{format: "gbfs"}, false)
    {true, "gbfs is always validated"}
    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha"}, false)
    {true, "no previous validation"}
    iex> Resource.needs_validation(%Resource{format: "gtfs-rt", content_hash: "a_sha"}, true)
    {false, "cannot validate this resource"}
    iex> Resource.needs_validation(%Resource{schema_name: "foo", filesize: 11000000}, false)
    {false, "schema is set but file is bigger than 10 MB"}
    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha",
    ...> validation: %Validation{validation_latest_content_hash: "another_sha"}}, false)
    {true, "content hash has changed"}
  """
  @spec needs_validation(__MODULE__.t(), boolean()) :: {boolean(), binary()}
  def needs_validation(%__MODULE__{} = resource, force_validation) do
    case can_validate?(resource) do
      {true, _} -> need_validate?(resource, force_validation)
      result -> result
    end
  end

  def can_validate?(%__MODULE__{format: format}) when format in ["GTFS", "gbfs"] do
    {true, "#{format} can be validated"}
  end

  def can_validate?(%__MODULE__{schema_name: schema_name, filesize: filesize})
      when is_binary(schema_name) and is_integer(filesize) and filesize > 10_000_000 do
    {false, "schema is set but file is bigger than 10 MB"}
  end

  def can_validate?(%__MODULE__{schema_name: schema_name}) when is_binary(schema_name) do
    {Schemas.is_known_schema?(schema_name), "schema is set"}
  end

  def can_validate?(%__MODULE__{}) do
    {false, "cannot validate this resource"}
  end

  def need_validate?(%__MODULE__{}, true) do
    {true, "forced validation"}
  end

  def need_validate?(
        %__MODULE__{
          content_hash: content_hash,
          validation: %Validation{
            validation_latest_content_hash: validation_latest_content_hash
          }
        } = r,
        _force_validation
      ) do
    # if there is already a validation, we revalidate only if the file has changed
    if content_hash != validation_latest_content_hash do
      Logger.info("the files for resource #{r.id} have been modified since last validation, we need to revalidate them")

      {true, "content hash has changed"}
    else
      {false, "content hash has not changed"}
    end
  end

  def need_validate?(%__MODULE__{format: "GTFS"}, _force_validation) do
    {true, "no previous validation"}
  end

  def need_validate?(%__MODULE__{format: "gbfs"}, _force_validation) do
    {true, "gbfs is always validated"}
  end

  def need_validate?(
        %__MODULE__{
          schema_name: schema_name,
          content_hash: content_hash,
          metadata: %{"validation" => %{"content_hash" => validation_content_hash}}
        },
        _force_validation
      )
      when is_binary(schema_name) do
    case validation_content_hash == content_hash do
      true -> {false, "schema is set but content hash has not changed"}
      false -> {true, "schema is set and content hash has changed"}
    end
  end

  def need_validate?(%__MODULE__{schema_name: schema_name}, _force_validation) when is_binary(schema_name) do
    {true, "schema is set and no previous validation"}
  end

  @spec validate_and_save(__MODULE__.t() | integer(), boolean()) :: {:error, any} | {:ok, nil}
  def validate_and_save(resource_id, force_validation) when is_integer(resource_id),
    do:
      __MODULE__
      |> where([r], r.id == ^resource_id)
      |> preload(:validation)
      |> Repo.one!()
      |> validate_and_save(force_validation)

  def validate_and_save(%__MODULE__{id: resource_id} = resource, force_validation) do
    Logger.info("Validating #{resource.url}")

    resource = Repo.preload(resource, :validation)

    with {true, msg} <- __MODULE__.needs_validation(resource, force_validation),
         {:ok, validations} <- validate(resource),
         {:ok, _} <- save(resource, validations) do
      # log the validation success
      Repo.insert(%LogsValidation{
        resource_id: resource_id,
        timestamp: DateTime.truncate(DateTime.utc_now(), :second),
        is_success: true,
        skipped_reason: msg
      })

      {:ok, nil}
    else
      {false, skipped_reason} ->
        # the ressource does not need to be validated again, we have nothing to do
        Repo.insert(%LogsValidation{
          resource_id: resource_id,
          timestamp: DateTime.truncate(DateTime.utc_now(), :second),
          is_success: true,
          skipped: true,
          skipped_reason: skipped_reason
        })

        {:ok, nil}

      {:error, error} ->
        Logger.warn("Error when calling the validator: #{error}")

        Sentry.capture_message(
          "unable_to_call_validator",
          extra: %{
            url: resource.url,
            error: error
          }
        )

        # log the validation error
        Repo.insert(%LogsValidation{
          resource_id: resource_id,
          timestamp: DateTime.truncate(DateTime.utc_now(), :second),
          is_success: false,
          error_msg: "error while calling the validator: #{inspect(error)}"
        })

        {:error, error}
    end
  rescue
    e ->
      Logger.error("error while validating resource #{resource.id}: #{inspect(e)}")
      Logger.error(Exception.format(:error, e, __STACKTRACE__))

      Repo.insert(%LogsValidation{
        resource_id: resource_id,
        timestamp: DateTime.truncate(DateTime.utc_now(), :second),
        is_success: false,
        error_msg: "#{inspect(e)}"
      })

      {:error, e}
  end

  @spec validate(__MODULE__.t()) :: {:error, any} | {:ok, map()}
  def validate(%__MODULE__{url: nil}), do: {:error, "No url"}

  def validate(%__MODULE__{url: url, format: "gbfs"}) do
    {:ok,
     %{
       "metadata" =>
         Transport.Shared.GBFSMetadata.Wrapper.compute_feed_metadata(
           url,
           "https://#{Application.fetch_env!(:transport, :domain_name)}"
         )
     }}
  end

  def validate(%__MODULE__{url: url, format: "GTFS"}) do
    with {:ok, validation_result} <- gtfs_validator().validate_from_url(url),
         {:ok, validations} <- Map.fetch(validation_result, "validations") do
      data_vis = DataVisualization.validation_data_vis(validations)

      {:ok, Map.put(validation_result, "data_vis", data_vis)}
    else
      {:error, error} ->
        Logger.error(inspect(error))
        {:error, "Validation failed."}

      :error ->
        {:error, "Validation failed."}
    end
  end

  def validate(%__MODULE__{schema_name: schema_name, metadata: metadata, content_hash: content_hash} = resource) do
    schema_type = Schemas.schema_type(schema_name)

    metadata =
      case validate_against_schema(resource, schema_type) do
        payload when is_map(payload) ->
          validation_details = %{"schema_type" => schema_type, "content_hash" => content_hash}
          Map.merge(metadata || %{}, %{"validation" => Map.merge(payload, validation_details)})

        nil ->
          metadata
      end

    {:ok, %{"metadata" => metadata}}
  end

  def validate(%__MODULE__{format: f, id: id}) do
    Logger.info("cannot validate resource id=#{id} because we don't know how to validate the #{f} format")

    {:ok, %{"validations" => nil, "metadata" => nil}}
  end

  defp validate_against_schema(
         %__MODULE__{url: url, schema_name: schema_name, schema_version: schema_version},
         schema_type
       ) do
    case schema_type do
      "tableschema" ->
        TableSchemaValidator.validate(schema_name, url, schema_version)

      "jsonschema" ->
        JSONSchemaValidator.validate(JSONSchemaValidator.load_jsonschema_for_schema(schema_name), url)
    end
  end

  @spec save(__MODULE__.t(), map()) :: {:ok, any()} | {:error, any()}
  def save(
        %__MODULE__{id: id, format: format} = r,
        %{
          "validations" => validations,
          "metadata" => metadata,
          "data_vis" => data_vis
        }
      ) do
    # When the validator is unable to open the archive, it will return a fatal issue
    # And the metadata will be nil (as it couldn’t read them)
    if is_nil(metadata) and format == "GTFS",
      do: Logger.warn("Unable to validate resource ##{id}: #{inspect(validations)}")

    ecto_response =
      __MODULE__
      |> preload(:validation)
      |> Repo.get(id)
      |> change(
        metadata: metadata,
        validation: %Validation{
          date:
            DateTime.utc_now()
            |> DateTime.to_string(),
          details: validations,
          max_error: get_max_severity_error(validations),
          validation_latest_content_hash: r.content_hash,
          data_vis: data_vis
        },
        start_date: str_to_date(metadata["start_date"]),
        end_date: str_to_date(metadata["end_date"])
      )
      |> Repo.update()

    ecto_response
  end

  def save(%__MODULE__{} = r, %{"metadata" => %{"validation" => validation} = metadata}) do
    r
    |> change(
      metadata: metadata,
      validation: %Validation{
        date: DateTime.utc_now() |> DateTime.to_string(),
        details: validation
      }
    )
    |> Repo.update()
  end

  def save(%__MODULE__{} = r, %{"metadata" => metadata}) do
    r |> change(metadata: metadata) |> Repo.update()
  end

  def save(url, _) do
    Logger.warn("Unknown error when saving the validation")
    Sentry.capture_message("validation_save_failed", extra: url)
  end

  def changeset(resource, params) do
    resource
    |> cast(
      params,
      [
        :url,
        :format,
        :last_import,
        :title,
        :metadata,
        :id,
        :datagouv_id,
        :last_update,
        :latest_url,
        :is_available,
        :is_community_resource,
        :schema_name,
        :schema_version,
        :community_resource_publisher,
        :original_resource_url,
        :content_hash,
        :description,
        :filesize,
        :filetype,
        :type,
        :display_position
      ]
    )
    |> validate_required([:url, :datagouv_id])
  end

  @spec is_outdated?(__MODULE__.t()) :: boolean
  def is_outdated?(%__MODULE__{
        metadata: %{
          "end_date" => nil
        }
      }),
      do: false

  def is_outdated?(%__MODULE__{
        metadata: %{
          "end_date" => end_date
        }
      }),
      do:
        end_date <=
          Date.utc_today()
          |> Date.to_iso8601()

  def is_outdated?(_), do: true

  # I duplicate this function in Transport.Validators.GTFSTransport
  # this one should be deleted later
  # https://github.com/etalab/transport-site/issues/2390
  @spec get_max_severity_error(any) :: binary()
  defp get_max_severity_error(%{} = validations) do
    validations
    |> Map.values()
    |> Enum.map(fn v -> hd(v)["severity"] end)
    |> Enum.min_by(fn sev -> Validation.severities(sev).level end, fn -> "NoError" end)
  end

  defp get_max_severity_error(_), do: nil

  @spec is_gtfs?(__MODULE__.t()) :: boolean()
  def is_gtfs?(%__MODULE__{format: "GTFS"}), do: true
  def is_gtfs?(_), do: false

  @spec is_gbfs?(__MODULE__.t()) :: boolean
  def is_gbfs?(%__MODULE__{format: "gbfs"}), do: true
  def is_gbfs?(_), do: false

  @spec is_netex?(__MODULE__.t()) :: boolean
  def is_netex?(%__MODULE__{format: "NeTEx"}), do: true
  def is_netex?(_), do: false

  @spec is_gtfs_rt?(__MODULE__.t()) :: boolean
  def is_gtfs_rt?(%__MODULE__{format: "gtfs-rt"}), do: true
  def is_gtfs_rt?(%__MODULE__{format: "gtfsrt"}), do: true
  def is_gtfs_rt?(_), do: false

  @spec is_siri?(__MODULE__.t()) :: boolean
  def is_siri?(%__MODULE__{format: "SIRI"}), do: true
  def is_siri?(_), do: false

  @spec is_siri_lite?(__MODULE__.t()) :: boolean
  def is_siri_lite?(%__MODULE__{format: "SIRI Lite"}), do: true
  def is_siri_lite?(_), do: false

  @spec is_documentation?(__MODULE__.t()) :: boolean
  def is_documentation?(%__MODULE__{type: "documentation"}), do: true
  def is_documentation?(_), do: false

  @spec is_community_resource?(__MODULE__.t()) :: boolean
  def is_community_resource?(%__MODULE__{is_community_resource: true}), do: true
  def is_community_resource?(_), do: false

  @spec is_real_time?(__MODULE__.t()) :: boolean
  def is_real_time?(%__MODULE__{} = resource) do
    is_gtfs_rt?(resource) or is_gbfs?(resource) or is_siri_lite?(resource) or is_siri?(resource)
  end

  @doc """
  Ultimately, requestor_refs should be imported as data gouv meta-data, or maybe just set via
  our backoffice. For now though, we're guessing them based on a public configuration + the host name.
  """
  def guess_requestor_ref(%__MODULE__{} = resource) do
    if URI.parse(resource.url).host == "ara-api.enroute.mobi" do
      public_siri_requestor_refs = Application.fetch_env!(:transport, :public_siri_requestor_refs)
      Map.get(public_siri_requestor_refs, :enroute)
    else
      nil
    end
  end

  @spec has_schema?(__MODULE__.t()) :: boolean
  def has_schema?(%__MODULE__{schema_name: schema_name}), do: not is_nil(schema_name)

  @spec can_direct_download?(__MODULE__.t()) :: boolean
  def can_direct_download?(resource) do
    # raw.githubusercontent.com does not put `Content-Disposition: attachment`
    # in response headers and we'd like to have this
    uri = URI.parse(resource.url)
    uri.scheme == "https" and uri.host != "raw.githubusercontent.com"
  end

  @spec other_resources_query(__MODULE__.t()) :: Ecto.Query.t()
  def other_resources_query(%__MODULE__{} = resource),
    do:
      from(
        r in __MODULE__,
        where: r.dataset_id == ^resource.dataset_id and r.id != ^resource.id
      )

  @spec other_resources(__MODULE__.t()) :: [__MODULE__.t()]
  def other_resources(%__MODULE__{} = r),
    do:
      r
      |> other_resources_query()
      |> Repo.all()

  @spec str_to_date(binary()) :: Date.t() | nil
  defp str_to_date(date) when not is_nil(date) do
    date
    |> Date.from_iso8601()
    |> case do
      {:ok, v} ->
        v

      {:error, e} ->
        Logger.error("date '#{date}' not valid: #{inspect(e)}")
        nil
    end
  end

  defp str_to_date(_), do: nil

  def by_id(query, id) do
    from(resource in query,
      where: resource.id == ^id
    )
  end

  @spec get_related_files(__MODULE__.t()) :: map()
  def get_related_files(%__MODULE__{id: resource_id}) do
    %{}
    |> Map.put(:geojson, get_related_geojson_info(resource_id))
    |> Map.put(:netex, get_related_netex_info(resource_id))
  end

  def get_related_geojson_info(resource_id), do: get_related_conversion_info(resource_id, "GeoJSON")
  def get_related_netex_info(resource_id), do: get_related_conversion_info(resource_id, "NeTEx")

  @spec get_related_conversion_info(integer() | nil, binary()) :: %{url: binary(), filesize: binary()} | nil
  def get_related_conversion_info(nil, _), do: nil

  def get_related_conversion_info(resource_id, format) when format in ["GeoJSON", "NeTEx"] do
    DB.ResourceHistory
    |> join(:inner, [rh], dc in DB.DataConversion,
      as: :dc,
      on: fragment("?::text = ? ->> 'uuid'", dc.resource_history_uuid, rh.payload)
    )
    |> select([rh, dc], %{
      url: fragment("? ->> 'permanent_url'", dc.payload),
      filesize: fragment("? ->> 'filesize'", dc.payload),
      resource_history_last_up_to_date_at: rh.last_up_to_date_at
    })
    |> where([rh, dc], rh.resource_id == ^resource_id and dc.convert_to == ^format)
    |> order_by([rh, _], desc: rh.inserted_at)
    |> limit(1)
    |> DB.Repo.one()
  end

  @spec content_updated_at(integer() | __MODULE__.t()) :: Calendar.datetime() | nil
  def content_updated_at(%__MODULE__{id: id}), do: content_updated_at(id)

  def content_updated_at(resource_id) do
    resource_history_list =
      DB.ResourceHistory
      |> where([rh], rh.resource_id == ^resource_id)
      |> where([rh], fragment("payload \\? 'download_datetime'"))
      |> select([rh], fragment("payload ->>'download_datetime'"))
      |> order_by([rh], desc: fragment("payload ->>'download_datetime'"))
      |> limit(2)
      |> DB.Repo.all()

    case Enum.count(resource_history_list) do
      n when n in [0, 1] ->
        nil

      _ ->
        {:ok, updated_at, 0} = resource_history_list |> Enum.at(0) |> DateTime.from_iso8601()
        updated_at
    end
  end

  def download_url(%__MODULE__{} = resource, conn_or_endpoint \\ TransportWeb.Endpoint) do
    cond do
      needs_stable_url?(resource) -> resource.latest_url
      can_direct_download?(resource) -> resource.url
      true -> resource_url(conn_or_endpoint, :download, resource.id)
    end
  end

  defp needs_stable_url?(%__MODULE__{latest_url: nil}), do: false

  defp needs_stable_url?(%__MODULE__{url: url}) do
    parsed_url = URI.parse(url)

    hosted_on_static_datagouv =
      Enum.member?(Application.fetch_env!(:transport, :datagouv_static_hosts), parsed_url.host)

    object_storage_regex =
      ~r{(https://.*\.blob\.core\.windows\.net)|(https://.*\.s3\..*\.amazonaws\.com)|(https://.*\.s3\..*\.scw\.cloud)|(https://.*\.cellar-c2\.services\.clever-cloud\.com)|(https://s3\..*\.cloud\.ovh\.net)}

    hosted_on_bison_fute = parsed_url.host == Application.fetch_env!(:transport, :bison_fute_host)

    cond do
      hosted_on_bison_fute -> is_link_to_folder?(parsed_url)
      hosted_on_static_datagouv -> true
      String.match?(url, object_storage_regex) -> true
      true -> false
    end
  end

  defp needs_stable_url?(%__MODULE__{}), do: false

  defp is_link_to_folder?(%URI{path: path}) do
    path |> Path.basename() |> :filename.extension() == ""
  end
end
