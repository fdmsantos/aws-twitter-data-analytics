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
  key     = "GlueJobs/DropDuplicates/drop_duplicates.py"
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
    "--job-bookmark-option"   = var.glue_jobs_bookmark
    "--class"                 = "GlueApp"
    "--job-language"          = "python"
    "--TempDir"               = "s3://${aws_s3_bucket.assets.bucket}/GlueJobs/DropDuplicates/temporary"
    "--spark-event-logs-path" = "s3://${aws_s3_bucket.assets.bucket}/GlueJobs/DropDuplicates/sparkHistoryLogs"
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
  count      = var.enable_data_catalog ? 1 : 0
  catalog_id = data.aws_caller_identity.this.id
  name       = replace("${var.name_prefix}-db", "-", "_")
}

resource "aws_glue_crawler" "this" {
  count         = var.enable_data_catalog ? 1 : 0
  database_name = aws_glue_catalog_database.this[0].name
  name          = "${var.name_prefix}-crawler"
  role          = aws_iam_role.glue_crawler_role[0].arn

  s3_target {
    path = "s3://${aws_s3_bucket.dataLake.bucket}/tweets"
  }

  recrawl_policy {
    recrawl_behavior = var.glue_crawl_recrawl_behavior
  }

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "LOG"
  }

}

resource "aws_iam_role" "glue_crawler_role" {
  count = var.enable_data_catalog ? 1 : 0
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
  count  = var.enable_data_catalog ? 1 : 0
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
  count      = var.enable_data_catalog ? 1 : 0
  role       = aws_iam_role.glue_crawler_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

###### Glue Workflow ######
resource "aws_glue_workflow" "this" {
  count       = var.enable_etl ? 1 : 0
  name        = "${var.name_prefix}-glue-workflow"
  description = "Glue Workflow for nba twitter"
}

resource "aws_glue_trigger" "trigger_workflow" {
  count         = var.enable_etl ? 1 : 0
  name          = "trigger-start"
  type          = "ON_DEMAND"
  workflow_name = aws_glue_workflow.this[0].name
  actions {
    job_name = aws_glue_job.drop_duplicates[0].name
  }
}

resource "aws_glue_trigger" "trigger-crawler" {
  count         = var.enable_etl && var.enable_data_catalog ? 1 : 0
  name          = "trigger-crawler"
  type          = "CONDITIONAL"
  workflow_name = aws_glue_workflow.this[0].name

  predicate {
    conditions {
      job_name = aws_glue_job.drop_duplicates[0].name
      state    = "SUCCEEDED"
    }
  }

  actions {
    crawler_name = aws_glue_crawler.this[0].name
  }
}

###### EMR Cluster ######
resource "aws_emr_cluster" "this" {
  count                             = var.enable_emr ? 1 : 0
  name                              = "${var.name_prefix}-emr"
  release_label                     = "emr-6.7.0"
  applications                      = ["Hive"]
  termination_protection            = false
  service_role                      = aws_iam_role.emr_service_role[0].arn
  keep_job_flow_alive_when_no_steps = true
  log_uri                           = "s3://${aws_s3_bucket.assets.bucket}/emr/logs"
  ec2_attributes {
    key_name                          = var.key_pair_name
    subnet_id                         = var.emr_subnet_id
    emr_managed_master_security_group = aws_security_group.emr_allow_my_access[0].id
    emr_managed_slave_security_group  = aws_security_group.emr_allow_my_access[0].id
    instance_profile                  = aws_iam_instance_profile.emr_instance_profile[0].arn
  }

  master_instance_group {
    instance_type  = "m3.xlarge"
    instance_count = 1
  }

  core_instance_group {
    instance_type  = "m3.xlarge"
    instance_count = 2
  }

  configurations_json = <<EOF
[
  {
    "Classification": "hive-site",
    "Properties": {
      "hive.metastore.client.factory.class": "com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory"
    }
  }
]
EOF

  step {
    action_on_failure = "TERMINATE_CLUSTER"
    name              = "Setup Hadoop Debugging"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["state-pusher-script"]
    }
  }


  #  step {
  #    action_on_failure = "CONTINUE"
  #    name              = "Python Spark App"
  #    hadoop_jar_step {
  #      jar  = "command-runner.jar"
  #      args = ["spark-submit", "s3://${aws_s3_bucket.this.bucket}/health_violations.py", "--data_source", "s3://${aws_s3_bucket.this.bucket}/food_establishment_data.csv", "--output_uri", "s3://${aws_s3_bucket.this.bucket}/MyOutputFolder"]
  #    }
  #  }

  lifecycle {
    ignore_changes = [log_uri]
  }

}

