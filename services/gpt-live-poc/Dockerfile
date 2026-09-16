FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8090

WORKDIR /app

COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt

COPY live_poc ./live_poc

RUN useradd --create-home --uid 10001 appuser
USER appuser

EXPOSE 8090

CMD ["python", "-m", "live_poc.app"]
