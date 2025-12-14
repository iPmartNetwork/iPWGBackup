#!/bin/bash
set -euo pipefail

INSTALL_DIR="/opt/wg-backup"
SERVICE_FILE="/etc/systemd/system/wg-backup.service"
TIMER_FILE="/etc/systemd/system/wg-backup.timer"
BOT_SCRIPT="$INSTALL_DIR/wg_backup.py"
LOG_FILE="/var/log/wg_backup_installer.log"

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
# Install dependencies
# -----------------------
echo "[+] Installing dependencies..."
apt update -y
apt install -y python3 python3-pip openssl curl

if ! python3 -c "import telegram" &>/dev/null; then
    pip3 install python-telegram-bot==13.15
fi

# -----------------------
# Create directories
# -----------------------
echo "[+] Creating directories..."
mkdir -p "$INSTALL_DIR"

# -----------------------
# User Input
# -----------------------
read -p "Enter Telegram Bot Token: " BOT_TOKEN
read -p "Enter Telegram Chat ID(s) (comma separated): " CHAT_ID
echo

# -----------------------
# Write configuration
# -----------------------
cat > "$INSTALL_DIR/config.env" <<CFG
BOT_TOKEN=$BOT_TOKEN
CHAT_ID=$CHAT_ID
CFG

chmod 600 "$INSTALL_DIR/config.env"

# -----------------------
# Create Python backup script
# -----------------------
cat > "$BOT_SCRIPT" <<'PY'
#!/usr/bin/env python3
import os, tarfile, time, logging
from telegram import Bot, Update
from telegram.ext import Updater, CommandHandler, CallbackContext
import threading

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

def run_backup(chat_ids=None):
    try:
        ts=time.strftime("%Y%m%d_%H%M%S")
        tar_path=f"{TMP_DIR}/wg_backup_{ts}.tar"

        logging.info("Backup started")

        with tarfile.open(tar_path,"w") as tar:
            for p in FILES_TO_BACKUP:
                if os.path.exists(p):
                    tar.add(p,arcname=p.lstrip("/"))

        recipients = chat_ids if chat_ids else cfg["CHAT_ID"].split(",")
        for cid in recipients:
            with open(tar_path,"rb") as f:
                bot.send_document(
                    chat_id=cid,
                    document=f,
                    caption="📦 WireGuard Backup"
                )

        os.remove(tar_path)
        logging.info("Backup completed successfully")
    except Exception as e:
        logging.exception("Backup failed")
        raise

def backup_command(update: Update, context: CallbackContext):
    chat_id = str(update.effective_chat.id)
    update.message.reply_text("⏳ Backup is starting...")
    threading.Thread(target=run_backup, args=([chat_id],)).start()
    update.message.reply_text("✅ Backup started. Check chat for the file when done.")

if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "manual":
        run_backup()
    else:
        updater = Updater(token=cfg["BOT_TOKEN"], use_context=True)
        dp = updater.dispatcher
        dp.add_handler(CommandHandler("backup", backup_command))
        logging.info("Telegram bot started, waiting for /backup command...")
        updater.start_polling()
        updater.idle()
PY

chmod +x "$BOT_SCRIPT"

# -----------------------
# Create systemd service
# -----------------------
cat > "$SERVICE_FILE" <<SRV
[Unit]
Description=WireGuard Telegram Backup (automatic)
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /opt/wg-backup/wg_backup.py manual
SRV

# -----------------------
# Create systemd timer
# -----------------------
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
systemctl daemon-reexec
systemctl daemon-reload
systemctl enable wg-backup.timer
systemctl start wg-backup.timer

echo
echo "======================================"
echo " Installation completed successfully!"
echo " Backups will be sent every 12 hours automatically"
echo " You can also trigger a manual backup via /backup command in your Telegram bot"
echo "======================================"
