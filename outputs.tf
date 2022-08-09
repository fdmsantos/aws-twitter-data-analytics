output "data_collection_stream_name" {
  value = var.enable_data_collection ? aws_kinesis_firehose_delivery_stream.this[0].name : null
}

output "glue_tweet_crawler" {
  value = var.enable_data_catalog ? aws_glue_crawler.this[0].name : null
}

output "glue_drop_duplicates_job" {
  value = var.enable_etl ? aws_glue_job.drop_duplicates[0].name : null
}