# AWS Twitter Data Analyst

Project to Learn Data analyst in AWS using twitter data.

**NOTES**

This project isn't optimized for Production. 

Some Architecting decisions doesn't make sense in production only in learning context. 

The configurations aren't cost optimized due learning reasons. 

This architecture doesn't follow the security best practices.

Most of the AWS services used in this project don't have free tier. Deploy this, will have costs.

## Useful Links

[NBA Players Twitter Accounts](https://www.basketball-reference.com/friv/twitter.html)

[Project Example](https://medium.com/fernando-pereiro/analyzing-twitter-on-real-time-with-aws-big-data-and-machine-learning-services-1fa888f962cf)

## Deploy

***Pre Requisites***

* AWS Cli Configured
* Terraform
* EC2 Key Pair Created
* VPC Created at least with one Subnet

```bash
make deploy
```

## DataCollection APP

### Run Local

**Pre Requisites**

* Golang Installed
* Copy .env.example to .env and add your variables values
  * When the app runs locally, you need have AWS PROFILE configure in your aws credentials file with permissions to assume a role with the necessary permissions to send records to Kinesis firehose

```shell
make run-collection
```

## Data ETL / Catalog

**Pre Requisites:** AWS Cli Configured

* Run Glue Job to Drop duplicates

```shell
make run-drop-duplicates
```

* Run Crawler

```shell
make run-crawler
```

* Run Glue Workflow
  * Glue Workflow runs first glue job drop duplicates and the glue crawler

```shell
make run-glue-workflow
```

## EMR

* SSH

```shell
make EMR_KEY=<key_location> ssh-emr
```

## WIP

* Data Collection App
  * Create Docker File
  * Deploy on ECS
* Firehose
  * Enable Comprehension 
  * Enable File Format Conversion to Parquet/ORC
* Glue Crawler
  * Add custom classifiers
  * Glue Workflow
    * Notification when failed
* EMR 
  * Deploy Transient EMR (Step Functions)
  * Run Hive QL Job
    * Use Analytics Functions. See udemy course

```sql
SELECT context.entity.name, count(*)
FROM twitter_nba_db.tweets, UNNEST(context_annotations) t(context)
WHERE context.domain.id = '60'
GROUP BY context.entity.name, year, month, day
HAVING year = '2022'
AND month = '08'
AND day = '05'
```

```hiveql
CREATE EXTERNAL TABLE IF NOT EXISTS twitter_nba_db.nba_players_tweets_total
(year string, month string, day string, player string, total int)
  row format
    serde 'org.apache.hive.hcatalog.data.JsonSerDe'
  LOCATION 's3://twitter-nba-datalake/hive'

INSERT INTO TABLE twitter_nba_db.nba_players_tweets_total
SELECT year, month, day, context.entity.name, count(*) as total
FROM twitter_nba_db.tweets
       LATERAL VIEW explode(context_annotations) t AS context
WHERE context.domain.id = '60'
GROUP BY context.entity.name,year, month, day
HAVING year = '2022'
   AND month = '08'
   AND day = '09';
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