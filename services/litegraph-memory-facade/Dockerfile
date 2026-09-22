FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PORT=8710

WORKDIR /app
COPY requirements.txt ./
RUN pip install --no-cache-dir -r requirements.txt
COPY memory_facade ./memory_facade
RUN useradd --create-home --uid 10001 appuser
USER appuser
EXPOSE 8710
CMD ["python", "-m", "memory_facade.app"]
