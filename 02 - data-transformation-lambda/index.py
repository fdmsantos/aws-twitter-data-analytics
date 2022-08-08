import base64
import json

def lambda_handler(event, context):
    output = []

    failed_records = 0

    for record in event['records']:
        try:

            payload = base64.b64decode(record['data'])
            payload_json = json.loads(payload)

            final_record = payload_json
            if "data" in payload_json:
                final_record = payload_json["data"][0]
                final_record["users"] = payload_json["includes"]["users"]

            output_record = {
                'recordId': record['recordId'],
                'result': 'Ok',
                'data': base64.b64encode(json.dumps(final_record).encode('utf-8')).decode('utf-8')
            }
        except:
            failed_records = failed_records + 1
            output_record = {
                'recordId': record['recordId'],
                'result': 'ProcessingFailed',
                'data': record['data']
            }


        output.append(output_record)

    print('Successfully processed {} records.'.format(len(event['records']) - failed_records))
    return {'records': output}

