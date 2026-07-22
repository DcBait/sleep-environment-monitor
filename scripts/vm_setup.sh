#!/usr/bin/env bash
# vm_setup.sh — run once on a fresh Oracle Cloud Ubuntu 22.04 VM
# Usage: bash scripts/vm_setup.sh
# Must be run from the repo root: cd ~/sleep-environment-monitor && bash scripts/vm_setup.sh

set -euo pipefail

# ── Config — edit these before running ────────────────────────────────────────
DB_NAME="sleep_monitor"
DB_USER="sleep_user"

# ── Helpers ───────────────────────────────────────────────────────────────────
BOLD="\033[1m"; RESET="\033[0m"; GREEN="\033[32m"
log()  { echo -e "${GREEN}[setup]${RESET} $*"; }
step() { echo -e "\n${BOLD}── $* ──${RESET}"; }

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VENV_DATA="$PROJECT_DIR/.venv/data_pipeline"
VENV_SUMMARY="$PROJECT_DIR/.venv/summary_bot"

# Prompt for DB password (not stored in script)
read -rsp "$(echo -e "${BOLD}Enter a password for the PostgreSQL user '$DB_USER':${RESET} ")" DB_PASS
echo

# ── 1. System update ──────────────────────────────────────────────────────────
step "System update"
sudo apt-get update -qq
sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq

# ── 2. Install system packages ────────────────────────────────────────────────
step "Installing packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    postgresql postgresql-contrib \
    mosquitto mosquitto-clients \
    python3-pip python3-venv \
    iptables-persistent \
    git
log "Packages installed."

# ── 3. PostgreSQL ─────────────────────────────────────────────────────────────
step "Configuring PostgreSQL"
sudo systemctl enable --now postgresql

# Create user (idempotent)
sudo -u postgres psql -tc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" \
    | grep -q 1 \
    || sudo -u postgres psql -c "CREATE USER $DB_USER WITH PASSWORD '$DB_PASS';"

# Create database (idempotent)
sudo -u postgres psql -tc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" \
    | grep -q 1 \
    || sudo -u postgres psql -c "CREATE DATABASE $DB_NAME OWNER $DB_USER;"

# Run migration
sudo -u postgres psql -d "$DB_NAME" -f "$PROJECT_DIR/migrations/001_init.sql"
log "Migration applied."

# Grant schema + sequence permissions to app user
sudo -u postgres psql -d "$DB_NAME" <<SQL
GRANT USAGE ON SCHEMA public, staging, mart TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA public   TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA staging  TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL TABLES    IN SCHEMA mart     TO $DB_USER;
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public   TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA public  GRANT ALL ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA staging GRANT ALL ON TABLES TO $DB_USER;
ALTER DEFAULT PRIVILEGES IN SCHEMA mart    GRANT ALL ON TABLES TO $DB_USER;
SQL
log "Postgres permissions granted."

# ── 4. Mosquitto ──────────────────────────────────────────────────────────────
step "Configuring Mosquitto"
sudo tee /etc/mosquitto/conf.d/sleep-monitor.conf > /dev/null <<'EOF'
listener 1883
allow_anonymous true
EOF

sudo systemctl enable --now mosquitto
sudo systemctl restart mosquitto
log "Mosquitto running on port 1883."

# ── 5. Python virtual environments ────────────────────────────────────────────
step "Creating Python venvs"
python3 -m venv "$VENV_DATA"
"$VENV_DATA/bin/pip" install -q --upgrade pip
"$VENV_DATA/bin/pip" install -q \
    -r "$PROJECT_DIR/data_pipeline/requirements.txt" \
    dbt-postgres

python3 -m venv "$VENV_SUMMARY"
"$VENV_SUMMARY/bin/pip" install -q --upgrade pip
"$VENV_SUMMARY/bin/pip" install -q -r "$PROJECT_DIR/summary_bot/requirements.txt"
log "Venvs ready."

# ── 6. Systemd service for subscriber ─────────────────────────────────────────
step "Installing systemd service"
sudo tee /etc/systemd/system/sleep-subscriber.service > /dev/null <<EOF
[Unit]
Description=Sleep Monitor MQTT Subscriber
After=network-online.target postgresql.service mosquitto.service
Wants=network-online.target

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR/data_pipeline/subscriber
EnvironmentFile=$PROJECT_DIR/data_pipeline/subscriber/.env
ExecStart=$VENV_DATA/bin/python subscriber.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable sleep-subscriber
log "Service installed (not started yet — create .env first)."

# ── 7. OS firewall ────────────────────────────────────────────────────────────
step "Opening port 1883 in iptables"
# Oracle Cloud Ubuntu blocks ports at OS level by default
sudo iptables -C INPUT -p tcp --dport 1883 -j ACCEPT 2>/dev/null \
    || sudo iptables -I INPUT -p tcp --dport 1883 -j ACCEPT
sudo netfilter-persistent save
log "Port 1883 open."

# ── 8. dbt profiles.yml ───────────────────────────────────────────────────────
step "Generating dbt profiles.yml"
DSN="postgresql://$DB_USER:$DB_PASS@localhost:5432/$DB_NAME"
cat > "$PROJECT_DIR/data_pipeline/dbt/profiles.yml" <<EOF
sleep_monitor:
  target: prod
  outputs:
    prod:
      type: postgres
      host: localhost
      port: 5432
      dbname: $DB_NAME
      user: $DB_USER
      password: $DB_PASS
      schema: public
      threads: 1
EOF
log "dbt profiles.yml written."

# ── Done ──────────────────────────────────────────────────────────────────────
cat <<EOF

$(echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━")
  Setup complete. Do these manually:
$(echo -e "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${RESET}")

1. Oracle Cloud Console → Networking → VCN → Security Lists
   Add ingress rule: TCP port 1883  (MQTT — for ESP32)
   (OS firewall is already open; the VCN rule is a separate layer)

2. Create subscriber .env:
   cp $PROJECT_DIR/data_pipeline/subscriber/.env.example \\
      $PROJECT_DIR/data_pipeline/subscriber/.env
   # Set: MQTT_BROKER=localhost
   # Set: DB_DSN=$DSN

3. Create summary_bot .env:
   cp $PROJECT_DIR/summary_bot/.env.example \\
      $PROJECT_DIR/summary_bot/.env
   # Fill in ANTHROPIC_API_KEY, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
   # Set: DB_DSN=$DSN

4. Start the subscriber:
   sudo systemctl start sleep-subscriber
   sudo journalctl -u sleep-subscriber -f

5. Run dbt:
   cd $PROJECT_DIR/data_pipeline/dbt
   $VENV_DATA/bin/dbt run
   $VENV_DATA/bin/dbt test

EOF
