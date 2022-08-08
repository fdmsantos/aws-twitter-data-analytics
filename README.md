# AWS Twitter Data Analyst
Project to Learn Data analyst in AWS using twitter data

## Usefull Links

[NBA Players Twitter Accounts](https://www.basketball-reference.com/friv/twitter.html)

[Project Example](https://medium.com/fernando-pereiro/analyzing-twitter-on-real-time-with-aws-big-data-and-machine-learning-services-1fa888f962cf)


## Deploy

```bash
terraform init
terrraform apply
```

## DataCollection APP

### Run Local

* Create the environment variables represented .env.example file
  * When the app runs locally, you need have PROFILE configure in your aws credentials file with permissions to assume a role with the necessary permissions to send records to Kinesis firehose

```shell
cd 01-data-collection-app
go run main.go
```

## Data ETL / Catalog

* Run Glue Job

```shell
aws glue start-job-run --job-name $(terraform output -json | jq -r .glue_drop_duplicates_job.value)
```

* Run Crawler

```shell
aws glue start-crawler --name $(terraform output -json | jq -r .glue_tweet_crawler.value)
```

## WIP

* Firehose
  * Enable Comprehension 
  * Enable File Format Conversion to Parquet/ORC
* Glue Crawler
  * Add custom classifiers
* EMR 
  * Deploy Transient EME
  * Run Hive QL Job
    * Possible Query

```hiveql
SELECT context.entity.name, count(*)
FROM tweets, UNNEST(context_annotations) t(context)
WHERE context.domain.id = '60'
GROUP BY context.entity.name, year, month, day
HAVING year = '2022'
AND month = '08'
AND day = '05'
```

* Redshift
  * Load outpur from EMR to Redshift
* Quicksight