# استقرار مرحله‌ای روی سرورهای فعال

این راهنما برای نصب Manager روی تونل‌هایی است که هم‌اکنون `enabled` و `active`
هستند. نصب مرحله‌ای هیچ کانفیگ یا باینری فعالی را جایگزین نمی‌کند.

## ترتیب پیشنهادی

برای کاهش ریسک، ابتدا یک Client کم‌ریسک و در پایان سرورهای مرکزی:

1. روسیه
2. UK
3. ترکیه
4. هلند
5. آلمان
6. ایران ۲
7. فرانسه

## نصب روی هر سرور

```bash
bash <(curl -fsSL --ipv4 \
  https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main/install.sh) \
  --skip-binary --enable-health-cron 5
```

بعد:

```bash
sudo bh list
sudo bh health
sudo bh cron status
```

همه سرویس‌ها باید `enabled` و `active` باشند. سپس منو:

```bash
sudo bh
```

## کنترل بعد از نصب

نصاب نباید PID سرویس Backhaul موجود را عوض کند؛ چون با `--skip-binary` فقط فایل‌های
Manager و Cron نصب می‌شوند. قبل و بعد از نصب می‌توان PIDها را مقایسه کرد:

```bash
pgrep -a backhaul
```

برای Clientها، وجود پیام زیر در لاگ اتصال را تأیید می‌کند:

```text
control channel established successfully
```

## تست ریبوت

پس از تکمیل استقرار، سرورها را یکی‌یکی ریبوت کنید؛ هر بار تا بازگشت کامل همان
سرور و اتصال تونل صبر کنید و سپس سرور بعدی را ریبوت کنید. ایران ۲ و فرانسه را
هم‌زمان ریبوت نکنید.


## بروزرسانی مرحله‌ای هسته

ابتدا روی یک Client کم‌ریسک اجرا کنید:

```bash
sudo bh backup create
sudo bh binary install --latest
sudo bh health
```

Manager Digest رسمی Asset را بررسی می‌کند و فقط سرویس‌هایی را که پیش از Update
فعال بوده‌اند Restart می‌کند. سرویس باید چند بررسی متوالی Active بماند؛ در غیر
این صورت باینری قبلی و وضعیت سرویس‌ها بازگردانده می‌شود.

## بازیابی بکاپ

```bash
sudo bh backup list
sudo bh backup restore /var/backups/backhaul-manager/BACKUP.tar.gz --yes
```

Restore پیش از تغییر فایل‌ها یک Safety Backup می‌سازد. پس از بازیابی، وضعیت و
لاگ همه تونل‌ها را کنترل کنید:

```bash
sudo bh list
sudo bh health
sudo journalctl -u backhaul-NAME-client.service -n 100 --no-pager
```
