#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/wg-backup"
SERVICE_FILE="/etc/systemd/system/wg-backup.service"
TIMER_FILE="/etc/systemd/system/wg-backup.timer"
LOG_FILE="/var/log/wg_backup_installer.log"
BACKUP_SCRIPT="$INSTALL_DIR/wg_backup.py"

echo "======================================"
echo " WireGuard Telegram Backup Installer"
echo "======================================"
echo

# -----------------------
# Check root
# -----------------------
if [[ $EUID -ne 0 ]]; then
    echo "[!] Please run as root"
    exit 1
fi

# -----------------------
# Check command argument
# -----------------------
if [[ $# -lt 1 ]]; then
    echo "Usage: $0 {install|backup}"
    exit 1
fi

ACTION="$1"

# -----------------------
# Backup function
# -----------------------
run_backup() {
    if [[ ! -f "$BACKUP_SCRIPT" ]]; then
        echo "[!] Backup script not found: $BACKUP_SCRIPT"
        exit 1
    fi
    echo "[+] Running backup..."
    /usr/bin/python3 "$BACKUP_SCRIPT"
    echo "[+] Backup completed!"
}

# -----------------------
# Install function
# -----------------------
install_backup() {
    # -----------------------
    # User Input
    # -----------------------
    read -p "Enter Telegram Bot Token: " BOT_TOKEN
    read -p "Enter Telegram Chat ID(s) (comma separated): " CHAT_ID
    read -s -p "Enter Backup Encryption Password: " BACKUP_PASSWORD
    echo
    echo

    # -----------------------
    # Install Dependencies
    # -----------------------
    echo "[+] Installing dependencies..."
    apt update -y
    apt install -y python3 python3-pip openssl

    if ! python3 -c "import telegram" &>/dev/null; then
        pip3 install python-telegram-bot==13.15
    fi

    # -----------------------
    # Create directories
    # -----------------------
    echo "[+] Creating directories..."
    mkdir -p "$INSTALL_DIR"

    # -----------------------
    # Write config
    # -----------------------
    echo "[+] Writing configuration..."
    cat > "$INSTALL_DIR/config.env" <<CFG
BOT_TOKEN=$BOT_TOKEN
CHAT_ID=$CHAT_ID
BACKUP_PASSWORD=$BACKUP_PASSWORD
CFG

    chmod 600 "$INSTALL_DIR/config.env"

    # -----------------------
    # Create backup script
    # -----------------------
    echo "[+] Creating backup script..."
    cat > "$BACKUP_SCRIPT" <<'PY'
#!/usr/bin/env python3
import os, tarfile, time, subprocess, logging
from telegram import Bot

CONFIG_FILE="/opt/wg-backup/config.env"
TMP_DIR="/tmp"
LOG_FILE="/var/log/wg_backup.log"

FILES_TO_BACKUP=[
    "/etc/wireguard",
    "/opt/iPWGD",
    "/var/www/html"
]

def load_config():
    cfg={}
    with open(CONFIG_FILE) as f:
        for l in f:
            if "=" in l:
                k,v=l.strip().split("=",1)
                cfg[k]=v
    return cfg

cfg=load_config()
bot=Bot(token=cfg["BOT_TOKEN"])

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

try:
    ts=time.strftime("%Y%m%d_%H%M%S")
    tar_path=f"{TMP_DIR}/wg_backup_{ts}.tar"
    enc_path=f"{tar_path}.enc"

    logging.info("Backup started")

    with tarfile.open(tar_path,"w") as tar:
        for p in FILES_TO_BACKUP:
            if os.path.exists(p):
                tar.add(p,arcname=p.lstrip("/"))

    subprocess.check_call([
        "openssl","enc","-aes-256-cbc","-salt",
        "-in",tar_path,
        "-out",enc_path,
        "-pass",f"pass:{cfg['BACKUP_PASSWORD']}"
    ])

    os.remove(tar_path)

    for cid in cfg["CHAT_ID"].split(","):
        with open(enc_path,"rb") as f:
            bot.send_document(
                chat_id=cid,
                document=f,
                caption="🔐 WireGuard Encrypted Backup"
            )

    os.remove(enc_path)
    logging.info("Backup completed successfully")
except Exception as e:
    logging.exception("Backup failed")
    raise
PY

    chmod +x "$BACKUP_SCRIPT"

    # -----------------------
    # Create systemd service
    # -----------------------
    echo "[+] Creating systemd service..."
    cat > "$SERVICE_FILE" <<SRV
[Unit]
Description=WireGuard Telegram Backup
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/wg-backup/wg_backup.py
SRV

    # -----------------------
    # Create systemd timer
    # -----------------------
    echo "[+] Creating systemd timer (every 12 hours)..."
    cat > "$TIMER_FILE" <<TMR
[Unit]
Description=Run WireGuard Backup every 12 hours

[Timer]
OnBootSec=5min
OnUnitActiveSec=12h
Persistent=true

[Install]
WantedBy=timers.target
TMR

    # -----------------------
    # Enable timer
    # -----------------------
    echo "[+] Enabling backup timer..."
    systemctl daemon-reexec
    systemctl daemon-reload
    systemctl enable wg-backup.timer
    systemctl start wg-backup.timer

    echo
    echo "======================================"
    echo " Installation completed successfully!"
    echo " Backups will be sent every 12 hours"
    echo "======================================"
}

# -----------------------
# Main
# -----------------------
case "$ACTION" in
    install)
        install_backup
        ;;
    backup)
        run_backup
        ;;
    *)
        echo "Invalid option: $ACTION"
        echo "Usage: $0 {install|backup}"
        exit 1
        ;;
esac
