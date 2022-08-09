# AWS Twitter Data Analyst
Project to Learn Data analyst in AWS using twitter data

## Usefull Links

[NBA Players Twitter Accounts](https://www.basketball-reference.com/friv/twitter.html)

[Project Example](https://medium.com/fernando-pereiro/analyzing-twitter-on-real-time-with-aws-big-data-and-machine-learning-services-1fa888f962cf)


## Deploy

```bash
make deploy
```

## DataCollection APP

### Run Local

* Copy .env.example to .env and add your variables values
  * When the app runs locally, you need have AWS PROFILE configure in your aws credentials file with permissions to assume a role with the necessary permissions to send records to Kinesis firehose

```shell
make run-collection
```

## Data ETL / Catalog

* Run Glue Job to Drop duplicates

```shell
make run-drop-duplicates
```

* Run Crawler

```shell
make run-crawler
```

## WIP

* Firehose
  * Enable Comprehension 
  * Enable File Format Conversion to Parquet/ORC
* Glue Crawler
  * Add custom classifiers
* EMR 
  * Deploy Transient EMR
  * Run Hive QL Job
    * Use Analytics Functions. See udemy course 
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
  * Load output from EMR to Redshift
* Quicksight
  * Percentil Graph
* Amazon Rekogniton
  * Analysis Athletes Photos and identify the objects
* Amazon Translate
  * Translate Tweets
* Amazon Comprehend
  * Tweets Sentimental Analysis
* Firehose Data Analytics
  * Check for NBA Tempering. Use window analysis. 3 tweets in 5 minutes = tempering
* Data Profiling Solution