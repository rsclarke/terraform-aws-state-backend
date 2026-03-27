variable "bucket_name" {
  description = "Prefix for the S3 bucket name. The account-regional suffix (-<account_id>-<region>-an) is appended automatically."
  type        = string

  validation {
    condition     = length(var.bucket_name) <= 32 && can(regex("^[a-z0-9][a-z0-9-]*[a-z0-9]$", var.bucket_name))
    error_message = "Bucket name prefix must be <= 32 characters, contain only lowercase alphanumeric characters and hyphens, and not start or end with a hyphen."
  }
}

variable "noncurrent_version_expiration_days" {
  description = "Number of days to retain noncurrent object versions before expiration."
  type        = number
  default     = 90
}

variable "use_kms" {
  description = "Enable SSE-KMS instead of SSE-S3. When true, this module enforces aws:kms object encryption."
  type        = bool
  default     = false
}

variable "kms_key_arn" {
  description = "Existing KMS key ARN to use when use_kms is true. If null, this module creates and manages a dedicated KMS key."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_arn == null || can(regex("^arn:aws[a-zA-Z-]*:kms:[^:]+:[0-9]{12}:key/.+$", var.kms_key_arn))
    error_message = "kms_key_arn must be null or a valid KMS key ARN."
  }
}

