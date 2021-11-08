use Mix.Config

# Configure GBFS Validator
config :transport,
  gbfs_validator_impl: Shared.Validation.GBFSValidator.HTTPClient,
  # This endpoint is not really public but we can use it for now
  # See https://github.com/MobilityData/gbfs-validator/issues/53#issuecomment-957917240
  gbfs_validator_url: System.get_env("GBFS_VALIDATOR_URL", "https://gbfs-validator.netlify.app/.netlify/functions/validator")
