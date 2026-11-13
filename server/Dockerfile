FROM python:3.13-slim
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates && rm -rf /var/lib/apt/lists/*
RUN useradd --create-home relay && mkdir /data && chown relay:relay /data
WORKDIR /app
COPY server.py push.py .
USER relay
ENV TIHO_DB=/data/relay.sqlite3 TIHO_BIND=0.0.0.0
EXPOSE 8787
CMD ["python3", "server.py"]
