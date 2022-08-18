output "s3_datalake_bucket" {
  value = aws_s3_bucket.dataLake.bucket
}

### FIREHOSE ###
output "data_collection_stream_name" {
  value = var.enable_data_collection ? aws_kinesis_firehose_delivery_stream.this[0].name : null
}

### GLUE ###
output "glue_database" {
  value = aws_glue_catalog_database.this.name
}

output "glue_tweet_crawler" {
  value = var.enable_glue_etl ? aws_glue_crawler.this[0].name : null
}

output "glue_drop_duplicates_job" {
  value = var.enable_glue_etl ? aws_glue_job.drop_duplicates[0].name : null
}

output "glue_workflow" {
  value = var.enable_glue_etl ? aws_glue_workflow.this[0].name : null
}

### EMR ###
output "emr_public_dns" {
  value = var.enable_emr_cluster ? aws_emr_cluster.this[0].master_public_dns : null
}

### STEP FUNCTIONS ###
output "state_machine_arn" {
  value = var.enable_step_functions ? aws_sfn_state_machine.this[0].arn : null
}

### REDSHIFT ###
output "redshift_iam_role_arn" {
  value = var.enable_redshift ? aws_iam_role.redshift_s3_role[0].arn : null
}

output "redshift_pipeline_id" {
  value = var.enable_redshift ? aws_datapipeline_pipeline.this[0].id : null
}

output "redshift_pipeline_input_s3" {
  value = local.redshift_data_pipeline_input_s3
}

output "redshift_s3_role_arn" {
  value = var.enable_redshift ? aws_iam_role.redshift_s3_role[0].arn : null
}

### Kinesis Data Analytics ###
output "kinesis_data_stream_source" {
  value = var.enable_kinesis_data_analytics ? aws_kinesis_stream.nba_tampering[0].name : null
}

output "kinesis_data_stream_output" {
  value = var.enable_kinesis_data_analytics ? aws_kinesis_stream.nba_tampering_output[0].name : null
}