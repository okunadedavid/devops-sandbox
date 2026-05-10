FROM python:3.12-slim

WORKDIR /workspace

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt
RUN apt-get update && apt-get install -y docker.io

COPY . .

CMD ["python", "api.py"]