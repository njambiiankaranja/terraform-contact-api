import json
import os
import re
import time
import uuid

import boto3

dynamodb = boto3.resource("dynamodb")
sns = boto3.client("sns")
table = dynamodb.Table(os.environ["TABLE_NAME"])
TOPIC_ARN = os.environ["TOPIC_ARN"]
RETENTION_DAYS = int(os.environ.get("RETENTION_DAYS", "90"))

EMAIL_PATTERN = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
LIMITS = {"name": 100, "email": 200, "message": 2000}


def response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body),
    }


def handler(event, context):
    try:
        data = json.loads(event.get("body") or "{}")
    except ValueError:
        return response(400, {"error": "Request body must be valid JSON"})

    if not isinstance(data, dict):
        return response(400, {"error": "Request body must be a JSON object"})

    # Honeypot: real visitors never fill this hidden field, bots often do
    if data.get("website"):
        return response(200, {"message": "Thank you"})

    fields = {}
    for key, limit in LIMITS.items():
        value = str(data.get(key, "")).strip()
        if not value:
            return response(400, {"error": f"{key} is required"})
        if len(value) > limit:
            return response(400, {"error": f"{key} is too long"})
        fields[key] = value

    if not EMAIL_PATTERN.match(fields["email"]):
        return response(400, {"error": "email is not valid"})

    now = int(time.time())
    item = {
        "id": str(uuid.uuid4()),
        "received_at": now,
        # DynamoDB TTL deletes the item after this time (epoch seconds)
        "expires_at": now + RETENTION_DAYS * 86400,
        **fields,
    }
    table.put_item(Item=item)

    sns.publish(
        TopicArn=TOPIC_ARN,
        Subject="New form submission",
        Message=f"From: {fields['name']} <{fields['email']}>\n\n{fields['message']}",
    )

    return response(200, {"message": "Thank you, your message was received"})