FROM python:3.13-slim
RUN useradd --create-home relay && mkdir /data && chown relay:relay /data
WORKDIR /app
COPY server.py .
USER relay
ENV TIHO_DB=/data/relay.sqlite3 TIHO_BIND=0.0.0.0
EXPOSE 8787
CMD ["python3", "server.py"]
