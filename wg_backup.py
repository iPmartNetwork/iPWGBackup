#!/usr/bin/env python3
import os
import tarfile
import time
import logging
from telegram import Bot, Update
from telegram.ext import Updater, CommandHandler, CallbackContext
import threading

# -----------------------
# Paths and configuration
# -----------------------
CONFIG_FILE = "/opt/wg-backup/config.env"
TMP_DIR = "/tmp"
LOG_FILE = "/var/log/wg_backup.log"

# Directories/files to backup
FILES_TO_BACKUP = [
    "/etc/wireguard",
    "/opt/iPWGD",
    "/var/www/html"
]

# -----------------------
# Load configuration
# -----------------------
def load_config():
    cfg = {}
    with open(CONFIG_FILE) as f:
        for line in f:
            if "=" in line:
                key, val = line.strip().split("=", 1)
                cfg[key] = val
    return cfg

cfg = load_config()
bot = Bot(token=cfg["BOT_TOKEN"])

# -----------------------
# Logging
# -----------------------
logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

# -----------------------
# Backup function
# -----------------------
def run_backup(chat_ids=None):
    try:
        ts = time.strftime("%Y%m%d_%H%M%S")
        tar_path = f"{TMP_DIR}/wg_backup_{ts}.tar"

        logging.info("Backup started")

        with tarfile.open(tar_path, "w") as tar:
            for path in FILES_TO_BACKUP:
                if os.path.exists(path):
                    tar.add(path, arcname=path.lstrip("/"))

        recipients = chat_ids if chat_ids else cfg["CHAT_ID"].split(",")
        for cid in recipients:
            with open(tar_path, "rb") as f:
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

# -----------------------
# Telegram command handler
# -----------------------
def backup_command(update: Update, context: CallbackContext):
    chat_id = str(update.effective_chat.id)
    update.message.reply_text("⏳ Backup is starting...")
    threading.Thread(target=run_backup, args=([chat_id],)).start()
    update.message.reply_text("✅ Backup started. Check chat for the file when done.")

# -----------------------
# Main execution
# -----------------------
if __name__ == "__main__":
    import sys
    if len(sys.argv) > 1 and sys.argv[1] == "manual":
        # Called by systemd timer for automatic backup
        run_backup()
    else:
        # Run Telegram bot for manual backup command
        updater = Updater(token=cfg["BOT_TOKEN"], use_context=True)
        dp = updater.dispatcher
        dp.add_handler(CommandHandler("backup", backup_command))
        logging.info("Telegram bot started, waiting for /backup command...")
        updater.start_polling()
        updater.idle()
