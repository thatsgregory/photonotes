def handler(event, context):
    print("S3 Event Triggered!")
    return {'statusCode': 200, 'body': 'OK'}
