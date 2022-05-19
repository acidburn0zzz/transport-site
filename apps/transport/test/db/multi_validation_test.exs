defmodule DB.MultiValidationTest do
  use ExUnit.Case, async: true
  doctest DB.MultiValidation
  import DB.Factory

  setup do
    Ecto.Adapters.SQL.Sandbox.checkout(DB.Repo)
  end

  test "already validated" do
    %{id: resource_history_id} = resource_history = insert(:resource_history)

    refute DB.MultiValidation.already_validated?(resource_history, Transport.Validators.Dummy)

    # wrong validator name
    insert(:multi_validation, %{validator: "random validator", resource_history_id: resource_history_id})
    refute DB.MultiValidation.already_validated?(resource_history, Transport.Validators.Dummy)

    insert(:multi_validation, %{
      validator: Transport.Validators.Dummy.validator_name(),
      resource_history_id: resource_history_id
    })

    assert DB.MultiValidation.already_validated?(resource_history, Transport.Validators.Dummy)
  end

  describe "get latest associated multi validation" do
    test "get resource latest validation" do
      now = DateTime.utc_now()
      before60 = DateTime.utc_now() |> DateTime.add(-60)
      before90 = DateTime.utc_now() |> DateTime.add(-90)

      validator = Transport.Validators.GTFSTransport
      validator_name = validator.validator_name()

      # one dataset
      %{id: dataset_id} = insert(:dataset)

      # one resource
      %{id: resource_id} = insert(:resource, %{datagouv_id: datagouv_id = "datagouv_id", dataset_id: dataset_id})

      # one resource history with some validations
      %{id: resource_history_id_latest} = insert(:resource_history, %{datagouv_id: datagouv_id, inserted_at: now})

      insert(:multi_validation, %{
        resource_history_id: resource_history_id_latest,
        validator: "other",
        validation_timestamp: now
      })

      insert(:multi_validation, %{
        resource_history_id: resource_history_id_latest,
        validator: validator_name,
        validation_timestamp: before90
      })

      %{id: mv_id} =
        insert(:multi_validation, %{
          resource_history_id: resource_history_id_latest,
          validator: validator_name,
          validation_timestamp: before60
        })

      # a second older resource history
      %{id: resource_history_id} = insert(:resource_history, %{datagouv_id: datagouv_id, inserted_at: before60})

      # with a very recent validation (it's a trap!)
      insert(:multi_validation, %{
        resource_history_id: resource_history_id,
        validator: validator_name,
        validation_timestamp: now
      })

      assert %{id: ^mv_id, resource_history_id: ^resource_history_id_latest} =
               DB.MultiValidation.resource_latest_validation(resource_id, validator)

      dataset_validations = DB.MultiValidation.dataset_latest_validation(dataset_id, [validator])

      assert [%{id: ^mv_id, resource_history_id: ^resource_history_id_latest}] =
               dataset_validations |> Map.get(resource_id)
    end

    test "no resource latest validation, resource alone" do
      validator = Transport.Validators.GTFSTransport
      %{id: dataset_id} = insert(:dataset)
      %{id: resource_id} = insert(:resource, %{dataset_id: dataset_id})

      assert nil == DB.MultiValidation.resource_latest_validation(resource_id, validator)

      dataset_validations = DB.MultiValidation.dataset_latest_validation(dataset_id, [validator])
      assert [nil] == dataset_validations |> Map.get(resource_id, "nothing")
    end

    test "no resource latest validation, resource + resource_history" do
      validator = Transport.Validators.GTFSTransport
      %{id: dataset_id} = insert(:dataset)
      %{id: resource_id} = insert(:resource, %{dataset_id: dataset_id, datagouv_id: datagouv_id = "datagouv_id"})
      insert(:resource_history, %{datagouv_id: datagouv_id})

      assert nil == DB.MultiValidation.resource_latest_validation(resource_id, validator)

      dataset_validations = DB.MultiValidation.dataset_latest_validation(dataset_id, [validator])
      assert [nil] == dataset_validations |> Map.get(resource_id, "nothing")
    end

    test "no resource latest validation with specified validator" do
      validator = Transport.Validators.GTFSTransport
      %{id: dataset_id} = insert(:dataset)
      %{id: resource_id} = insert(:resource, %{dataset_id: dataset_id, datagouv_id: datagouv_id = "datagouv_id"})
      %{id: resource_history_id} = insert(:resource_history, %{datagouv_id: datagouv_id})

      insert(:multi_validation, %{
        resource_history_id: resource_history_id,
        validator: "other_validator_name"
      })

      assert nil == DB.MultiValidation.resource_latest_validation(resource_id, validator)

      dataset_validations = DB.MultiValidation.dataset_latest_validation(dataset_id, [validator])
      assert [nil] == dataset_validations |> Map.get(resource_id, "nothing")
    end

    test "dataset validations, multiple resources and validators" do
      validator_1 = Transport.Validators.GTFSTransport
      validator_1_name = validator_1.validator_name()
      validator_2 = Transport.Validators.Dummy
      validator_2_name = validator_2.validator_name()

      %{id: dataset_id} = insert(:dataset)

      %{id: resource_id_1} = insert(:resource, %{dataset_id: dataset_id, datagouv_id: datagouv_id_1 = "datagouv_id_1"})
      %{id: resource_id_2} = insert(:resource, %{dataset_id: dataset_id, datagouv_id: datagouv_id_2 = "datagouv_id_2"})
      %{id: resource_id_3} = insert(:resource, %{dataset_id: dataset_id, datagouv_id: "datagouv_id_3"})

      %{id: resource_history_id_1} = insert(:resource_history, %{datagouv_id: datagouv_id_1})
      %{id: resource_history_id_2} = insert(:resource_history, %{datagouv_id: datagouv_id_2})

      insert(:multi_validation, %{
        resource_history_id: resource_history_id_1,
        validator: validator_1.validator_name()
      })

      insert(:multi_validation, %{
        resource_history_id: resource_history_id_1,
        validator: validator_2.validator_name()
      })

      insert(:multi_validation, %{
        resource_history_id: resource_history_id_2,
        validator: validator_1.validator_name()
      })

      validations = DB.MultiValidation.dataset_latest_validation(dataset_id, [validator_1, validator_2])

      resource_1_validations = validations |> Map.get(resource_id_1) |> Enum.sort_by(fn %{id: id} -> id end)

      assert [
               %{resource_history_id: ^resource_history_id_1, validator: ^validator_1_name},
               %{resource_history_id: ^resource_history_id_1, validator: ^validator_2_name}
             ] = resource_1_validations

      assert [%{resource_history_id: ^resource_history_id_2, validator: ^validator_1_name}] =
               validations |> Map.get(resource_id_2)

      assert [nil] = validations |> Map.get(resource_id_3)
    end
  end
end