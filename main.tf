data "aws_caller_identity" "this" {}
data "aws_region" "current" {}

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

  redshift_data_pipeline_input_s3 = var.enable_redshift ? "s3://${aws_s3_bucket.dataLake.bucket}/${local.players_total_tweets_mentions_table}/" : null

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
resource "aws_glue_catalog_database" "this" {
  catalog_id = data.aws_caller_identity.this.id
  name       = replace("${var.name_prefix}-db", "-", "_")
}

resource "aws_glue_crawler" "this" {
  count         = var.enable_glue_etl ? 1 : 0
  database_name = aws_glue_catalog_database.this.name
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
  count = var.enable_glue_etl ? 1 : 0
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
  count  = var.enable_glue_etl ? 1 : 0
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

resource "aws_iam_role_policy_attachment" "glue_crawler_service_policy" {
  count      = var.enable_glue_etl ? 1 : 0
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

resource "aws_iam_role" "emr_ec2_role" {
  count = var.enable_emr_cluster || var.enable_step_functions ? 1 : 0
  name  = "${var.name_prefix}-emr-ec2-role"

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
  name  = "${var.name_prefix}-emr-ec2-instance-profile"
  role  = aws_iam_role.emr_ec2_role[0].name
}

resource "aws_iam_role_policy_attachment" "emr_instance_profile_policy" {
  count      = var.enable_emr_cluster || var.enable_step_functions ? 1 : 0
  role       = aws_iam_role.emr_ec2_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonElasticMapReduceforEC2Role"
}

###### Step Functions ######
data "template_file" "hive_create_table" {
  count    = var.enable_step_functions ? 1 : 0
  template = file("${path.module}/04-hive-scripts/create-players-total-tweets-table.q")
  vars = {
    GLUE_DATABASE = aws_glue_catalog_database.this.name
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
    GLUE_DATABASE = aws_glue_catalog_database.this.name
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
        "DatabaseName": "${aws_glue_catalog_database.this.name}",
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

###### Redshift ######
resource "aws_redshift_cluster" "this" {
  count               = var.enable_redshift ? 1 : 0
  cluster_identifier  = "${var.name_prefix}-cluster"
  database_name       = "twitter"
  master_username     = var.redshift_username
  master_password     = var.redshift_password
  node_type           = "dc2.large"
  cluster_type        = "single-node"
  skip_final_snapshot = true
  iam_roles           = [aws_iam_role.redshift_s3_role[0].arn]
}

resource "aws_iam_role" "redshift_s3_role" {
  count = var.enable_redshift ? 1 : 0
  name  = "${var.name_prefix}-redshift-s3-role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "redshift.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy_attachment" "redshift_s3_policy" {
  count      = var.enable_redshift ? 1 : 0
  role       = aws_iam_role.redshift_s3_role[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_datapipeline_pipeline" "this" {
  count       = var.enable_redshift ? 1 : 0
  name        = "${var.name_prefix}-data-pipeline"
  description = "Data Pipeline to move data from S3 to Redshift"
}

resource "aws_datapipeline_pipeline_definition" "this" {
  count       = var.enable_redshift ? 1 : 0
  pipeline_id = aws_datapipeline_pipeline.this[0].id
  pipeline_object {
    id   = "Default"
    name = "Default"
    field {
      key          = "scheduleType"
      string_value = "ONDEMAND"
    }
    field {
      key          = "pipelineLogUri"
      string_value = "s3://${aws_s3_bucket.assets.bucket}/data-pipeline"
    }
    field {
      key          = "role"
      string_value = aws_iam_role.data_pipeline_role[0].name
    }
    field {
      key          = "resourceRole"
      string_value = aws_iam_instance_profile.data_pipeline_ec2_instance_profile[0].name
    }
    field {
      key          = "failureAndRerunMode"
      string_value = "CASCADE"
    }
  }
  pipeline_object {
    id   = "RedshiftCluster"
    name = "RedshiftCluster"
    field {
      key          = "type"
      string_value = "RedshiftDatabase"
    }
    field {
      key          = "username"
      string_value = "#{myRedshiftUsername}"
    }
    field {
      key          = "*password"
      string_value = "#{*myRedshiftPassword}"
    }
    field {
      key          = "databaseName"
      string_value = "#{myRedshiftJdbcConnectStr}"
    }
    field {
      key          = "connectionString"
      string_value = "#{myRedshiftJdbcConnectStr}"
    }
  }
  pipeline_object {
    id   = "Ec2Instance"
    name = "Ec2Instance"
    field {
      key          = "type"
      string_value = "Ec2Resource"
    }
    field {
      key          = "instanceType"
      string_value = "t1.micro"
    }
    field {
      key          = "terminateAfter"
      string_value = "1 Hour"
    }
    field {
      key          = "securityGroups"
      string_value = "#{myRedshiftSecurityGrps}"
    }
  }
  pipeline_object {
    id   = "DestRedshiftTable"
    name = "DestRedshiftTable"
    field {
      key          = "type"
      string_value = "RedshiftDataNode"
    }
    field {
      key          = "tableName"
      string_value = "#{myRedshiftTableName}"
    }
    field {
      key          = "createTableSql"
      string_value = "#{myRedshiftCreateTableSql}"
    }
    field {
      key       = "database"
      ref_value = "RedshiftCluster"
    }
  }
  pipeline_object {
    id   = "S3InputDataNode"
    name = "S3InputDataNode"
    field {
      key          = "type"
      string_value = "S3DataNode"
    }
    field {
      key          = "directoryPath"
      string_value = "#{myInputS3Loc}"
    }
  }
  pipeline_object {
    id   = "RedshiftLoadActivity"
    name = "RedshiftLoadActivity"
    field {
      key          = "type"
      string_value = "RedshiftCopyActivity"
    }
    field {
      key          = "insertMode"
      string_value = "#{myInsertMode}"
    }
    field {
      key       = "runsOn"
      ref_value = "Ec2Instance"
    }
    field {
      key       = "input"
      ref_value = "S3InputDataNode"
    }
    field {
      key       = "output"
      ref_value = "DestRedshiftTable"
    }
    field {
      key          = "commandOptions"
      string_value = "FORMAT AS JSON 'auto'"
    }
  }
  parameter_object {
    id = "*myRedshiftPassword"
    attribute {
      key          = "description"
      string_value = "Redshift password"
    }
    attribute {
      key          = "type"
      string_value = "String"
    }
  }
  parameter_object {
    id = "myRedshiftDbName"
    attribute {
      key          = "description"
      string_value = "Redshift database name"
    }
    attribute {
      key          = "type"
      string_value = "String"
    }
  }
  parameter_object {
    id = "myRedshiftSecurityGrps"
    attribute {
      key          = "description"
      string_value = "Redshift security group(s)"
    }
    attribute {
      key          = "type"
      string_value = "String"
    }
    attribute {
      key          = "isArray"
      string_value = "true"
    }
    attribute {
      key          = "helpText"
      string_value = "The names of one or more security groups that are assigned to the Redshift cluster."
    }
    attribute {
      key          = "watermark"
      string_value = "security group name"
    }
    attribute {
      key          = "default"
      string_value = "default"
    }
  }
  parameter_object {
    id = "myRedshiftUsername"
    attribute {
      key          = "description"
      string_value = "Redshift username"
    }
    attribute {
      key          = "type"
      string_value = "String"
    }
  }
  parameter_object {
    id = "myRedshiftCreateTableSql"
    attribute {
      key          = "description"
      string_value = "Create table SQL query"
    }
    attribute {
      key          = "type"
      string_value = "String"
    }
    attribute {
      key          = "optional"
      string_value = "true"
    }
    attribute {
      key          = "helpText"
      string_value = "The SQL statement to create the Redshift table if it does not already exist."
    }
    attribute {
      key          = "watermark"
      string_value = "CREATE TABLE IF NOT EXISTS #{tableName} (id varchar(255), name varchar(255), address varchar(255), primary key(id)) distkey(id) sortkey(id);"
    }
  }
  parameter_object {
    id = "myRedshiftTableName"
    attribute {
      key          = "description"
      string_value = "Redshift table name"
    }
    attribute {
      key          = "type"
      string_value = "String"
    }
  }
  parameter_object {
    id = "myInputS3Loc"
    attribute {
      key          = "description"
      string_value = "Input S3 folder"
    }
    attribute {
      key          = "type"
      string_value = "AWS::S3::ObjectKey"
    }
  }
  parameter_object {
    id = "myRedshiftJdbcConnectStr"
    attribute {
      key          = "description"
      string_value = "Redshift JDBC connection string"
    }
    attribute {
      key          = "type"
      string_value = "string"
    }
  }
  parameter_object {
    id = "myInsertMode"
    attribute {
      key          = "description"
      string_value = "Table insert mode"
    }
    attribute {
      key          = "type"
      string_value = "String"
    }
    attribute {
      key          = "default"
      string_value = "OVERWRITE_EXISTING"
    }
  }
  parameter_value {
    id           = "myRedshiftUsername"
    string_value = aws_redshift_cluster.this[0].master_username
  }
  parameter_value {
    id           = "myRedshiftCreateTableSql"
    string_value = "CREATE TABLE IF NOT EXISTS playerstotaltweets(year integer not null, month integer not null, day integer not null, player varchar(255) not null, total integer not null);"
  }
  parameter_value {
    id           = "myRedshiftDbName"
    string_value = aws_redshift_cluster.this[0].database_name
  }
  parameter_value {
    id           = "myRedshiftJdbcConnectStr"
    string_value = "jbdc:postgresql://${aws_redshift_cluster.this[0].endpoint}/${aws_redshift_cluster.this[0].database_name}?tcpKeepAlive=true"
  }
  parameter_value {
    id           = "*myRedshiftPassword"
    string_value = aws_redshift_cluster.this[0].master_password
  }
  parameter_value {
    id           = "myInsertMode"
    string_value = "TRUNCATE"
  }
  parameter_value {
    id           = "myRedshiftSecurityGrps"
    string_value = "default"
  }
  parameter_value {
    id           = "myRedshiftTableName"
    string_value = "playerstotaltweets"
  }
  parameter_value {
    id           = "myInputS3Loc"
    string_value = local.redshift_data_pipeline_input_s3
  }
}

resource "aws_iam_role" "data_pipeline_role" {
  count = var.enable_redshift ? 1 : 0
  name  = "${var.name_prefix}-data-pipeline-role"

  assume_role_policy = <<EOF
{
  "Version": "2008-10-17",
  "Statement": [
    {
      "Sid": "",
      "Effect": "Allow",
      "Principal": {
        "Service": "datapipeline.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF
}

resource "aws_iam_role_policy" "data_pipeline_policy" {
  count  = var.enable_redshift ? 1 : 0
  name   = "${var.name_prefix}-data-pipeline-policy"
  role   = aws_iam_role.data_pipeline_role[0].id
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Resource": "*",
        "Action": [
            "s3:*",
            "ec2:*",
            "iam:*"
        ]
    }]
}
EOF
}

resource "aws_iam_role" "data_pipeline_ec2_role" {
  count = var.enable_redshift ? 1 : 0
  name  = "${var.name_prefix}-datapipeline-ec2-role"

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

resource "aws_iam_instance_profile" "data_pipeline_ec2_instance_profile" {
  count = var.enable_redshift ? 1 : 0
  name  = "${var.name_prefix}-datapipeline-ec2-instance-profile"
  role  = aws_iam_role.data_pipeline_ec2_role[0].name
}

resource "aws_iam_role_policy" "data_pipeline_ec2_policy" {
  count  = var.enable_redshift ? 1 : 0
  name   = "${var.name_prefix}-data-pipeline-ec2-policy"
  role   = aws_iam_role.data_pipeline_ec2_role[0].id
  policy = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [{
        "Effect": "Allow",
        "Resource": "*",
        "Action": [
            "s3:*",
            "cloudwatch:*",
            "datapipeline:*",
            "ec2:*",
            "dynamodb:*",
            "elasticmapreduce:*",
            "rds:*",
            "redshift:*",
            "sdb:*",
            "sns:*",
            "sqs:*"
        ]
    }]
}
EOF
}

### Quicksight ###
resource "aws_quicksight_data_source" "redshift" {
  count          = var.enable_quicksight ? 1 : 0
  data_source_id = "${var.name_prefix}-redshift"
  name           = local.players_total_tweets_mentions_table
  type           = "REDSHIFT"
  aws_account_id = data.aws_caller_identity.this.id

  credentials {
    credential_pair {
      username = aws_redshift_cluster.this[0].master_username
      password = aws_redshift_cluster.this[0].master_password
    }
  }

  permission {
    actions = [
      "quicksight:UpdateDataSourcePermissions",
      "quicksight:DescribeDataSourcePermissions",
      "quicksight:PassDataSource",
      "quicksight:DescribeDataSource",
      "quicksight:DeleteDataSource",
      "quicksight:UpdateDataSource"
    ]
    principal = var.quicksight_user_arn
  }

  parameters {
    redshift {
      cluster_id = aws_redshift_cluster.this[0].id
      database   = aws_redshift_cluster.this[0].database_name
    }
  }

  ssl_properties {
    disable_ssl = false
  }

  lifecycle {
    precondition {
      condition     = var.enable_redshift
      error_message = "Redshift Component must be enabled."
    }
  }
}

### Kinesis Data Analytics ###
resource "aws_s3_object" "flink" {
  count  = var.enable_kinesis_data_analytics ? 1 : 0
  bucket = aws_s3_bucket.assets.bucket
  key    = "FlinkScripts/nba-tampering-flink-app.jar"
  source = "${path.module}/08-flink-java/nba-tampering-flink/target/nba-tampering-flink-1.0-SNAPSHOT.jar"
  etag = filemd5("${path.module}/08-flink-java/nba-tampering-flink/target/nba-tampering-flink-1.0-SNAPSHOT.jar")
}

resource "aws_kinesis_stream" "nba_tampering" {
  count            = var.enable_kinesis_data_analytics ? 1 : 0
  name             = "${var.name_prefix}-nba-tampering-source"
  shard_count      = 1
  retention_period = 48

  shard_level_metrics = [
    "IncomingBytes",
    "OutgoingBytes",
  ]

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

resource "aws_kinesis_stream" "nba_tampering_output" {
  count            = var.enable_kinesis_data_analytics ? 1 : 0
  name             = "${var.name_prefix}-nba-tampering-output"
  shard_count      = 1
  retention_period = 48

  shard_level_metrics = [
    "IncomingBytes",
    "OutgoingBytes",
  ]

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

resource "aws_sns_topic" "nba_tampering" {
  count = var.enable_kinesis_data_analytics ? 1 : 0
  name  = "${var.name_prefix}-nba-tampering-notification"
}

resource "aws_sns_topic_subscription" "nba_tampering" {
  count     = var.enable_kinesis_data_analytics ? 1 : 0
  topic_arn = aws_sns_topic.nba_tampering[0].arn
  protocol  = "email"
  endpoint  = var.my_email
}

module "lambda_nba_tampering" {
  count                                   = var.enable_kinesis_data_analytics ? 1 : 0
  source                                  = "terraform-aws-modules/lambda/aws"
  function_name                           = "${var.name_prefix}-nba-tampering-notify"
  description                             = "Lambda to notify nba tampering"
  handler                                 = "index.lambda_handler"
  runtime                                 = "python3.8"
  docker_image                            = "public.ecr.aws/j9c7g0r1/lambda_python:latest"
  source_path                             = "${path.module}/06-notify-nba-tampering-lambda"
  recreate_missing_package                = true
  ignore_source_code_hash                 = true
  build_in_docker                         = true
  docker_pip_cache                        = true
  memory_size                             = 512
  timeout                                 = 900
  cloudwatch_logs_retention_in_days       = 5
  create_current_version_allowed_triggers = false
  environment_variables = {
    TOPIC_ARN = aws_sns_topic.nba_tampering[0].arn
  }
  event_source_mapping = {
    kinesis = {
      event_source_arn                   = aws_kinesis_stream.nba_tampering_output[0].arn
      starting_position                  = "LATEST"
      maximum_batching_window_in_seconds = 5
      batch_size                         = 100
    }
  }
  allowed_triggers = {
    kinesis = {
      principal  = "kinesis.amazonaws.com"
      source_arn = aws_kinesis_stream.nba_tampering_output[0].arn
    }
  }
  attach_policy_json = true
  policy_json        = <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Effect": "Allow",
            "Action": [
                "sns:*"
            ],
            "Resource": ["*"]
        }
    ]
}
EOF
  attach_policies    = true
  number_of_policies = 1
  policies = [
    "arn:aws:iam::aws:policy/service-role/AWSLambdaKinesisExecutionRole",
  ]
}

resource "aws_kinesisanalyticsv2_application" "this" {
  count                  = var.enable_kinesis_data_analytics ? 1 : 0
  name                   = "${var.name_prefix}-analytics"
  runtime_environment    = "FLINK-1_13"
  service_execution_role = aws_iam_role.analytics[0].arn
  start_application      = true

  application_configuration {
    application_code_configuration {
      code_content {
        s3_content_location {
          bucket_arn = aws_s3_bucket.assets.arn
          file_key   = aws_s3_object.flink[0].key
        }
      }

      code_content_type = "ZIPFILE"
    }

    environment_properties {
      property_group {
        property_group_id = "ControlConsumerConfig"

        property_map = {
          "input.stream.name"    = aws_kinesis_stream.tampering_control[0].name
          "flink.stream.initpos" = "LATEST"
          "aws.region"           = data.aws_region.current.name
        }
      }

      property_group {
        property_group_id = "TweetsConsumerConfig"

        property_map = {
          "input.stream.name"    = aws_kinesis_stream.nba_tampering[0].name
          "flink.stream.initpos" = "LATEST"
          "aws.region"           = data.aws_region.current.name
        }
      }

      property_group {
        property_group_id = "ProducerConfig"

        property_map = {
          "output.stream.name" = aws_kinesis_stream.nba_tampering_output[0].name
          "aws.region"         = data.aws_region.current.name
        }
      }

      property_group {
        property_group_id = "ApplicationConfig"

        property_map = {
          "window.seconds" = "30"
        }
      }
    }

    flink_application_configuration {
      checkpoint_configuration {
        configuration_type = "DEFAULT"
      }

      monitoring_configuration {
        configuration_type = "CUSTOM"
        log_level          = "DEBUG"
        metrics_level      = "TASK"
      }

      parallelism_configuration {
        auto_scaling_enabled = true
        configuration_type   = "CUSTOM"
        parallelism          = 1
        parallelism_per_kpu  = 1
      }
    }
  }

  cloudwatch_logging_options {
    log_stream_arn = aws_cloudwatch_log_stream.analytics[0].arn
  }
}

resource "aws_iam_role" "analytics" {
  count = var.enable_kinesis_data_analytics ? 1 : 0
  name  = "${var.name_prefix}-analytics-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Sid    = ""
        Principal = {
          Service = "kinesisanalytics.amazonaws.com"
        }
      },
    ]
  })
  inline_policy {
    name = "policy"
    policy = jsonencode({
      Version = "2012-10-17"
      Statement = [
        {
          Action   = "cloudwatch:*",
          Effect   = "Allow"
          Resource = "*"
        },
        {
          Action   = "logs:*",
          Effect   = "Allow"
          Resource = "*"
        },
        {
          Action   = "s3:*",
          Effect   = "Allow"
          Resource = "*"
        },
        {
          Action   = "kinesis:*",
          Effect   = "Allow"
          Resource = "*"
        },
        {
          Action   = "dynamodb:*",
          Effect   = "Allow"
          Resource = "*"
        }
      ]
    })
  }
}

resource "aws_cloudwatch_log_group" "analytics" {
  count = var.enable_kinesis_data_analytics ? 1 : 0
  name  = "${var.name_prefix}-analytics-log"
}

resource "aws_cloudwatch_log_stream" "analytics" {
  count          = var.enable_kinesis_data_analytics ? 1 : 0
  name           = "${var.name_prefix}-log-stream"
  log_group_name = aws_cloudwatch_log_group.analytics[0].name
}

resource "aws_dynamodb_table" "tampering_control" {
  count            = var.enable_kinesis_data_analytics ? 1 : 0
  name             = "${var.name_prefix}-tampering-control"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "team"

  attribute {
    name = "team"
    type = "S"
  }

}

resource "aws_kinesis_stream" "tampering_control" {
  count            = var.enable_kinesis_data_analytics ? 1 : 0
  name             = "${var.name_prefix}-dynamodb-tampering-control"
  shard_count      = 1
  retention_period = 48

  shard_level_metrics = [
    "IncomingBytes",
    "OutgoingBytes",
  ]

  stream_mode_details {
    stream_mode = "PROVISIONED"
  }
}

resource "aws_dynamodb_kinesis_streaming_destination" "this" {
  stream_arn = aws_kinesis_stream.tampering_control[0].arn
  table_name = aws_dynamodb_table.tampering_control[0].name
}

resource "aws_dynamodb_table" "players" {
  count        = var.enable_kinesis_data_analytics ? 1 : 0
  name         = "${var.name_prefix}-players"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "account"

  attribute {
    name = "account"
    type = "S"
  }

  attribute {
    name = "name"
    type = "S"
  }

  global_secondary_index {
    name            = "PlayerNameIndex"
    hash_key        = "name"
    projection_type = "ALL"
  }
}

resource "aws_dynamodb_table_item" "doncic" {
  count      = var.enable_kinesis_data_analytics ? 1 : 0
  table_name = aws_dynamodb_table.players[0].name
  hash_key   = aws_dynamodb_table.players[0].hash_key

  item = <<ITEM
{
  "account": {"S": "luka7doncic"},
  "name": {"S": "Luka Doncic"},
  "team": {"S": "Dallas"}
}
ITEM
}

resource "aws_dynamodb_table_item" "davis" {
  count      = var.enable_kinesis_data_analytics ? 1 : 0
  table_name = aws_dynamodb_table.players[0].name
  hash_key   = aws_dynamodb_table.players[0].hash_key

  item = <<ITEM
{
  "account": {"S": "AntDavis23"},
  "name": {"S": "Anthony Davis"},
  "team": {"S": "LA Lakers"}
}
ITEM
}

resource "aws_dynamodb_table_item" "james" {
  count      = var.enable_kinesis_data_analytics ? 1 : 0
  table_name = aws_dynamodb_table.players[0].name
  hash_key   = aws_dynamodb_table.players[0].hash_key

  item = <<ITEM
{
  "account": {"S": "KingJames"},
  "name": {"S": "Lebron James"},
  "team": {"S": "LA Lakers"}
}
ITEM
}

resource "aws_dynamodb_table_item" "durant" {
  count      = var.enable_kinesis_data_analytics ? 1 : 0
  table_name = aws_dynamodb_table.players[0].name
  hash_key   = aws_dynamodb_table.players[0].hash_key

  item = <<ITEM
{
  "account": {"S": "KDTrey5"},
  "name": {"S": "Kevin Durant"},
  "team": {"S": "BK Nets"}
}
ITEM
}

resource "aws_dynamodb_table_item" "irving" {
  count      = var.enable_kinesis_data_analytics ? 1 : 0
  table_name = aws_dynamodb_table.players[0].name
  hash_key   = aws_dynamodb_table.players[0].hash_key

  item = <<ITEM
{
  "account": {"S": "KyrieIrving"},
  "name": {"S": "Kyrie Irving"},
  "team": {"S": "BK Nets"}
}
ITEM
}

resource "aws_dynamodb_table_item" "curry" {
  count      = var.enable_kinesis_data_analytics ? 1 : 0
  table_name = aws_dynamodb_table.players[0].name
  hash_key   = aws_dynamodb_table.players[0].hash_key

  item = <<ITEM
{
  "account": {"S": "StephenCurry30"},
  "name": {"S": "Stephen Curry"},
  "team": {"S": "GS Warriors"}
}
ITEM
}