data "http" "my_public_ip" {
  count = var.enable_emr ? 1 : 0
  url   = "http://ipv4.icanhazip.com"
}


resource "aws_security_group" "emr_allow_my_access" {
  count                  = var.enable_emr ? 1 : 0
  name                   = "emr-allow-my-ssh"
  description            = "Allow My Access"
  vpc_id                 = var.emr_vpc_id
  revoke_rules_on_delete = true

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.my_public_ip[0].body)}/32"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    ignore_changes = [
      ingress,
      egress,
    ]
  }

}

resource "aws_iam_role" "emr_service_role" {
  count = var.enable_emr ? 1 : 0
  name  = "${var.name_prefix}-emr-servicerole"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "elasticmapreduce.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "emr_service_policy" {
  count = var.enable_emr ? 1 : 0
  name  = "${var.name_prefix}-servicerole-policy"
  role  = aws_iam_role.emr_service_role[0].id

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Resource": "*",
        "Action": [
            "ec2:AuthorizeSecurityGroupEgress",
            "ec2:AuthorizeSecurityGroupIngress",
            "ec2:CancelSpotInstanceRequests",
            "ec2:CreateNetworkInterface",
            "ec2:CreateSecurityGroup",
            "ec2:CreateTags",
            "ec2:DeleteNetworkInterface",
            "ec2:DeleteSecurityGroup",
            "ec2:DeleteTags",
            "ec2:DescribeAvailabilityZones",
            "ec2:DescribeAccountAttributes",
            "ec2:DescribeDhcpOptions",
            "ec2:DescribeInstanceStatus",
            "ec2:DescribeInstances",
            "ec2:DescribeKeyPairs",
            "ec2:DescribeNetworkAcls",
            "ec2:DescribeNetworkInterfaces",
            "ec2:DescribePrefixLists",
            "ec2:DescribeRouteTables",
            "ec2:DescribeSecurityGroups",
            "ec2:DescribeSpotInstanceRequests",
            "ec2:DescribeSpotPriceHistory",
            "ec2:DescribeSubnets",
            "ec2:DescribeVpcAttribute",
            "ec2:DescribeVpcEndpoints",
            "ec2:DescribeVpcEndpointServices",
            "ec2:DescribeVpcs",
            "ec2:DetachNetworkInterface",
            "ec2:ModifyImageAttribute",
            "ec2:ModifyInstanceAttribute",
            "ec2:RequestSpotInstances",
            "ec2:RevokeSecurityGroupEgress",
            "ec2:RunInstances",
            "ec2:TerminateInstances",
            "ec2:DeleteVolume",
            "ec2:DescribeVolumeStatus",
            "ec2:DescribeVolumes",
            "ec2:DetachVolume",
            "iam:GetRole",
            "iam:GetRolePolicy",
            "iam:ListInstanceProfiles",
            "iam:ListRolePolicies",
            "iam:PassRole",
            "s3:CreateBucket",
            "s3:Get*",
            "s3:List*",
            "sdb:BatchPutAttributes",
            "sdb:Select",
            "sqs:CreateQueue",
            "sqs:Delete*",
            "sqs:GetQueue*",
            "sqs:PurgeQueue",
            "sqs:ReceiveMessage"
        ]
    }]
}
EOF
}

resource "aws_iam_role" "emr_instance_profile_role" {
  count = var.enable_emr ? 1 : 0
  name  = "iam_emr_profile_role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_instance_profile" "emr_instance_profile" {
  count = var.enable_emr ? 1 : 0
  name  = "emr_profile"
  role  = aws_iam_role.emr_instance_profile_role[0].name
}

resource "aws_iam_role_policy_attachment" "emr_instance_profile_policy" {
  count      = var.enable_emr ? 1 : 0
  role       = aws_iam_role.emr_instance_profile_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
}