output "data_collection_stream_name" {
  value = aws_kinesis_firehose_delivery_stream.this.name
}

output "glue_tweet_crawler" {
  value = aws_glue_crawler.this.name
}

output "glue_drop_duplicates_job" {
  value = aws_glue_job.drop_duplicates.name
}