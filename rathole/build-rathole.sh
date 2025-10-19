cat > Dockerfile <<'EOF'
FROM rust:1.79 as builder
WORKDIR /app
RUN git clone --branch main --depth 1 https://github.com/rapiz1/rathole.git . && \
    cargo build --release

FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y ca-certificates && rm -rf /var/lib/apt/lists/*
RUN mkdir -p /var/log/rathole
COPY --from=builder /app/target/release/rathole /usr/local/bin/rathole
ENTRYPOINT ["rathole"]
CMD ["-c", "/etc/rathole/server.toml"]
EOF

docker build -t rathole:local .

cat > docker-compose.yml <<'EOF'
services:
  rathole-server:
    image: rathole:local
    container_name: rathole-server
    restart: unless-stopped
    ports:
      - "2333:2333/tcp"
      - "3889:3389/tcp"
      - "3889:3389/udp"
    volumes:
      - ./server.toml:/etc/rathole/server.toml:ro
      - /var/log/rathole:/var/log
    command: ["-c", "/etc/rathole/server.toml"]
EOF

docker compose up -d

docker logs -f rathole-server
