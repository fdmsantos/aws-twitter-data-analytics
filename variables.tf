variable "name_prefix" {
  type    = string
  default = "twitter-nba"
}

variable "s3_force_destroy" {
  type    = bool
  default = false
}

variable "enable_data_collection" {
  type        = bool
  default     = true
  description = "Set it to false to disable process related with data collection (Kinesis Firehose)"
}

variable "enable_data_catalog" {
  type        = bool
  default     = true
  description = "Set it to false to disable process related with data catalog (Glue Catalog & Glue Crawler)"
}

variable "enable_etl" {
  type        = bool
  default     = true
  description = "Set it to false to disable process related with etl (Glue Job)"
}