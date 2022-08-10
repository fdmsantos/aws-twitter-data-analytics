output "data_collection_stream_name" {
  value = var.enable_data_collection ? aws_kinesis_firehose_delivery_stream.this[0].name : null
}

output "glue_tweet_crawler" {
  value = var.enable_data_catalog ? aws_glue_crawler.this[0].name : null
}

output "glue_drop_duplicates_job" {
  value = var.enable_glue_etl ? aws_glue_job.drop_duplicates[0].name : null
}

output "glue_workflow" {
  value = var.enable_glue_etl ? aws_glue_workflow.this[0].name : null
}

output "emr_public_dns" {
  value = var.enable_emr_cluster ? aws_emr_cluster.this[0].master_public_dns : null
}

output "state_machine_arn" {
  value = var.enable_step_functions ? aws_sfn_state_machine.this[0].arn : null
}