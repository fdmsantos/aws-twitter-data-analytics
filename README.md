# AWS Twitter Data Analyst
Project to Learn Data analyst in AWS using twitter data

## Usefull Links

[NBA Players Twitter Accounts](https://www.basketball-reference.com/friv/twitter.html)

[Project Example](https://medium.com/fernando-pereiro/analyzing-twitter-on-real-time-with-aws-big-data-and-machine-learning-services-1fa888f962cf)


## Deploy

```bash
cd deploy
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