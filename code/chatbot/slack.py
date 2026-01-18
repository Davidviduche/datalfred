from functools import wraps
import hashlib
import hmac
import json
import os
import requests
import time
import urllib
import boto3
from botocore.exceptions import ClientError
from slack_sdk import WebClient


def send_slack_message(message_content: str, channel_id: str=None, unfurl_links: bool=True) -> str:
    boto_session = boto3.session.Session()
    secretsmanager_client = boto_session.client("secretsmanager")
    secret_id = "poc_slack_alerting_prod"
    slack_info = json.loads(
        secretsmanager_client.get_secret_value(
            SecretId=secret_id)["SecretString"]
        )
    channel_id = channel_id if channel_id else slack_info.get("slack_channel_id")
    if not channel_id:
        raise ValueError(f"Did not find any slack channel in secret {secret_id} or in parameters.")
    slack_client = WebClient(token=slack_info["token"])
    slack_client.chat_postMessage(
        channel=channel_id, text=message_content, unfurl_links=unfurl_links)


def recover_secret(secret_arn: str, field: str) -> str:
    """
    Requests secrets manager to recover the secret that will help
    compute the signature of the message
    Return either the secret as a string,
    or an empty string if an error is met
    """
    print('Recovering slack secret ...')
    try:
        # Use the client to retrieve the secret
        fetch_secret_response = boto3.client("secretsmanager").get_secret_value(
            SecretId=secret_arn
    )
    except ClientError as e:
        print(f'Error while recovering slack secret at {secret_arn}: {e}')
        return ''
    secret = json.loads(fetch_secret_response['SecretString'])[field]
    print('Slack secret recovered')
    return secret


def reply_to_slack(event: dict, message: str) -> requests.Response:
    """
    Posts given message in slack thread specified in slack event.
    """
    data = urllib.parse.urlencode({
        "token": recover_secret(os.environ['SLACK_SECRET_ARN'], "token"),
        "channel": event["channel"],
        "text": message,
        "thread_ts": event["ts"],
        "user": event["user"],
        "link_names": True,
        "mrkdwn": True
    })
    data = data.encode("ascii")
    request = urllib.request.Request(
        "https://slack.com/api/chat.postMessage", data=data, method="POST")
    request.add_header("Content-Type", "application/x-www-form-urlencoded")
    res = urllib.request.urlopen(request).read()
    return res

def check_slack_event(lambda_handler):
    """
    Decorator that verifies that slack received event is actually an
    question aksed to maestro bot.
    If so, lambda handler will be called to get answer,
    if not, lambda_handler is skipped.
    """
    @wraps(lambda_handler)
    def wrapper(event: dict, context) -> dict:
        print(event['headers'])
        if 'x-slack-retry-num' in event['headers']:
            print('Event was a slack retry. Skipping ...')
            return {"statusCode": 202}

        if challenge := json.loads(event['body']).get('challenge'):
            print('Request was a slack challenge. Skipping ...')
            return {
                "statusCode": 200,
                "body": challenge
            }

        if json.loads(event['body']).get('event', {}).get('bot_profile'):
            print('Event was triggered by bot response. Skipping ...')
            return {"statusCode": 200}

        return lambda_handler(event, context)

    return wrapper


# ========================================================================
# SLACK SIGNATURE VALIDATION
# ========================================================================

def compute_signature(
    signing_secret: str,
    timestamp: int,
    body: dict
) -> str:
    """
    Computes payload signature based on slack secret
    Return the signature as a str
    """
    if isinstance(body, bytes):
        body = body.decode("utf-8")

    format_req = str.encode(f"v0:{timestamp}:{body}")
    encoded_secret = str.encode(signing_secret)
    request_hash = hmac.new(encoded_secret, format_req, hashlib.sha256).hexdigest()
    calculated_signature = f"v0={request_hash}"
    return calculated_signature

def check_slack_signature(lambda_handler):
    """
    Decorators put on top of lambda handler.
    Will compute signature from event body and slack secret stored in secrets manager,
    and compared it to the one given in headers.
    If the two are different, then body content is surely illicit, and not be processed.
    """
    @wraps(lambda_handler)
    def wrapper(event: dict, context) -> dict:
        print('Checking signature ...')
        headers = event['headers']
        timestamp = int(headers['x-slack-request-timestamp'])
        given_signature = headers['x-slack-signature']

        now = time.time()
        if abs(now - timestamp) > 60 * 5:
            # The request timestamp is more than five minutes from local time.
            # It could be a replay attack, so let's ignore it.
            print(f'Too much time occurs between request creation {timestamp} and its reception {now}. Refusing request ...')
            return {"statusCode": 408}

        if not (secret := recover_secret(os.environ['SLACK_SECRET_ARN'], "signing_secret")):
            print('Failed to recover slack secret')
            return {"statusCode": 500}

        computed_signature = compute_signature(secret, timestamp, event['body'])
        if computed_signature != given_signature:
            print('Signatures does not match. Refusing request ...')
            return {"statusCode": 401}
        print('Signatures comply. Proceeding further ...')
        return lambda_handler(event, context)
    return wrapper
