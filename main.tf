data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.region

  bucket_name            = "${var.bucket_name}-${local.account_id}-${local.region}-an"
  kms_enabled            = var.use_kms
  create_kms_key         = var.use_kms && var.kms_key_arn == null
  effective_kms_key_arn  = var.use_kms ? coalesce(var.kms_key_arn, try(aws_kms_key.this[0].arn, null)) : null
  required_sse_algorithm = var.use_kms ? "aws:kms" : "AES256"
}

# -----------------------------------------------------------------------------
# Optional KMS Key for encrypting Terraform state
# -----------------------------------------------------------------------------

resource "aws_kms_key" "this" {
  count = local.create_kms_key ? 1 : 0

  description             = "Encrypts Terraform state objects in S3"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  policy = data.aws_iam_policy_document.kms[0].json
}

data "aws_iam_policy_document" "kms" {
  count = local.create_kms_key ? 1 : 0

  # Key administrators – manage the key lifecycle
  statement {
    sid    = "AllowKeyAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    actions = [
      "kms:Create*",
      "kms:Describe*",
      "kms:Enable*",
      "kms:List*",
      "kms:Put*",
      "kms:Update*",
      "kms:Revoke*",
      "kms:Disable*",
      "kms:Get*",
      "kms:Delete*",
      "kms:TagResource",
      "kms:UntagResource",
      "kms:ScheduleKeyDeletion",
      "kms:CancelKeyDeletion",
    ]

    resources = ["*"]
  }

  # Key users – cryptographic operations via S3 only
  statement {
    sid    = "AllowKeyUsageViaS3"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }

    actions = [
      "kms:Decrypt",
      "kms:DescribeKey",
      "kms:Encrypt",
      "kms:GenerateDataKey*",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [local.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:EncryptionContext:aws:s3:arn"
      values   = [aws_s3_bucket.this.arn]
    }
  }
}

# -----------------------------------------------------------------------------
# S3 Bucket for Terraform state
# -----------------------------------------------------------------------------

resource "aws_s3_bucket" "this" {
  bucket           = local.bucket_name
  bucket_namespace = "account-regional"
}

resource "aws_s3_bucket_versioning" "this" {
  bucket = aws_s3_bucket.this.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = local.required_sse_algorithm
      kms_master_key_id = local.kms_enabled ? local.effective_kms_key_arn : null
    }

    bucket_key_enabled = local.kms_enabled ? true : null
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_lifecycle_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_expiration_days
    }

    expiration {
      expired_object_delete_marker = true
    }
  }
}

resource "aws_s3_bucket_ownership_controls" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_policy" "this" {
  bucket = aws_s3_bucket.this.id
  policy = data.aws_iam_policy_document.bucket.json

  depends_on = [aws_s3_bucket_public_access_block.this]
}

data "aws_iam_policy_document" "bucket" {
  # Deny any request that does not use TLS
  statement {
    sid    = "DenyInsecureTransport"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }

  # Restrict bucket access to the management account only
  statement {
    sid    = "DenyCrossAccountAccess"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:*"]
    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "aws:PrincipalAccount"
      values   = [local.account_id]
    }
  }

  # Require clients to explicitly send SSE headers for PutObject
  statement {
    sid    = "DenyMissingSSEHeader"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "Null"
      variable = "s3:x-amz-server-side-encryption"
      values   = ["true"]
    }
  }

  # Require configured server-side encryption algorithm for object writes
  statement {
    sid    = "DenyIncorrectSSEAlgorithm"
    effect = "Deny"

    principals {
      type        = "*"
      identifiers = ["*"]
    }

    actions = ["s3:PutObject"]
    resources = [
      "${aws_s3_bucket.this.arn}/*",
    ]

    condition {
      test     = "StringNotEquals"
      variable = "s3:x-amz-server-side-encryption"
      values   = [local.required_sse_algorithm]
    }
  }

  dynamic "statement" {
    for_each = local.kms_enabled ? [1] : []

    content {
      # Require the configured CMK for object writes
      sid    = "DenyWrongKMSKey"
      effect = "Deny"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      actions = ["s3:PutObject"]
      resources = [
        "${aws_s3_bucket.this.arn}/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["aws:kms"]
      }

      condition {
        test     = "StringNotEquals"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = [local.effective_kms_key_arn]
      }
    }
  }

  dynamic "statement" {
    for_each = local.kms_enabled ? [1] : []

    content {
      # If SSE-KMS is requested, require callers to provide a KMS key ID header
      sid    = "DenyMissingKMSKeyId"
      effect = "Deny"

      principals {
        type        = "*"
        identifiers = ["*"]
      }

      actions = ["s3:PutObject"]
      resources = [
        "${aws_s3_bucket.this.arn}/*",
      ]

      condition {
        test     = "StringEquals"
        variable = "s3:x-amz-server-side-encryption"
        values   = ["aws:kms"]
      }

      condition {
        test     = "Null"
        variable = "s3:x-amz-server-side-encryption-aws-kms-key-id"
        values   = ["true"]
      }
    }
  }
}

# -----------------------------------------------------------------------------
# IAM Policies for state backend access
# -----------------------------------------------------------------------------

resource "aws_iam_policy" "read" {
  name        = "${local.bucket_name}-read"
  description = "Read access to Terraform state"
  policy      = data.aws_iam_policy_document.read.json
}

data "aws_iam_policy_document" "read" {
  statement {
    sid    = "AllowStateRead"
    effect = "Allow"

    actions = [
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
    ]

    resources = [
      aws_s3_bucket.this.arn,
      "${aws_s3_bucket.this.arn}/*",
    ]
  }

  dynamic "statement" {
    for_each = local.kms_enabled ? [1] : []

    content {
      sid    = "AllowKMSDecrypt"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
      ]

      resources = [local.effective_kms_key_arn]
    }
  }
}

resource "aws_iam_policy" "write" {
  name        = "${local.bucket_name}-write"
  description = "Write access to Terraform state"
  policy      = data.aws_iam_policy_document.write.json
}

resource "aws_iam_policy" "lock" {
  name        = "${local.bucket_name}-lock"
  description = "Access to Terraform state lock files"
  policy      = data.aws_iam_policy_document.lock.json
}

data "aws_iam_policy_document" "write" {
  statement {
    sid    = "AllowStateWrite"
    effect = "Allow"

    actions = [
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "${aws_s3_bucket.this.arn}/*",
    ]
  }

  dynamic "statement" {
    for_each = local.kms_enabled ? [1] : []

    content {
      sid    = "AllowKMSEncrypt"
      effect = "Allow"

      actions = [
        "kms:Encrypt",
        "kms:GenerateDataKey*",
      ]

      resources = [local.effective_kms_key_arn]
    }
  }
}

data "aws_iam_policy_document" "lock" {
  statement {
    sid    = "AllowStateLockfileAccess"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
    ]

    resources = [
      "${aws_s3_bucket.this.arn}/*.tflock",
    ]
  }

  dynamic "statement" {
    for_each = local.kms_enabled ? [1] : []

    content {
      sid    = "AllowKMSForLockfileAccess"
      effect = "Allow"

      actions = [
        "kms:Decrypt",
        "kms:DescribeKey",
        "kms:Encrypt",
        "kms:GenerateDataKey*",
      ]

      resources = [local.effective_kms_key_arn]
    }
  }
}
