# Chatbot (Datalfred)

* [I. Project Overview](#i-project-overview)
* [II. Architecture / Design](#ii-architecture--design)
* [III. Prerequisites](#iii-prerequisites)
* [IV. Installation / Setup](#iv-installation--setup)
* [V. Usage](#v-usage)
* [VI. Infrastructure](#vi-infrastructure)
* [VII. Configuration](#vii-configuration)
* [VIII. Project Structure](#viii-project-structure)
  * [A. Application Code](#a-application-code)
  * [B. Infrastructure as Code](#b-infrastructure-as-code)
* [IX. Limitations / Assumptions](#ix-limitations--assumptions)

## I. Project Overview

Datalfred is an AI-powered chatbot designed to assist users in interacting with a data lake platform on AWS. The chatbot provides capabilities for querying data, investigating AWS infrastructure issues, and managing ingestion workflows. 

The system is deployed as an AWS Lambda function accessible via Slack, using AWS Bedrock for LLM inference and integrating with various AWS services including Athena, Glue Data Catalog, Step Functions, CloudWatch, and ECS/EMR for data operations.

## II. Architecture / Design

### High-Level Components

The system follows a multi-agent architecture built on the `strands` framework:

1. **Main Agent** (`main_agent.py`)
   - Orchestrates the overall conversation flow
   - Routes user requests to specialized sub-agents
   - Manages conversation history using a sliding window approach
   - Tracks token usage and calculates costs

2. **Sub-Agents**
   - **Data Analyst Agent** (`data_analyst.py`): Queries data from the Glue Data Catalog and executes SQL queries via Athena
   - **Run Guy Agent** (`run_guy.py`): Investigates AWS infrastructure issues, monitors ingestion jobs (Step Functions, ECS, EMR), and can redrive failed executions

3. **Slack Integration** (`slack.py`)
   - Validates Slack webhook signatures to prevent unauthorized access
   - Sends and receives messages from Slack channels
   - Manages threaded conversations

4. **Lambda Entrypoint** (`lambda_entrypoint.py`)
   - Receives Slack events via Lambda function URL
   - Implements timeout failsafe mechanism to prevent Lambda execution timeouts
   - Authorizes users based on Slack user IDs

5. **Failsafe Lambda** (`chatbot_failsafe/main.py`)
   - Automatically disables the main chatbot Lambda if too many authentication failures are detected (>100 in 1 hour)
   - Triggered by CloudWatch alarms monitoring signature validation failures

### Infrastructure

The infrastructure is defined using Terraform and includes:

- **AWS Bedrock Inference Profiles**: Three profiles (large, medium, small) using different Claude and Amazon Nova models
- **Lambda Function**: Containerized Python application deployed via ECR
- **S3 Bucket**: Stores Athena query results and conversation session data
- **Athena Workgroup**: Configured for SQL query execution
- **CloudWatch**: Logs and alarms for monitoring and failsafe triggering
- **IAM Roles & Policies**: Fine-grained permissions for Lambda execution

The chatbot uses the `strands-agents` framework for agent orchestration and AWS services for data access and infrastructure management.

## III. Prerequisites

- **Python**: 3.13
- **Poetry**: For dependency management (version 2.1.4 in Dockerfile)
- **AWS Account**: With permissions to deploy Lambda, Bedrock, S3, Athena, IAM, CloudWatch, and Glue resources
- **Terraform**: For infrastructure deployment (backend configured for S3 with DynamoDB state locking)
- **Docker**: For building the Lambda container image
- **AWS CLI**: Configured with appropriate credentials
- **Slack Workspace**: With administrator access to create and configure a Slack app
- **AWS Bedrock Access**: Models must be enabled in your AWS account (Claude Sonnet 4.5, Claude Haiku 3, Amazon Nova Pro)

## IV. Installation / Setup

### Local Development Setup

1. **Clone the repository**
   ```bash
   git clone <repository-url>
   cd chatbot
   ```

2. **Install Python dependencies**
   ```bash
   cd code
   poetry install --with agent
   ```

3. **Configure AWS credentials**
   Ensure your AWS CLI is configured with credentials for the target AWS account:
   ```bash
   aws configure
   ```

4. **Set up required AWS Secrets**
   
   Create a Secrets Manager secret with the following structure:
   ```json
   {
     "token": "xoxb-your-slack-bot-token",
     "signing_secret": "your-slack-signing-secret",
     "slack_channel_id": "C01234567"
   }
   ```
   
   The secret name should follow the pattern: `{project_name}_slack_alerting_prod`

### Infrastructure Deployment

1. **Navigate to the infrastructure directory**
   ```bash
   cd iac
   ```

2. **Create a `terraform.tfvars` file**
   ```hcl
   project_name                    = "poc"
   git_repository                  = "your-git-repo-url"
   failure_notification_receivers  = "email1@example.com,email2@example.com"
   authorized_slack_users          = "U01234567,U89ABCDEF"
   role_to_assume_arn             = "arn:aws:iam::123456789012:role/deployment-role"
   ```

3. **Initialize Terraform with backend configuration**
   ```bash
   terraform init \
     -backend-config="bucket=$TERRAFORM_BACKEND_BUCKET" \
     -backend-config="dynamodb_table=$TERRAFORM_BACKEND_DYNAMODB"
   ```

4. **Select or create a workspace** (determines the stage/environment)
   ```bash
   terraform workspace new prod
   # or
   terraform workspace select prod
   ```

5. **Deploy the infrastructure**
   ```bash
   terraform plan
   terraform apply
   ```

   This will:
   - Build and push the Docker image to ECR
   - Create the Lambda function with the container image
   - Set up Bedrock inference profiles
   - Configure S3, Athena, CloudWatch, and IAM resources
   - Deploy the failsafe Lambda and CloudWatch alarm

6. **Retrieve the Lambda Function URL**
   
   After deployment, get the Lambda function URL from Terraform outputs:
   ```bash
   terraform output
   ```
   
   You will need this URL in the next step to configure your Slack app.

### Slack App Configuration

The chatbot requires a Slack app to be created and configured in your Slack workspace. Follow these steps:

1. **Create a new Slack app** at [api.slack.com/apps](https://api.slack.com/apps)

2. **Use the following app manifest**, replacing the placeholder values:
   - `$APPLICATION_NAME`: Choose a display name for your bot (e.g., "Datalfred")
   - `$AWS_LAMBDA_FUNCTION_URL`: Use the Lambda function URL from the Terraform output above

   ```json
   {
       "display_information": {
           "name": "$APPLICATION_NAME"
       },
       "features": {
           "app_home": {
               "home_tab_enabled": false,
               "messages_tab_enabled": true,
               "messages_tab_read_only_enabled": false
           },
           "bot_user": {
               "display_name": "$APPLICATION_NAME",
               "always_online": false
           }
       },
       "oauth_config": {
           "scopes": {
               "bot": [
                   "app_mentions:read",
                   "chat:write",
                   "chat:write.customize",
                   "commands",
                   "im:read",
                   "im:write",
                   "incoming-webhook",
                   "reactions:read",
                   "reactions:write",
                   "im:history",
                   "mpim:history"
               ]
           }
       },
       "settings": {
           "event_subscriptions": {
               "request_url": "$AWS_LAMBDA_FUNCTION_URL",
               "user_events": [
                   "message.app_home"
               ],
               "bot_events": [
                   "app_mention",
                   "message.im"
               ]
           },
           "org_deploy_enabled": false,
           "socket_mode_enabled": false,
           "token_rotation_enabled": false
       }
   }
   ```

3. **Install the app to your Slack workspace**
   
   After creating the app with the manifest, click "Install to Workspace" and authorize the requested permissions.

4. **Copy the credentials to AWS Secrets Manager**
   
   From the Slack app settings, retrieve:
   - **Bot User OAuth Token** (from "OAuth & Permissions" → starts with `xoxb-`)
   - **Signing Secret** (from "Basic Information" → "App Credentials")
   
   Update your AWS Secrets Manager secret (created in step 4 of Local Development Setup) with these values.

5. **Verify the configuration**
   
   Send a direct message to your bot in Slack or mention it in a channel. If configured correctly, the bot should respond (or indicate if you're not in the authorized users list).

## V. Usage

### Command-Line Interface (CLI)

The chatbot can be run interactively from the command line:

```bash
poetry run chatbot --project-name <project_name> --stage-name <stage> --model-size <size>
```

**Options:**
- `-p, --project-name` (required): Name of the project
- `-s, --stage-name` (optional, default: `prod`): Environment name
- `-m, --model-size` (optional, default: `large`): Model size (`large`, `medium`, `small`)
- `-d, --print-sub-agent-debug` (optional, flag): Print debug output from sub-agents
- `-id, --session-id` (optional): Session ID for conversation persistence
- `-up, --user-prompt` (optional): Single prompt for one-shot execution instead of interactive mode

**Examples:**

Interactive mode:
```bash
poetry run chatbot -p poc -s prod -m large
```

One-shot query:
```bash
poetry run chatbot -p poc -s prod -m medium -up "Show me tables in the analytics database"
```

With session persistence:
```bash
poetry run chatbot -p poc -s prod -id my-session-123
```

### Slack Interface

Users can interact with Datalfred by mentioning the bot in a Slack channel or sending it a direct message. The bot will:

1. Validate the request signature
2. Check if the user is authorized (via `AUTHORIZED_SLACK_USERS` environment variable)
3. Process the question using the main agent and sub-agents
4. Reply in the same Slack thread

**Slack User Authorization:**
Only Slack users whose IDs are listed in the `authorized_slack_users` Terraform variable can use the bot.

**Finding Slack User IDs:**
To find a user's Slack ID, click on their profile in Slack, then click the three dots (More) → "Copy member ID".

### Agent Capabilities

- **Query Data**: Ask questions about data in the data lake (Glue Catalog, Athena queries)
  - Example: _"What tables are in the customer database?"_
  - Example: _"Show me the last 10 records from the sales table"_

- **Investigate Infrastructure**: Check status of ingestion jobs, Step Functions, ECS tasks, CloudWatch logs
  - Example: _"What's the status of the latest ingestion run?"_
  - Example: _"Show me errors in the data-pipeline CloudWatch logs"_

- **Redrive Executions**: Restart failed Step Function executions (only when explicitly requested)
  - Example: _"Redrive the failed execution for pipeline X"_

### Cost Tracking

The chatbot tracks token usage and provides cost estimates after each conversation. It will also suggest using a smaller model size if costs exceed expectations.

## VI. Infrastructure

### Terraform Resources

The infrastructure is organized into the following modules:

1. **Bedrock Inference Profiles** (`bedrock_inference_profile.tf`)
   - Creates three inference profiles for different model sizes
   - Large: Claude Sonnet 4.5
   - Medium: Claude Haiku 3
   - Small: Amazon Nova Pro

2. **Lambda Function** (`lambda_chatbot.tf`)
   - Container-based Lambda function (900s timeout, 520 MB memory)
   - Uses a Terraform module to build and push Docker images to ECR
   - Automatically rebuilds when code changes are detected (via file hash triggers)
   - Exposes a Lambda function URL for Slack webhook integration

3. **S3 Bucket** (`s3.tf`)
   - Stores Athena query results (7-day lifecycle)
   - Stores conversation session data with versioning enabled
   - Intelligent tiering for cost optimization
   - Server-side encryption (AES256)

4. **Athena Workgroup** (`athena_workgroup.tf`)
   - Configured with output location in S3
   - Enforces workgroup configuration

5. **Failsafe Lambda** (`lambda_chatbot_failsafe.tf`)
   - Monitors CloudWatch logs for authentication failures
   - Triggers a CloudWatch alarm if >100 signature mismatches occur in 1 hour
   - Automatically sets the main Lambda concurrency to 0 (disabling it) when triggered
   - Sends email notifications to configured recipients

### Deployment Workflow

- **GitLab CI**: Pipelines are defined in `.gitlab-ci.yml` using shared templates from a central repository
- **Stages**: `init`, `format`, `security`, `deploy`, `mirror_to_github`
- **Environment Selection**: Determined by Git branch name in CI, or by Terraform workspace locally
- **Naming Convention**: Resources follow `{project_name}_{domain_name}_{stage_name}_<resource_name>` pattern
- **Backend**: Terraform state is stored in S3 with DynamoDB locking (configured at `terraform init` time)

## VII. Configuration

### Environment Variables (Lambda)

The following environment variables are configured for the Lambda function:

- `PROJECT_NAME`: Project identifier (e.g., `poc`)
- `DOMAIN_NAME`: Domain/component name (hardcoded to `chatbot`)
- `STAGE_NAME`: Environment name (e.g., `prod`, `dev`)
- `SLACK_SECRET_ARN`: ARN of the Secrets Manager secret containing Slack credentials
- `AUTHORIZED_SLACK_USERS`: Comma-separated list of Slack user IDs authorized to use the bot

### Terraform Variables

Required variables (defined in `variables.tf`):

- `project_name`: Name of the project
- `git_repository`: Git repository URL
- `failure_notification_receivers`: Comma-separated email addresses for failure alerts
- `authorized_slack_users`: Comma-separated Slack user IDs
- `role_to_assume_arn`: (Optional) IAM role ARN for Terraform to assume during deployment

### Slack App Configuration

The Slack app requires the following OAuth scopes (configured via app manifest):

**Bot Token Scopes:**
- `app_mentions:read`: Detect when the bot is mentioned
- `chat:write`: Send messages as the bot
- `chat:write.customize`: Customize message appearance
- `commands`: Support slash commands (if implemented)
- `im:read`, `im:write`: Read and send direct messages
- `im:history`, `mpim:history`: Access message history in DMs
- `incoming-webhook`: Post messages to channels
- `reactions:read`, `reactions:write`: Read and add reactions

**Event Subscriptions:**
- `app_mention`: Triggered when the bot is mentioned in a channel
- `message.im`: Triggered when a direct message is sent to the bot
- `message.app_home`: Triggered when a message is sent in the app home

### Local Configuration

- **Terraform Workspace**: Determines the `stage_name` for local deployments
- **AWS Region**: Default region is `eu-west-1` (configured in `terraform.tf`)
- **Model Size**: Can be set via CLI (`--model-size`) to control cost/performance tradeoff

### Conversation Settings

- **Sliding Window Size**: 20 messages maximum in conversation history
- **Session Storage**: Persisted in S3 for continued conversations (when session ID is provided)
- **Lambda Timeout**: 900 seconds (15 minutes)
- **Failsafe Trigger**: 100 signature validation failures in 1 hour

## VIII. Project Structure

### A. Application Code

Located in the `code/` directory:

```
code/
├── chatbot/                      # Main application package
│   ├── __init__.py
│   ├── main_agent.py             # Main orchestration agent
│   ├── lambda_entrypoint.py      # AWS Lambda handler
│   ├── slack.py                  # Slack integration (webhooks, signatures)
│   └── sub_agents/               # Specialized agents
│       ├── data_analyst.py       # Queries Glue/Athena
│       └── run_guy.py            # AWS infrastructure investigation
├── chatbot_failsafe/             # Emergency shutoff Lambda
│   └── main.py
├── pyproject.toml                # Poetry dependencies
└── Dockerfile                    # Lambda container image definition
```

**Key Files:**

- `main_agent.py`: Entry point for the chatbot, orchestrates sub-agents, manages conversation state, and calculates costs
- `lambda_entrypoint.py`: AWS Lambda handler, processes Slack events, implements timeout failsafe
- `slack.py`: Handles Slack signature validation, message sending, and event filtering
- `sub_agents/`: Each sub-agent is a specialized tool with its own system prompt and capabilities

### B. Infrastructure as Code

Located in the `iac/` directory:

```
iac/
├── terraform.tf                  # Provider and backend configuration
├── locals.tf                     # Local variables (domain_name, stage_name)
├── variables.tf                  # Input variables
├── data.tf                       # Data sources (AWS account, region, secrets)
├── lambda_chatbot.tf             # Main Lambda function and IAM
├── lambda_chatbot_failsafe.tf    # Failsafe Lambda and CloudWatch alarm
├── bedrock_inference_profile.tf  # Bedrock model configurations
├── s3.tf                         # S3 bucket for Athena and sessions
├── athena_workgroup.tf           # Athena workgroup configuration
└── outputs.tf                    # Terraform outputs
```

**Key Files:**

- `lambda_chatbot.tf`: Defines the main Lambda function, builds Docker images via a reusable Terraform module, and manages IAM permissions
- `bedrock_inference_profile.tf`: Creates three Bedrock inference profiles for different model sizes
- `lambda_chatbot_failsafe.tf`: Implements the security failsafe mechanism with CloudWatch alarms

## IX. Limitations / Assumptions

1. **AWS Region**: Infrastructure is deployed in `eu-west-1` by default (Ireland).

2. **GitLab CI Dependency**: CI/CD pipelines rely on GitLab CI templates that are not present in GitHub mirrors. GitHub should be considered read-only.

3. **Bedrock Model Availability**: The chatbot assumes that the required Bedrock models (Claude Sonnet 4.5, Claude Haiku 3, Amazon Nova Pro) are enabled in the AWS account and region.

4. **Slack App Configuration**: The chatbot requires a Slack app to be manually created and configured using the provided manifest. The Lambda function URL must be available before configuring the Slack app's event subscription endpoint.

5. **Slack Secrets**: The chatbot expects a Secrets Manager secret named `{project_name}_slack_alerting_prod` with specific fields (`token`, `signing_secret`, `slack_channel_id`).

6. **Session Persistence**: Conversation history is only persisted when a `session_id` is provided. In Slack mode, the Slack user ID is used as the session ID.

7. **Lambda Timeout**: The Lambda function has a 15-minute timeout. Long-running queries or operations may be interrupted by the failsafe mechanism (triggered at <3 minutes remaining).

8. **Cost Tracking**: Token usage and cost calculations are approximations based on hardcoded pricing for specific models. Actual costs may vary.

9. **Terraform Backend**: Backend configuration (S3 bucket and DynamoDB table) must be provided at `terraform init` time and is not hardcoded.

10. **Failsafe Threshold**: The security failsafe is triggered after 100 failed signature validations in 1 hour. This threshold is hardcoded and may need adjustment based on usage patterns.

11. **Tool Error Handling**: Sub-agents are instructed not to retry failed tool calls (except for SQL syntax errors) to prevent infinite loops and reduce costs.

12. **Read-Only AWS Operations**: The "Run Guy" agent is restricted to read-only AWS operations, with the exception of redriving failed Step Function executions when explicitly requested by authorized users.

13. **Workspace-Based Environment Selection**: When running Terraform locally, the environment (stage) is determined by the active Terraform workspace. The default workspace results in `stage_name=default`, which may not be intended for production use.
