import boto3
import random
import json
import time
import datetime
import argparse

source_players = ["KingJames", "AntDavis23", "KyrieIrving", "StephenCurry30"]
destination_players = ["Lebron James", "Anthony Davis", "Kyrie Irving", "Stephen Curry"]

def randint(min=0, max=100000):
    a = random.randint(min, max)
    return a


def get_data():
    return {
        'event_time': datetime.datetime.now().isoformat(),
        'data': [{
            "text": "Dummy Text",
            "context_annotations": [
                {
                    "domain": {
                        "id": "3",
                        "name": "TV Shows",
                        "description": "Television shows from around the world"
                    },
                    "entity": {
                        "id": "10000607734",
                        "name": "NBA Basketball",
                        "description": "All the latest basketball action from the NBA."
                    }
                },
                {
                    "domain": {
                        "id": "60",
                        "name": "Athlete",
                        "description": "An athlete in the world, like Serena Williams or Lionel Messi"
                    },
                    "entity": {
                        "id": "1142269203002454017",
                        "name": random.choice(destination_players)
                    }
                }

            ],
            "id": randint(),
        }],
        'includes': {
            "users": [
                {
                    "username": random.choice(source_players),
                }
            ]
        }
    }


def generate(stream_name, kinesis_client):
    while True:
        data = get_data()
        print(data)
        kinesis_client.put_record(
            StreamName=stream_name,
            Data=json.dumps(data),
            PartitionKey="partitionkey")
        time.sleep(2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()

    parser.add_argument('--stream_name', type=str, required=True,
                        help='Kinesis Data Stream name to sent records')

    args = parser.parse_args()
    generate(args.stream_name, boto3.client('kinesis'))
