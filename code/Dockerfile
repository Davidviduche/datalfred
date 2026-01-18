FROM --platform=linux/amd64 public.ecr.aws/lambda/python:3.13
RUN pip3 install --no-cache-dir poetry==2.1.4
WORKDIR $LAMBDA_TASK_ROOT/
CMD [ "chatbot.lambda_entrypoint.main" ]
COPY pyproject.toml .
COPY chatbot/. ./chatbot/
RUN poetry config virtualenvs.create false --local && poetry install --with agent
ENV PYTHONPATH $LAMBDA_TASK_ROOT/chatbot/
