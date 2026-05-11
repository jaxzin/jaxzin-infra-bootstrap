terraform {
  backend "s3" {
    # All concrete settings are supplied via `tofu init -backend-config=...`
    # at run time so no topology lives in this file.
    #
    # Required at init:
    #   endpoint                   - B2 S3-compat endpoint URL
    #   bucket                     - state bucket name
    #   key                        - "tofu-state/jaxzin-infra-bootstrap/network.tfstate"
    #   region                     - any value B2 accepts; "us-west-002" is typical
    #   skip_credentials_validation - true (B2 doesn't implement STS)
    #   skip_metadata_api_check     - true (no EC2 metadata)
    #   skip_region_validation      - true (B2 region naming differs from AWS)
    #   skip_requesting_account_id  - true (B2 doesn't expose AWS account IDs)
    #   use_lockfile                - true (S3 conditional-write locks)
    #   force_path_style            - true (B2 requires path-style addressing)
  }
}
