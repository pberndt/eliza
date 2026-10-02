FROM python:3.13-slim
WORKDIR /tests
RUN pip install --no-cache-dir openai==2.26.0
COPY tests/e2e.py .
COPY tools/image_delta.py tools/
COPY tests/test_image_delta.py .
ENTRYPOINT ["python", "e2e.py"]
