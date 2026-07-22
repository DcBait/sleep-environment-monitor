#!/usr/bin/env bash
# grafana_setup.sh — install Grafana OSS on Ubuntu 22.04
# Run after vm_setup.sh: bash scripts/grafana_setup.sh

set -euo pipefail

BOLD="\033[1m"; RESET="\033[0m"; GREEN="\033[32m"
log()  { echo -e "${GREEN}[grafana]${RESET} $*"; }
step() { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── 1. Add Grafana APT repo ───────────────────────────────────────────────────
step "Adding Grafana repository"
sudo apt-get install -y -qq apt-transport-https software-properties-common wget
sudo mkdir -p /etc/apt/keyrings/
wget -q -O - https://apt.grafana.com/gpg.key \
    | gpg --dearmor \
    | sudo tee /etc/apt/keyrings/grafana.gpg > /dev/null
echo "deb [signed-by=/etc/apt/keyrings/grafana.gpg] https://apt.grafana.com stable main" \
    | sudo tee /etc/apt/sources.list.d/grafana.list > /dev/null

# ── 2. Install ────────────────────────────────────────────────────────────────
step "Installing Grafana OSS"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq grafana

# ── 3. Enable and start ───────────────────────────────────────────────────────
step "Starting Grafana"
sudo systemctl enable --now grafana-server
log "Grafana running on port 3000."

# ── 4. OS firewall ────────────────────────────────────────────────────────────
step "Opening port 3000 in iptables"
sudo iptables -C INPUT -p tcp --dport 3000 -j ACCEPT 2>/dev/null \
    || sudo iptables -I INPUT -p tcp --dport 3000 -j ACCEPT
sudo netfilter-persistent save

VM_IP=$(curl -s --max-time 3 ifconfig.me 2>/dev/null || echo "<your-vm-public-ip>")

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<EOF

$(echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  Grafana installed. Manual steps remaining:
$(echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}")

1. Oracle Cloud Console → Networking → VCN → Security Lists
   Add ingress rule: TCP port 3000  (Grafana UI)

2. Open http://$VM_IP:3000
   Default login: admin / admin  (you'll be forced to change it)

3. Add PostgreSQL datasource:
   Connections → Data sources → Add new → PostgreSQL
     Host URL:     localhost:5432
     Database:     sleep_monitor
     Username:     sleep_user
     Password:     <your DB password>
     TLS/SSL mode: disable
   Save & test — should say "Database Connection OK"

4. Import the dashboard:
   Dashboards → New → Import
   Upload: grafana/dashboard_export.json
   Select the datasource you just created when prompted

EOF
