cat > wg_backup.py <<'EOF'
#!/usr/bin/env python3
import os, tarfile, time, sys, subprocess, logging

CONFIG_FILE = "/opt/wg-backup/config.env"
TMP_DIR = "/tmp"
LOG_FILE = "/var/log/wg_backup.log"

FILES_TO_BACKUP = [
    "/etc/wireguard",
    "/opt/iPWGD",
    "/var/www/html"
]

def ensure(pkg):
    try:
        __import__(pkg)
    except ImportError:
        subprocess.check_call([sys.executable, "-m", "pip", "install", pkg])

ensure("telegram")
from telegram import Bot

def load_config():
    cfg = {}
    with open(CONFIG_FILE) as f:
        for l in f:
            if "=" in l:
                k, v = l.strip().split("=", 1)
                cfg[k] = v
    return cfg

cfg = load_config()
BOT_TOKEN = cfg["BOT_TOKEN"]
CHAT_IDS = cfg["CHAT_ID"].split(",")
BACKUP_PASSWORD = cfg["BACKUP_PASSWORD"]

logging.basicConfig(
    filename=LOG_FILE,
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s"
)

def create_backup():
    ts = time.strftime("%Y%m%d_%H%M%S")
    tar_path = f"{TMP_DIR}/wg_backup_{ts}.tar"
    enc_path = f"{tar_path}.enc"

    with tarfile.open(tar_path, "w") as tar:
        for p in FILES_TO_BACKUP:
            if os.path.exists(p):
                tar.add(p, arcname=p.lstrip("/"))

    subprocess.check_call([
        "openssl", "enc", "-aes-256-cbc", "-salt",
        "-in", tar_path,
        "-out", enc_path,
        "-pass", f"pass:{BACKUP_PASSWORD}"
    ])

    os.remove(tar_path)
    return enc_path

def send_backup(enc):
    bot = Bot(token=BOT_TOKEN)
    for cid in CHAT_IDS:
        with open(enc, "rb") as f:
            bot.send_document(
                chat_id=cid,
                document=f,
                caption="🔐 WireGuard / iPWGD Encrypted Backup"
            )
    os.remove(enc)

if __name__ == "__main__":
    b = create_backup()
    send_backup(b)
EOF
