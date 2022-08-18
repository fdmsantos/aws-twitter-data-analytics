variable "name_prefix" {
  type    = string
  default = "twitter-nba"
}

variable "s3_force_destroy" {
  type    = bool
  default = false
}

### Flags ###
variable "enable_data_collection" {
  type        = bool
  default     = true
  description = "Set it to false to disable process related with data collection (Kinesis Firehose)"
}

variable "enable_glue_etl" {
  type        = bool
  default     = true
  description = "Set it to false to disable process related with etl (Glue Job)"
}

variable "enable_emr_cluster" {
  type        = bool
  default     = true
  description = "Set it to false to disable emr cluster"
}

variable "enable_step_functions" {
  type        = bool
  default     = true
  description = "Set it to false to disable step functions creation"
}

variable "enable_redshift" {
  type        = bool
  default     = true
  description = "Set it to false to disable redshift"
}

variable "enable_quicksight" {
  type        = string
  default     = true
  description = "Set it to false to disable quicksight"
}

variable "enable_kinesis_data_analytics" {
  type        = string
  default     = true
  description = "Set it to false to disable Kinesis Data Analytics"
}
### EMR ###
variable "emr_vpc_id" {
  type    = string
  default = null
}

variable "emr_subnet_id" {
  type    = string
  default = null
}

variable "key_pair_name" {
  type    = string
  default = null
}

variable "emr_applications" {
  type        = list(string)
  default     = ["Hive", "Flink"]
  description = "Applications to be installed on EMR cluster"
}

variable "emr_release_version" {
  type        = string
  default     = "emr-6.7.0"
  description = "EMR Cluster Version"
}

### Glue ###
variable "glue_jobs_bookmark" {
  type    = string
  default = "job-bookmark-disable"
  validation {
    condition     = contains(["job-bookmark-enable", "job-bookmark-disable", "job-bookmark-pause"], var.glue_jobs_bookmark)
    error_message = "Valid values for var: glue_jobs_bookmark are (job-bookmark-enable, job-bookmark-disable, job-bookmark-pause)."
  }
}

variable "glue_crawl_recrawl_behavior" {
  type    = string
  default = "CRAWL_NEW_FOLDERS_ONLY"
  validation {
    condition     = contains(["CRAWL_EVENT_MODE", "CRAWL_EVERYTHING", "CRAWL_NEW_FOLDERS_ONLY"], var.glue_crawl_recrawl_behavior)
    error_message = "Valid values for var: glue_crawl_recrawl_behavior are (CRAWL_EVENT_MODE, CRAWL_EVERYTHING, CRAWL_NEW_FOLDERS_ONLY)."
  }
}

### Redshift ###
variable "redshift_username" {
  type    = string
  default = null
}

variable "redshift_password" {
  type      = string
  sensitive = true
  default   = null
}

### Quicksight ###
variable "quicksight_user_arn" {
  type    = string
  default = null
}

### Analytics ###
variable "my_email" {
  type    = string
  default = null
}