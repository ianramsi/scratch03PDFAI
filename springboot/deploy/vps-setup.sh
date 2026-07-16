#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# vps-setup.sh  —  run ONCE on a fresh Ubuntu 22.04 VPS (as root).
#
# What it does:
#   1. Installs Docker + Docker Compose plugin
#   2. Creates /opt/pdf-finalizer with a .env from the example
#   3. Uses the INIT nginx config (HTTP only) so certbot can issue the cert
#   4. Issues the Let's Encrypt cert
#   5. Switches to the full HTTPS nginx config
#
# Usage (from your LOCAL machine):
#   ssh root@76.13.22.198 'bash -s' < deploy/vps-setup.sh
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

DOMAIN="supdf.suplo.my.id"
EMAIL="your@email.com"          # ← change to your real email for cert expiry notices
APP_DIR="/opt/pdf-finalizer"

echo "──── Installing Docker ────"
apt-get update -q
apt-get install -y -q ca-certificates curl gnupg lsb-release
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Write the Docker repo as a single printf-generated line.
# Multi-line echo with backslash continuations breaks when piped via ssh;
# printf gives us exact control and avoids corrupted sources.list entries.
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$(dpkg --print-architecture)" "$(lsb_release -cs)" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -q
apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin
systemctl enable docker
systemctl start  docker
echo "Docker $(docker --version) installed."

echo "──── Creating app directory ────"
mkdir -p "${APP_DIR}/nginx/conf.d"
mkdir -p "${APP_DIR}/nginx/certbot/conf"
mkdir -p "${APP_DIR}/nginx/certbot/www"

echo "──── Writing initial nginx config (HTTP only, for cert issuance) ────"
# The init config is copied here by deploy.sh; this just confirms the directory exists.
echo "  (nginx/conf.d will be populated by deploy.sh scp step)"

echo "──── Done. Next steps ────"
echo ""
echo "  1. From your LOCAL machine, run:"
echo "       ./deploy/deploy.sh"
echo "     This copies the image + configs to this VPS."
echo ""
echo "  2. Create /opt/pdf-finalizer/.env:"
echo "       cp /opt/pdf-finalizer/.env.example /opt/pdf-finalizer/.env"
echo "       nano /opt/pdf-finalizer/.env    # fill in real values"
echo ""
echo "  3. Start with the INIT config (HTTP only) first:"
echo "       cd /opt/pdf-finalizer"
echo "       # Ensure only pdf-finalizer-init.conf is in nginx/conf.d/"
echo "       docker compose up -d nginx certbot pdf-finalizer"
echo ""
echo "  4. Issue the Let's Encrypt certificate:"
echo "       docker compose run --rm certbot certonly \\"
echo "         --webroot --webroot-path=/var/www/certbot \\"
echo "         --email ${EMAIL} --agree-tos --no-eff-email \\"
echo "         -d ${DOMAIN}"
echo ""
echo "  5. Switch to the full HTTPS config:"
echo "       cd /opt/pdf-finalizer/nginx/conf.d"
echo "       mv pdf-finalizer-init.conf pdf-finalizer-init.conf.bak"
echo "       # The full pdf-finalizer.conf is already there from deploy.sh"
echo "       docker compose restart nginx"
echo ""
echo "  6. Test:"
echo "       curl https://${DOMAIN}/api/v1/forms/ping"
