# terraform-aws-state-backend

Reusable Terraform module that provisions an S3 backend bucket for Terraform state with:

- S3 account-regional namespace to prevent bucketsquatting
- SSE-S3 by default, with optional SSE-KMS mode
- Bucket versioning and public access blocking
- Bucket policy guardrails for TLS-only, same-account, and encryption-algorithm enforcement
- Separate IAM policies for state read, state write, and lockfile access

The bucket is always created in your account's [account-regional namespace](https://aws.amazon.com/blogs/aws/introducing-account-regional-namespaces-for-amazon-s3-general-purpose-buckets/). The full bucket name is constructed as `<bucket_name>-<account_id>-<region>-an`, ensuring only your account can own names with your suffix.

This module is designed so you can attach least-privilege policies by workflow:

- Plan-only users: read policy
- Apply users: read + write policies
- Lock-capable plan/apply users: add lock policy when using backend locking

## Usage

```hcl
module "terraform_state_backend" {
  source = "rsclarke/state-backend/aws"

  bucket_name = "my-org-terraform-state"
  # Optional: set true to enforce SSE-KMS instead of SSE-S3.
  # If true and kms_key_arn is null, the module creates a dedicated KMS key.
  # use_kms    = true
  # kms_key_arn = "arn:aws:kms:eu-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"

  # Creates bucket: my-org-terraform-state-123456789012-eu-west-2-an
}

# Examples of role/policy attachment outside this module:
#
# - plan role:   attach module.terraform_state_backend.read_policy_arn
# - apply role:  attach module.terraform_state_backend.read_policy_arn
#                + module.terraform_state_backend.write_policy_arn
# - lock role:   attach module.terraform_state_backend.lock_policy_arn
# - bucket name: use module.terraform_state_backend.bucket_name for the full
#                computed bucket name (in backend config/CLI args)
```

## Backend Configuration And Lockfile Intent

This module supports S3 native lockfiles (`use_lockfile = true`) rather than DynamoDB locking.

Typical backend usage:

```hcl
terraform {
  backend "s3" {
    bucket       = "my-org-terraform-state-123456789012-eu-west-2-an"
    key          = "envs/prod/network/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    use_lockfile = true
  }
}
```

With this module, `encrypt = true` uses SSE-S3 by default and no `kms_key_id` is required.

If `use_kms = true`, the bucket policy enforces SSE-KMS writes to the configured key and backend clients must provide `kms_key_id`.

The bucket policy denies `PutObject` requests that omit encryption headers or use a different encryption algorithm than the configured mode.

Note: backend blocks cannot reference variables, resources, or module outputs directly. Provide backend values via static backend config (for example, a generated `backend.hcl`) or `terraform init -backend-config=...` arguments.

Typical backend usage for KMS mode:

```hcl
terraform {
  backend "s3" {
    bucket       = "my-org-terraform-state-123456789012-eu-west-2-an"
    key          = "envs/prod/network/terraform.tfstate"
    region       = "eu-west-2"
    encrypt      = true
    kms_key_id   = "arn:aws:kms:eu-west-2:123456789012:key/11111111-2222-3333-4444-555555555555"
    use_lockfile = true
  }
}
```

Operational guidance:

- For speculative plans, you can run `terraform plan -lock=false` with only read access.
- For plans that should acquire a lock (`terraform plan -lock=true`) and for apply operations, include lock permissions.
- Apply workflows usually need read + write + lock policy attachment.

## Lifecycle And Version Retention

The bucket has versioning enabled, which means every state write and lockfile operation creates object versions that accumulate over time:

- **State files** — each `terraform apply` overwrites the `.tfstate` object, pushing the previous version to noncurrent. These noncurrent versions provide a rollback window if state becomes corrupted or needs to be recovered.
- **Lock files** — each `terraform plan` or `apply` with `use_lockfile = true` creates a `.tflock` object and then deletes it. This creates a noncurrent version and a delete marker per lock/unlock cycle, which can add up quickly in active CI pipelines.

Without lifecycle rules, these versions and delete markers grow indefinitely. The module includes a lifecycle configuration with one tuneable variable and automatic delete marker cleanup:

| Variable | Default | Purpose |
|----------|---------|---------|
| `noncurrent_version_expiration_days` | `90` | How long to keep old state file versions before they are permanently deleted. A 90-day window covers most incident recovery scenarios. Increase this if your compliance or operational requirements demand longer retention. |

Expired object delete markers (the empty tombstones left after all noncurrent versions of a deleted object are gone) are cleaned up automatically by the lifecycle rule. These are primarily generated by lockfile churn and have no operational value once the associated versions are gone.

## Trust Model And Limitations

This module assumes delegated trust within a single AWS management account, where principals using the backend are trusted operators of related infrastructure.

The exported read/write/lock IAM policies are bucket-wide and lockfile-wide by design (`${bucket}/*` and `${bucket}/*.tflock`). In a shared backend bucket, principals with these policies can access other state objects and interfere with other lockfiles.

If you need stricter separation between teams, environments, or workspaces, attach caller-managed path-scoped IAM policies instead of (or in addition to) the broad module outputs.

Common approaches are one backend bucket per trust boundary, or key-prefix-scoped policies for each role that restrict `s3:ListBucket` with `s3:prefix` and restrict object/lockfile actions to specific state paths.

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.7 |
| aws | >= 6.37.0 |

## Providers

| Name | Version |
|------|---------|
| aws | >= 6.37.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| bucket_name | Prefix for the S3 bucket name. The account-regional suffix is appended automatically. | `string` | n/a | yes |
| noncurrent_version_expiration_days | Number of days to retain noncurrent object versions before expiration. | `number` | `90` | no |
| use_kms | Enable SSE-KMS mode. When false, SSE-S3 (`AES256`) is enforced. | `bool` | `false` | no |
| kms_key_arn | Existing KMS key ARN to use when `use_kms = true`. If null, the module creates a dedicated key. | `string` | `null` | no |

## Outputs

| Name | Description |
|------|-------------|
| bucket_name | Full name of the S3 bucket (including account-regional suffix) |
| bucket_arn | ARN of the S3 bucket |
| read_policy_arn | ARN of the IAM policy granting read access to state |
| write_policy_arn | ARN of the IAM policy granting write access to state |
| lock_policy_arn | ARN of the IAM policy granting lockfile access to state |
| kms_key_arn | Effective KMS key ARN when `use_kms = true`, otherwise `null` |
