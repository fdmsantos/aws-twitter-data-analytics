data "aws_caller_identity" "this" {}

locals {
  raw_data_location_prefix            = "raw"
  tweets_data_location_prefix         = "tweets"
  players_total_tweets_mentions_table = "PlayersTotalTweets"
  states_emr_applications             = jsonencode([for application in var.emr_applications : { Name : application }])
  emr_s3_logs_uri                     = "s3://${aws_s3_bucket.assets.bucket}/emr/logs"
  emr_configurations                  = <<EOF
[
  {
    "Classification": "hive-site",
    "Properties": {
      "hive.metastore.client.factory.class": "com.amazonaws.glue.catalog.metastore.AWSGlueDataCatalogHiveClientFactory"
    }
  }
]
EOF
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
  source_path                       = "${path.module}/02-data-transformation-lambda"
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
  count    = var.enable_glue_etl || var.enable_step_functions ? 1 : 0
  template = file("${path.module}/03-drop-duplicates-script/drop-duplicates.py")
  vars = {
    S3_INPUT_BUCKET_URI  = "s3://${aws_s3_bucket.dataLake.bucket}/${local.raw_data_location_prefix}"
    S3_OUTPUT_BUCKET_URI = "s3://${aws_s3_bucket.dataLake.bucket}/${local.tweets_data_location_prefix}"
  }
}

resource "aws_s3_object" "drop_duplicates" {
  count   = var.enable_glue_etl || var.enable_step_functions ? 1 : 0
  bucket  = aws_s3_bucket.assets.bucket
  key     = "GlueJobs/DropDuplicates/drop_duplicates.py"
  content = data.template_file.drop_duplicates[0].rendered
}

