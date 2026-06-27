FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
# agent-framework はプレリリース系のため --pre を許可（安定版があればそちらを優先）
RUN pip install --no-cache-dir --pre -r requirements.txt

COPY app ./app

EXPOSE 8000
ENV HOST=0.0.0.0 PORT=8000

# Container App の Ingress target-port と一致（8000）
CMD ["sh", "-c", "uvicorn app.main:app --host 0.0.0.0 --port ${PORT}"]
