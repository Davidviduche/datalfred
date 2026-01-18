import os
import boto3


def main(event: dict, context: dict):
    client = boto3.client("lambda")
    response = client.put_function_concurrency(
        FunctionName=os.environ["DATALFRED_CHATBOT_FUNCTION_NAME"],
        ReservedConcurrentExecutions=0
    )
