data "aws_caller_identity" "this" {}

locals {
  raw_data_location_prefix    = "raw"
  tweets_data_location_prefix = "tweets"
}

###### S3 ######
resource "aws_s3_bucket" "dataLake" {
  bucket        = "${var.name_prefix}-datalake"
  force_destroy = var.s3_force_destroy
}

resource "aws_s3_bucket_public_access_block" "dataLake" {
  bucket                  = aws_s3_bucket.dataLake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket" "assets" {
  bucket        = "${var.name_prefix}-assets-bucket"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "code_public_access_block" {
  bucket                  = aws_s3_bucket.assets.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

################# Data Collection #################
module "firehose_lambda_transformation" {
  count                             = var.enable_data_collection ? 1 : 0
  source                            = "terraform-aws-modules/lambda/aws"
  function_name                     = "${var.name_prefix}-tweets-transformation"
  description                       = "Lambda to transform tweets records"
  handler                           = "index.lambda_handler"
  runtime                           = "python3.9"
  source_path                       = "${path.module}/02 - data-transformation-lambda"
  recreate_missing_package          = true
  ignore_source_code_hash           = true
  build_in_docker                   = true
  docker_pip_cache                  = true
  memory_size                       = 512
  timeout                           = 900
  cloudwatch_logs_retention_in_days = 5
  attach_policy_json                = false

}

resource "aws_iam_role" "firehose_role" {
  count = var.enable_data_collection ? 1 : 0
  name  = "${var.name_prefix}-firehose-role"

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
  count  = var.enable_data_collection ? 1 : 0
  name   = "s3"
  role   = aws_iam_role.firehose_role[0].id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:*"
      ],
      "Resource": [
        "${aws_s3_bucket.dataLake.arn}",
        "${aws_s3_bucket.dataLake.arn}/*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "firehose-lambda" {
  count  = var.enable_data_collection ? 1 : 0
  name   = "lambda"
  role   = aws_iam_role.firehose_role[0].id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:InvokeFunction",
        "lambda:GetFunctionConfiguration"
      ],
      "Resource": "${module.firehose_lambda_transformation[0].lambda_function_arn}:*"
    }
  ]
}
EOF
}

resource "aws_kinesis_firehose_delivery_stream" "this" {
  count       = var.enable_data_collection ? 1 : 0
  name        = "${var.name_prefix}-data-collection"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn        = aws_iam_role.firehose_role[0].arn
    bucket_arn      = aws_s3_bucket.dataLake.arn
    buffer_interval = 60
    buffer_size     = 64

    prefix              = "${local.raw_data_location_prefix}/year=!{partitionKeyFromQuery:year}/month=!{partitionKeyFromQuery:month}/day=!{partitionKeyFromQuery:day}/"
    error_output_prefix = "errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/error=!{firehose:error-output-type}/"

    s3_backup_mode = "Enabled"
    s3_backup_configuration {
      role_arn            = aws_iam_role.firehose_role[0].arn
      bucket_arn          = aws_s3_bucket.dataLake.arn
      prefix              = "original-data/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
      error_output_prefix = "original-data-errors/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/error=!{firehose:error-output-type}/"
      buffer_interval     = 300
      compression_format  = "GZIP"
    }

    dynamic_partitioning_configuration {
      enabled = "true"
    }

    processing_configuration {
      enabled = "true"

      processors {
        type = "AppendDelimiterToRecord"
      }

      processors {
        type = "Lambda"

        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = "${module.firehose_lambda_transformation[0].lambda_function_arn}:$LATEST"
        }
      }

      processors {
        type = "MetadataExtraction"
        parameters {
          parameter_name  = "JsonParsingEngine"
          parameter_value = "JQ-1.6"
        }
        parameters {
          parameter_name  = "MetadataExtractionQuery"
          parameter_value = "{year:.created_at[0:4],month:.created_at[5:7],day:.created_at[8:10]}"
        }
      }
    }
  }
}

################# GLUE #################
###### ETL ######
data "template_file" "drop_duplicates" {
  count    = var.enable_etl ? 1 : 0
  template = file("${path.module}/03 - drop-duplicates-script/drop-duplicates.py")
  vars = {
    S3_INPUT_BUCKET_URI  = "s3://${aws_s3_bucket.dataLake.bucket}/${local.raw_data_location_prefix}"
    S3_OUTPUT_BUCKET_URI = "s3://${aws_s3_bucket.dataLake.bucket}/${local.tweets_data_location_prefix}"
  }
}

resource "aws_s3_object" "drop_duplicates" {
  count   = var.enable_etl ? 1 : 0
  bucket  = aws_s3_bucket.assets.bucket
  key     = "drop_duplicates.py"
  content = data.template_file.drop_duplicates[0].rendered
}

resource "aws_glue_job" "drop_duplicates" {
  count             = var.enable_etl ? 1 : 0
  name              = "${var.name_prefix}-drop-duplicates"
  role_arn          = aws_iam_role.glue_job_drop_duplicates_role[0].arn
  description       = "Glue Job to drop duplicated tweets"
  glue_version      = "3.0"
  worker_type       = "G.1X"
  number_of_workers = 10

  command {
    script_location = "s3://${aws_s3_bucket.assets.bucket}/${aws_s3_object.drop_duplicates[0].key}"
    python_version  = 3
  }

  default_arguments = {
    "--job-bookmark-option" : "job-bookmark-enable"
    "--class"                 = "GlueApp"
    "--job-language"          = "python"
    "--TempDir"               = "s3://${aws_s3_bucket.assets.bucket}/temporary"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.assets.bucket}/sparkHistoryLogs"
  }
}

resource "aws_iam_role" "glue_job_drop_duplicates_role" {
  count = var.enable_etl ? 1 : 0
  name  = "${var.name_prefix}-glue-job-drop-duplicates-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "glue.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "glue_job_drop_duplicates_policy" {
  count  = var.enable_etl ? 1 : 0
  name   = "s3"
  role   = aws_iam_role.glue_job_drop_duplicates_role[0].id
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

###### Data Catalog ######
resource "aws_glue_catalog_database" "this" {
  count      = var.enable_data_collection ? 1 : 0
  catalog_id = data.aws_caller_identity.this.id
  name       = replace("${var.name_prefix}-db", "-", "_")
}

resource "aws_glue_crawler" "this" {
  count         = var.enable_data_collection ? 1 : 0
  database_name = aws_glue_catalog_database.this[0].name
  name          = "${var.name_prefix}-crawler"
  role          = aws_iam_role.glue_crawler_role[0].arn

  s3_target {
    path = "s3://${aws_s3_bucket.dataLake.bucket}/tweets"
  }

  recrawl_policy {
    recrawl_behavior = "CRAWL_NEW_FOLDERS_ONLY"
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "LOG"
  }

}

resource "aws_iam_role" "glue_crawler_role" {
  count = var.enable_data_collection ? 1 : 0
  name  = "${var.name_prefix}-glue-crawler-role"

  assume_role_policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "glue.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "glue_crawler_s3" {
  count  = var.enable_data_collection ? 1 : 0
  name   = "s3"
  role   = aws_iam_role.glue_crawler_role[0].id
  policy = <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
         "s3:GetObject",
          "s3:PutObject"
      ],
      "Resource": [
        "${aws_s3_bucket.dataLake.arn}",
        "${aws_s3_bucket.dataLake.arn}/*"
      ]
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "glue_service_policy" {
  count      = var.enable_data_collection ? 1 : 0
  role       = aws_iam_role.glue_crawler_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}