resource "aws_glue_job" "drop_duplicates" {
  count             = var.enable_glue_etl || var.enable_step_functions ? 1 : 0
  name              = "${var.name_prefix}-drop-duplicates"
  role_arn          = aws_iam_role.glue_job_drop_duplicates_role[0].arn
  description       = "Glue Job to drop duplicated tweets"
  glue_version      = "3.0"
  worker_type       = "G.1X"
  number_of_workers = 10

  command {
    script_location = "s3://${aws_s3_object.drop_duplicates[0].bucket}/${aws_s3_object.drop_duplicates[0].key}"
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
  count = var.enable_glue_etl || var.enable_step_functions ? 1 : 0
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
  count  = var.enable_glue_etl || var.enable_step_functions ? 1 : 0
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
resource "aws_glue_catalog_database" "this" { # TODO Should be always created. Remove enable_data_catalog variable
  count      = var.enable_data_catalog || var.enable_glue_etl || var.enable_step_functions ? 1 : 0
  catalog_id = data.aws_caller_identity.this.id
  name       = replace("${var.name_prefix}-db", "-", "_")
}

resource "aws_glue_crawler" "this" {
  count         = var.enable_data_catalog || var.enable_glue_etl ? 1 : 0
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
  count = var.enable_data_catalog || var.enable_glue_etl ? 1 : 0
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
  count  = var.enable_data_catalog || var.enable_glue_etl ? 1 : 0
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
  count      = var.enable_data_catalog || var.enable_glue_etl ? 1 : 0
  role       = aws_iam_role.glue_crawler_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

###### Glue Workflow ######
resource "aws_glue_workflow" "this" {
  count       = var.enable_glue_etl ? 1 : 0
  name        = "${var.name_prefix}-glue-workflow"
  description = "Glue Workflow for nba twitter"
}

resource "aws_glue_trigger" "trigger_workflow" {
  count         = var.enable_glue_etl ? 1 : 0
  name          = "trigger-start"
  type          = "ON_DEMAND"
  workflow_name = aws_glue_workflow.this[0].name
  actions {
    job_name = aws_glue_job.drop_duplicates[0].name
  }
}

resource "aws_glue_trigger" "trigger-crawler" {
  count         = var.enable_glue_etl ? 1 : 0
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
  count                             = var.enable_emr_cluster ? 1 : 0
  name                              = "${var.name_prefix}-emr-cluster"
  release_label                     = var.emr_release_version
  applications                      = var.emr_applications
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

  configurations_json = local.emr_configurations

  step {
    action_on_failure = "TERMINATE_CLUSTER"
    name              = "Setup Hadoop Debugging"

    hadoop_jar_step {
      jar  = "command-runner.jar"
      args = ["state-pusher-script"]
    }
  }

  lifecycle {
    ignore_changes = [log_uri]
  }

}

data "http" "my_public_ip" {
  count = var.enable_emr_cluster ? 1 : 0
  url   = "http://ipv4.icanhazip.com"
}

resource "aws_security_group" "emr_allow_my_access" {
  count                  = var.enable_emr_cluster ? 1 : 0
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
  count = var.enable_emr_cluster || var.enable_step_functions ? 1 : 0
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
  count = var.enable_emr_cluster || var.enable_step_functions ? 1 : 0
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
  count = var.enable_emr_cluster || var.enable_step_functions ? 1 : 0
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
  count = var.enable_emr_cluster || var.enable_step_functions ? 1 : 0
  name  = "emr_profile"
  role  = aws_iam_role.emr_instance_profile_role[0].name
}

resource "aws_iam_role_policy_attachment" "emr_instance_profile_policy" {
  count      = var.enable_emr_cluster || var.enable_step_functions ? 1 : 0
  role       = aws_iam_role.emr_instance_profile_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
}

###### Step Functions ######
data "template_file" "hive_create_table" {
  count    = var.enable_step_functions ? 1 : 0
  template = file("${path.module}/04-hive-scripts/create-players-total-tweets-table.q")
  vars = {
    GLUE_DATABASE = aws_glue_catalog_database.this[0].name
    GLUE_TABLE    = local.players_total_tweets_mentions_table
  }
}

resource "aws_s3_object" "hive_create_table_script" {
  count   = var.enable_step_functions ? 1 : 0
  bucket  = aws_s3_bucket.assets.bucket
  key     = "HiveScripts/create-players-total-tweets-table.q"
  content = data.template_file.hive_create_table[0].rendered
}

data "template_file" "hive_query" {
  count    = var.enable_step_functions ? 1 : 0
  template = file("${path.module}/04-hive-scripts/players-total-tweets-query.q")
  vars = {
    GLUE_DATABASE = aws_glue_catalog_database.this[0].name
    GLUE_TABLE    = local.players_total_tweets_mentions_table
  }
}

resource "aws_s3_object" "hive_query" {
  count   = var.enable_step_functions ? 1 : 0
  bucket  = aws_s3_bucket.assets.bucket
  key     = "HiveScripts/players-total-tweets-query.q"
  content = data.template_file.hive_query[0].rendered
}

resource "aws_sfn_state_machine" "this" {
  count    = var.enable_step_functions ? 1 : 0
  name     = "${var.name_prefix}-etl"
  role_arn = aws_iam_role.step_functions_role[0].arn

  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.sfn[0].arn}:*"
    include_execution_data = true
    level                  = "ERROR"
  }

  definition = <<EOF
{
  "Comment": "State Machine to calculate the Total Twitters By Athlete",
  "StartAt": "EMR CreateCluster",
  "States": {

    "EMR CreateCluster": {
    "Type": "Task",
    "Resource": "arn:aws:states:::elasticmapreduce:createCluster.sync",
    "Parameters": {
      "Name": "${var.name_prefix}-emr-cluster",
      "ServiceRole": "${aws_iam_role.emr_service_role[0].arn}",
      "JobFlowRole": "${aws_iam_instance_profile.emr_instance_profile[0].arn}",
      "ReleaseLabel": "${var.emr_release_version}",
      "Applications": ${local.states_emr_applications},
      "LogUri": "${local.emr_s3_logs_uri}",
      "VisibleToAllUsers": true,
      "Configurations": ${local.emr_configurations},
      "Instances": {
        "KeepJobFlowAliveWhenNoSteps": true,
        "InstanceFleets": [
          {
            "InstanceFleetType": "MASTER",
            "Name": "Master",
            "TargetOnDemandCapacity": 1,
            "InstanceTypeConfigs": [
              {
                "InstanceType": "m3.xlarge"
              }
            ]
          }
        ]
      }
    },
    "ResultPath": "$.CreateClusterResult",
    "Next": "GetTable",
    "Catch": [
      {
        "ErrorEquals": [
          "States.ALL"
        ],
        "Comment": "All",
        "Next": "Fail"
      }
    ]
  },

    "Fail": {
      "Type": "Fail"
    },

    "GetTable": {
      "Type": "Task",
      "Next": "EMR Run Query",
      "Parameters": {
        "DatabaseName": "${aws_glue_catalog_database.this[0].name}",
        "Name": "${local.players_total_tweets_mentions_table}"
       },
      "Resource": "arn:aws:states:::aws-sdk:glue:getTable",
      "ResultPath": null,
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "Comment": "All Errors",
          "ResultPath": null,
          "Next": "EMR Create Table"
        }
      ]
    },

    "EMR Create Table": {
      "Type": "Task",
      "Resource": "arn:aws:states:::elasticmapreduce:addStep.sync",
      "Parameters": {
        "ClusterId.$": "$.CreateClusterResult.Cluster.Id",
        "Step": {
          "Name": "HiveCreateTable",
          "ActionOnFailure": "TERMINATE_CLUSTER",
          "HadoopJarStep": {
            "Jar": "command-runner.jar",
            "Args": [
                "hive-script",
                "--run-hive-script",
                "--args",
                "-f",
                "s3://${aws_s3_object.hive_create_table_script[0].bucket}/${aws_s3_object.hive_create_table_script[0].key}",
                "-d",
                "INPUT=s3://${aws_s3_bucket.dataLake.bucket}/${local.players_total_tweets_mentions_table}"
              ]
          }
        }
      },
      "Next": "EMR Run Query",
      "ResultPath": null,
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "Next": "EMR TerminateCluster",
          "ResultPath": "$.Error"
        }
      ]
    },

  "EMR Run Query": {
    "Type": "Task",
    "Resource": "arn:aws:states:::elasticmapreduce:addStep.sync",
    "Parameters": {
      "ClusterId.$": "$.CreateClusterResult.Cluster.Id",
      "Step": {
        "Name": "HiveRunQuery",
        "ActionOnFailure": "TERMINATE_CLUSTER",
        "HadoopJarStep": {
          "Jar": "command-runner.jar",
          "Args.$": "States.Array('hive-script', '--run-hive-script', '--args', '-f', 's3://${aws_s3_object.hive_query[0].bucket}/${aws_s3_object.hive_query[0].key}', '-d', States.Format('YEAR={}', $.Year), '-d', States.Format('MONTH={}', $.Month), '-d', States.Format('DAY={}', $.Day))"
          }
        }
       },
      "Next": "EMR TerminateCluster",
      "ResultPath": null,
      "Catch": [
        {
          "ErrorEquals": [
            "States.ALL"
          ],
          "Next": "EMR TerminateCluster",
          "ResultPath": "$.Error"
        }
      ]
    },

    "EMR TerminateCluster": {
      "Type": "Task",
      "Resource": "arn:aws:states:::elasticmapreduce:terminateCluster.sync",
      "Parameters": {
        "ClusterId.$": "$.CreateClusterResult.Cluster.Id"
      },
      "Next": "Success"
    },

   "Success": {
      "Type": "Succeed"
    }
  }
}
EOF
}

resource "aws_iam_role" "step_functions_role" {
  count = var.enable_step_functions ? 1 : 0
  name  = "${var.name_prefix}-step-functions-role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "states.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "step_functions_policy" {
  count = var.enable_step_functions ? 1 : 0
  name  = "${var.name_prefix}-stepfunctions-policy"
  role  = aws_iam_role.step_functions_role[0].id

  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Resource": "*",
        "Action": [
            "glue:*",
            "logs:*",
            "elasticmapreduce:*",
            "iam:PassRole"
        ]
    }]
}
EOF
}

resource "aws_cloudwatch_log_group" "sfn" {
  count = var.enable_step_functions ? 1 : 0
  name  = "${var.name_prefix}-state-machine-log"
}