resource "aws_kinesis_firehose_delivery_stream" "this" {
  name        = "${var.name_prefix}-data-collection"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn   = aws_iam_role.firehose_role.arn
    bucket_arn = aws_s3_bucket.dataLake.arn

    prefix              = "raw-data/!{partitionKeyFromQuery:year}/!{partitionKeyFromQuery:month}/!{partitionKeyFromQuery:day}/"
    error_output_prefix = "errors/!{timestamp:yyyy}/!{timestamp:MM}/!{timestamp:dd}/!{timestamp:HH}/!{firehose:error-output-type}/"

    buffer_size = 64

    dynamic_partitioning_configuration {
      enabled = "true"
    }

    processing_configuration {
      enabled = "true"

      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{year:.data[0].created_at[0:4],month:.data[0].created_at[5:7],day:.data[0].created_at[8:10]}"
        }
      }
    }
  }
}

resource "aws_s3_bucket" "dataLake" {
  bucket        = "${var.name_prefix}-datalake"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "dataLake" {
  bucket                  = aws_s3_bucket.dataLake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "firehose_role" {
  name = "${var.name_prefix}-firehose-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "firehose.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "firehose-s3" {
  name   = "s3"
  role   = aws_iam_role.firehose_role.id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF
}