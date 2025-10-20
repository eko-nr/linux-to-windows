#!/usr/bin/env bash
set -e
sudo apt update
sudo apt upgrade -y

# 1. Install dependencies
sudo apt install -y \
  ca-certificates \
  curl \
  gnupg \
  lsb-release

# 2. Add Docker’s official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | \
  sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

# 3. Set up the stable repository
echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
   https://download.docker.com/linux/debian \
   $(. /etc/os-release && echo \"$VERSION_CODENAME\") stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# 4. Update apt package index
sudo apt update

# 5. Install Docker Engine and related packages
sudo apt install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

# 6. Start and enable Docker service
sudo systemctl enable --now docker

echo "🚀 Building Rathole Server (v0.5.x) Docker image..."

# Pastikan Rust toolchain terpasang
if ! command -v cargo &> /dev/null; then
  echo "🦀 Installing Rust toolchain..."
  curl https://sh.rustup.rs -sSf | sh -s -- -y
  source $HOME/.cargo/env
fi

# Install dependency sistem
echo "📦 Installing build dependencies..."
apt-get update -y
apt-get install -y pkg-config libssl-dev ca-certificates git build-essential

# Clone repo Rathole kalau belum ada
if [ ! -d "rathole-src" ]; then
  echo "📥 Cloning Rathole repository..."
  git clone --branch main --depth 1 https://github.com/rapiz1/rathole.git rathole-src
else
  echo "🔄 Updating existing Rathole source..."
  cd rathole-src && git pull && cd ..
fi

# Build Rathole dengan fitur server dan rustls
echo "🛠️ Building Rathole binary..."
cd rathole-src
cargo clean
cargo build --release --no-default-features --features rustls,server
cd ..

# Pastikan target folder ada
mkdir -p ./target/release
cp ./rathole-src/target/release/rathole ./target/release/rathole

# Build Docker image
echo "🐳 Building Docker image..."
docker compose build

# Jalankan container
echo "🚀 Starting Rathole server container..."
docker compose up -d

echo "✅ Rathole server is now running!"
echo "👉 Check logs with: docker compose logs -f"