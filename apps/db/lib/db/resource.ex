defmodule DB.Resource do
  @moduledoc """
  Resource model
  """
  use Ecto.Schema
  use TypedEctoSchema
  alias DB.{Dataset, Repo, Validation}
  import Ecto.{Changeset, Query}
  import DB.Gettext
  require Logger

  @client HTTPoison
  @res HTTPoison.Response
  @err HTTPoison.Error
  @timeout 180_000

  typed_schema "resource" do
    field(:is_active, :boolean)
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
    # automatically discovered tags
    field(:auto_tags, {:array, :string}, default: [])
    field(:conversion_latest_content_hash, :string)

    field(:is_community_resource, :boolean)
    # only relevant for community resources, name of the owner or the organization that published the resource
    field(:community_resource_publisher, :string)
    field(:description, :string)

    # we add 2 fields, that are already in the metadata json, in order to be able to add some indices
    field(:start_date, :date)
    field(:end_date, :date)

    belongs_to(:dataset, Dataset)
    has_one(:validation, Validation, on_replace: :delete)
  end

  @spec endpoint() :: binary()
  def endpoint, do: Application.get_env(:transport, :gtfs_validator_url) <> "/validate"

  @doc """
  A validation is needed if the last update from the data is newer than the last validation.
  ## Examples

    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha",
    ...> validation: %Validation{validation_latest_content_hash: "a_sha"}}, false)
    false
    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha",
    ...> validation: %Validation{validation_latest_content_hash: "a_sha"}}, true)
    true
    iex> Resource.needs_validation(%Resource{format: "gbfs", content_hash: "a_sha",
    ...> validation: %Validation{validation_latest_content_hash: "a_sha"}}, false)
    false
    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha"}, false)
    true
    iex> Resource.needs_validation(%Resource{format: "gtfs-rt", content_hash: "a_sha"}, true)
    false
    iex> Resource.needs_validation(%Resource{format: "GTFS", content_hash: "a_sha",
    ...> validation: %Validation{validation_latest_content_hash: "another_sha"}}, false)
    true
  """
  @spec needs_validation(__MODULE__.t(), boolean()) :: boolean()
  def needs_validation(%__MODULE__{format: format}, _force_validation) when format != "GTFS" do
    # we only want to validate GTFS
    false
  end

  def needs_validation(%__MODULE__{}, true = _force_validation) do
    true
  end

  def needs_validation(
        %__MODULE__{
          content_hash: content_hash,
          validation: %Validation{validation_latest_content_hash: validation_latest_content_hash}
        } = r,
        _force_validation
      ) do
    # if there is already a validation, we revalidate only if the file has changed
    if content_hash != validation_latest_content_hash do
      Logger.info("the files for resource #{r.id} have been modified since last validation, we need to revalidate them")
      true
    else
      false
    end
  end

  def needs_validation(%__MODULE__{}, _force_validation) do
    # if there is no validation, we want to validate
    true
  end

  @spec validate_and_save(__MODULE__.t()) :: {:error, any} | {:ok, nil}
  def validate_and_save(%__MODULE__{} = resource) do
    Logger.info("Validating #{resource.url}")

    with {:ok, validations} <- validate(resource),
         {:ok, _} <- save(resource, validations) do
      {:ok, nil}
    else
      {:error, error} ->
        Logger.warn("Error when calling the validator: #{error}")

        Sentry.capture_message("unable_to_call_validator",
          extra: %{url: resource.url, error: error}
        )

        {:error, error}
    end
  rescue
    e ->
      Logger.error("error while validating resource #{resource.id}: #{inspect(e)}")
      {:error, e}
  end

  @spec validate(__MODULE__.t()) :: {:error, any} | {:ok, map()}
  def validate(%__MODULE__{url: nil}), do: {:error, "No url"}

  def validate(%__MODULE__{url: url, format: "GTFS"}) do
    case @client.get("#{endpoint()}?url=#{URI.encode_www_form(url)}", [], recv_timeout: @timeout) do
      {:ok, %@res{status_code: 200, body: body}} -> Poison.decode(body)
      {:ok, %@res{body: body}} -> {:error, body}
      {:error, %@err{reason: error}} -> {:error, error}
      _ -> {:error, "Unknown error in validation"}
    end
  end

  def validate(%__MODULE__{format: f, id: id}) do
    Logger.info("cannot validate resource id=#{id} because we don't know how to validate the #{f} format")
    {:ok, %{"validations" => nil, "metadata" => nil}}
  end

  @spec save(__MODULE__.t(), map()) :: {:ok, any()} | {:error, any()}
  def save(%__MODULE__{id: id, url: url, format: format} = r, %{
        "validations" => validations,
        "metadata" => metadata
      }) do
    # When the validator is unable to open the archive, it will return a fatal issue
    # And the metadata will be nil (as it couldn’t read them)
    if is_nil(metadata) and format == "GTFS",
      do: Logger.warn("Unable to validate resource (id = #{id})")

    __MODULE__
    |> preload(:validation)
    |> Repo.get(id)
    |> change(
      metadata: metadata,
      validation: %Validation{
        date: DateTime.utc_now() |> DateTime.to_string(),
        details: validations,
        max_error: get_max_severity_error(validations),
        validation_latest_content_hash: r.content_hash
      },
      auto_tags: find_tags(r, metadata),
      content_hash: Hasher.get_content_hash(url),
      start_date: str_to_date(metadata["start_date"]),
      end_date: str_to_date(metadata["end_date"])
    )
    |> Repo.update()
  end

  def save(url, _) do
    Logger.warn("Unknown error when saving the validation")
    Sentry.capture_message("validation_save_failed", extra: url)
  end

  # for the moment the tag detection is very simple, we only add the modes
  @spec find_tags(__MODULE__.t(), map()) :: [binary()]
  def find_tags(%__MODULE__{} = _r, %{"modes" => modes}) do
    modes
  end

  def find_tags(%__MODULE__{} = _r, _) do
    []
  end

  def changeset(resource, params) do
    resource
    |> cast(
      params,
      [
        :is_active,
        :url,
        :format,
        :last_import,
        :title,
        :metadata,
        :id,
        :last_update,
        :latest_url,
        :is_available,
        :auto_tags,
        :is_community_resource,
        :community_resource_publisher,
        :description
      ]
    )
    |> validate_required([:url])
  end

  @spec issues_short_translation() :: %{binary() => binary()}
  def issues_short_translation,
    do: %{
      "UnusedStop" => dgettext("validations", "Unused stops"),
      "Slow" => dgettext("validations", "Slow"),
      "ExcessiveSpeed" => dgettext("validations", "Excessive speed between two stops"),
      "NegativeTravelTime" => dgettext("validations", "Negative travel time between two stops"),
      "CloseStops" => dgettext("validations", "Close stops"),
      "NullDuration" => dgettext("validations", "Null duration between two stops"),
      "InvalidReference" => dgettext("validations", "Invalid reference"),
      "InvalidArchive" => dgettext("validations", "Invalid archive"),
      "MissingRouteName" => dgettext("validations", "Missing route name"),
      "MissingId" => dgettext("validations", "Missing id"),
      "MissingCoordinates" => dgettext("validations", "Missing coordinates"),
      "MissingName" => dgettext("validations", "Missing name"),
      "InvalidCoordinates" => dgettext("validations", "Invalid coordinates"),
      "InvalidRouteType" => dgettext("validations", "Invalid route type"),
      "MissingUrl" => dgettext("validations", "Missing url"),
      "InvalidUrl" => dgettext("validations", "Invalid url"),
      "InvalidTimezone" => dgettext("validations", "Invalid timezone"),
      "DuplicateStops" => dgettext("validations", "Duplicate stops"),
      "MissingPrice" => dgettext("validations", "Missing price"),
      "InvalidCurrency" => dgettext("validations", "Invalid currency"),
      "InvalidTransfers" => dgettext("validations", "Invalid transfers"),
      "InvalidTransferDuration" => dgettext("validations", "Invalid transfer duration"),
      "MissingLanguage" => dgettext("validations", "Missing language"),
      "InvalidLanguage" => dgettext("validations", "Invalid language"),
      "DupplicateObjectId" => dgettext("validations", "Dupplicate object id"),
      "UnloadableModel" => dgettext("validations", "Not compliant with the GTFS specification"),
      "MissingMandatoryFile" => dgettext("validations", "Missing mandatory file"),
      "ExtraFile" => dgettext("validations", "Extra file"),
      "ImpossibleToInterpolateStopTimes" => dgettext("validations", "Impossible to interpolate stop times")
    }

  @spec valid?(__MODULE__.t()) :: boolean()
  def valid?(%__MODULE__{} = r), do: r.metadata != nil

  @spec is_outdated?(__MODULE__) :: boolean
  def is_outdated?(%__MODULE__{metadata: %{"end_date" => nil}}), do: false

  def is_outdated?(%__MODULE__{metadata: %{"end_date" => end_date}}),
    do: end_date <= Date.utc_today() |> Date.to_iso8601()

  def is_outdated?(_), do: true

  @spec get_max_severity_validation_number(__MODULE__) :: map() | nil
  def get_max_severity_validation_number(%__MODULE__{id: id}) do
    """
      SELECT json_data.value#>'{0,severity}', json_array_length(json_data.value)
      FROM validations, json_each(validations.details) json_data
      WHERE validations.resource_id = $1
    """
    |> Repo.query([id])
    |> case do
      {:ok, %{rows: rows}} when rows != [] ->
        [max_severity | _] =
          Enum.min_by(
            rows,
            fn [severity | _] -> Validation.severities(severity)[:level] end,
            fn -> nil end
          )

        count_errors =
          rows
          |> Enum.filter(fn [severity, _] -> severity == max_severity end)
          |> Enum.reduce(0, fn [_, nb], acc -> acc + nb end)

        %{severity: max_severity, count_errors: count_errors}

      {:ok, _} ->
        if Repo.get_by(Validation, resource_id: id).details == %{} do
          %{severity: "Irrevelant", count_errors: 0}
        else
          Logger.error("Unable to get validation of resource #{id}")
          nil
        end

      {:error, error} ->
        Logger.error(error)
        nil
    end
  end

  def get_max_severity_validation_number(_), do: nil

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

  @spec other_resources_query(__MODULE__.t()) :: Ecto.Query.t()
  def other_resources_query(%__MODULE__{} = resource),
    do:
      from(r in __MODULE__,
        where: r.dataset_id == ^resource.dataset_id and r.id != ^resource.id and not is_nil(r.metadata)
      )

  @spec other_resources(__MODULE__.t()) :: [__MODULE__.t()]
  def other_resources(%__MODULE__{} = r), do: r |> other_resources_query() |> Repo.all()

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
end
