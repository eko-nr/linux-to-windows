FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*

RUN mkdir -p /var/log/rathole
COPY ./target/release/rathole /usr/local/bin/rathole
COPY ./server.toml /etc/rathole/server.toml

ENTRYPOINT ["rathole"]
CMD ["-s", "/etc/rathole/server.toml"]
