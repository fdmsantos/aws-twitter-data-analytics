import json
import boto3
import base64
import os
from aws_kinesis_agg.deaggregator import deaggregate_records

sns_client = boto3.client('sns')


def lambda_handler(event, context):
    print(f"[lambda_function] Received event: {json.dumps(event)}")

    raw_kinesis_records = event['Records']
    #Deaggregate all records in one call
    user_records = deaggregate_records(raw_kinesis_records)

    #Iterate through deaggregated records
    for record in user_records:
        payload = str(base64.b64decode(record["kinesis"]["data"], validate=False), 'utf-8')
        json_properties = json.loads(payload)

        sns_client.publish(TopicArn=os.environ['TOPIC_ARN'],
                           Message="Nba Player " + json_properties['sourceplayer'] + " did " + str(json_properties['total']) + ' tweets to player ' + json_properties['destinationplayer'],
                           Subject="NBA Tampering Detect")

    return {
        'message' : 'Completed'
    }