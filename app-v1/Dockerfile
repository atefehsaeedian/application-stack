FROM python:3.12-slim

RUN useradd --system --no-create-home --shell /usr/sbin/nologin appuser

WORKDIR /app

COPY app.py .

USER appuser

ENV APP_VERSION=v1

EXPOSE 8001

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
	CMD python3 -c "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8001/health', timeout=2)" || exit 1

CMD ["python3", "app.py"]

