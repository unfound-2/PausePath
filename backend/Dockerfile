FROM python:3.12-slim
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
COPY migrations ./migrations
COPY scripts ./scripts
RUN useradd --uid 10001 --create-home appuser
USER appuser
EXPOSE 10000
CMD ["python", "scripts/start.py"]
