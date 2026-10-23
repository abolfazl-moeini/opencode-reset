# OpenCode Reset & Token Sync Manager

A robust, lightweight CLI tool to seamlessly change API tokens, sync SQLite credentials, and restart the OpenCode background daemon on macOS.

---

## ⚡ TL;DR (English)

### Why changing tokens fails in OpenCode:
1. **SQLite Database (v2.x)**: OpenCode stores active credentials in `~/.local/share/opencode/opencode.db` (`credential` table). Editing `auth.json` or `.env` alone is ignored because OpenCode no longer polls them once migrated.
2. **Persistent Daemon (`opencode serve --service`)**: A long-running background service locks `opencode.db` and caches credentials in RAM. Changes won't take effect until the service is cleanly terminated and restarted.

### Quick Start:
```bash
# Set new OpenCode token directly and reset everything
opencode-reset oc_sk_your_new_token_here

# Interactive mode (inspect active token, paste new one or press Enter to reset)
opencode-reset

# Sync edits made in auth.json / .env to SQLite and restart
opencode-reset --restart

# Check service and database credential status
opencode-reset --status

# Update another provider (e.g. OpenRouter, BAI)
opencode-reset "sk-or-v1-..." openrouter
```

### What it does:
- Terminates running `opencode serve --service` processes cleanly (releasing DB locks).
- Atomically updates `opencode.db` (`credential` table) with proper `{"type": "key", "key": "..."}` format.
- Checkpoints SQLite WAL (`PRAGMA wal_checkpoint(TRUNCATE)`).
- Syncs `~/.local/share/opencode/auth.json` and `~/.config/opencode/.env`.
- Cleans stale quarantine/failover caches and orphaned plugins.
- Starts the background service and verifies status via `opencode auth export`.

---

## 🇮🇷 راهنمای فارسی

### 🔍 ریشه مشکل چه بود؟
1. **دیتابیس SQLite در اوپن‌کد ۲**: اوپن‌کد توکن‌های فعال را در جدول `credential` دیتابیس `opencode.db` نگه می‌دارد. تغییر دستی `auth.json` یا `.env` دیگر به تنهایی خوانده نمی‌شود.
2. **سرویس پس‌زمینه (`opencode serve --service`)**: سرویس پس‌زمینه فعال، دیتابیس را قفل نگه داشته و توکن قبلی را در رم کش می‌کند؛ تا سرویس کامپلیت ریست نشود، توکن جدید اعمال نخواهد شد.

---

### 🚀 دستورات کاربردی

#### ۱. تغییر مستقیم توکن:
```bash
opencode-reset oc_sk_your_new_token_here
```

#### ۲. حالت تعاملی (Interactive):
```bash
opencode-reset
```
توکن فعلی را نمایش می‌دهد؛ در صورت وارد کردن توکن جدید جایگزین می‌شود و در صورت زدن **Enter**، توکن فعلی حفظ شده و سرویس ریست و همگام می‌گردد.

#### ۳. بعد از ادیت دستی `auth.json` یا `.env`:
```bash
opencode-reset --restart
```
تغییرات فایل‌های کانفیگ را با دیتابیس سینک کرده و سرویس را ری‌استارت می‌کند.

#### ۴. بررسی وضعیت توکن‌ها و سرویس:
```bash
opencode-reset --status
```

---

### 📦 نصب سراسری
اسکریپت به صورت خودکار به `~/.local/bin/opencode-reset` لینک شده است. در صورت نیاز به لینک مجدد:
```bash
./opencode-reset.sh --install
```
