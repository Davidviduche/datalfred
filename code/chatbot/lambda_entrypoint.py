import os
import logging
import json
import boto3
from chatbot.slack import send_slack_message
from chatbot.main_agent import main as chatbot_main
from chatbot.slack import check_slack_event, check_slack_signature, reply_to_slack

@check_slack_signature
@check_slack_event
def main(event: dict, lambda_context: "LambdaContext") -> dict:
    """
    Processes slack event if it is actually a question asked to maestro.
    Forwards question to RAG lambda, and reply in slack thread with the answer.
    """
    project_name = os.environ["PROJECT_NAME"]
    domain_name = os.environ["DOMAIN_NAME"]
    stage_name = os.environ["STAGE_NAME"]
    boto_session = boto3.session.Session()
    logger = logging.getLogger()
    logging.basicConfig(
        level=logging.INFO, format='%(message)s', force=True)
    logger.info("Received event: " + json.dumps(event))
    logger.info('Event passed checks. Now processing it ...')
    event_body = json.loads(event['body'])
    slack_event: dict = event_body.get('event', {})
    if slack_event.get("user") not in os.environ["AUTHORIZED_SLACK_USERS"].split(","):
        reply_to_slack(
            slack_event,
            "Looks like you are not authorized to use this slackbot, "
            "contact Datalfred owner if you think this is an error..."
        )
        logger.info(f"Unauthorized access by user '{slack_event.get('user', 'No user found')}'")
        return {
            'statusCode': 200,
            'body': '"Unauthorized access by unauthorized slack user'
        }


    logger.info('Sending waiter message to slack ...')
    reply_to_slack(
        slack_event,
        "Asking Datalfred..."
    )

    logger.info(f'Asking datalfred: {slack_event["text"]}')
    slack_user_prompt = slack_event['text']
    slack_user_prompt += "\n\nYour answer will be displayed in a slack message, format accordingly if and when relevant (especially, bold text must be surrounded by only one *, not two; hyperlink are formatted <http://someurl.com|like this>; and code blocks must not have the language specified after the triple ```)."
    logger.info(f'Using {slack_event["user"]}, the slack user, as session id')
    class LambdaTimeoutFalsafeException(Exception):
        pass
    def lambda_timeout_failsafe_callback(**kwargs):
        if "agent" in kwargs.keys():
            # if the remaining time of lambda execution is less than 3 minutes
            if lambda_context.get_remaining_time_in_millis() / 1000 < 180:
                raise LambdaTimeoutFalsafeException(
                    "Stopping agent execution to prevent AWS lambda function timeout.")
    try:
        response = chatbot_main(
            logger,
            boto_session,
            project_name,
            domain_name,
            stage_name,
            model_size="large",
            print_sub_agent_debug=True,
            user_prompt=slack_user_prompt,
            datalfred_chatbot_strands_session_id=slack_event["user"],
            agent_callback_function=lambda_timeout_failsafe_callback)
    except LambdaTimeoutFalsafeException:
        reply_to_slack(
            slack_event,
            "The lambda was about to timeout, aborting treatment..."
        )
    except Exception as error:
        reply_to_slack(
            slack_event,
            "Technical error while asking the datalfred agent..."
        )
        raise error

    logger.info("Sending response")
    reply_to_slack(
        slack_event,
        response
    )

    return {
        'statusCode': 200,
        'body': 'Datalfred answered successfuly'
    }
