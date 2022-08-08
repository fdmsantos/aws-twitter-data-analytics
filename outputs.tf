output "data-collection-stream-name" {
  value = aws_kinesis_firehose_delivery_stream.this.name
}

#output "glue-tweet-crawler" {
#  value = aws_glue_crawler.this.name
#}