FROM python:3.13-slim
WORKDIR /tests
RUN pip install --no-cache-dir openai==2.26.0
COPY tests/e2e.py .
ENTRYPOINT ["python", "e2e.py"]
