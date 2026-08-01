# Backhaul Homa Ghost Tunnel Manager

منوی انگلیسی و امن برای نصب و مدیریت چند تونل مستقل
[Backhaul](https://github.com/Musixal/Backhaul) روی Ubuntu و Debian.

این پروژه برای معماری «ایران به‌عنوان ورودی و سرورهای خارج به‌عنوان خروجی» طراحی
شده است. نسخه `1.1.11` علاوه بر نصب تونل جدید، سرویس‌های Backhaul از قبل نصب‌شده
را نیز بدون تغییر کانفیگ شناسایی و مدیریت می‌کند.

## منوی انگلیسی سازگار با ترمینال موبایل

پس از نصب فقط اجرا کنید:

```bash
sudo bh
```

منو در بافر عادی ترمینال اجرا می‌شود. پیش از رسم منو، صفحه فعلی با Line Feed
به Scrollback منتقل می‌شود؛ در نتیجه هنگام بازبودن `bh` نیز می‌توان در Termius
با کشیدن صفحه، دستورها و خروجی‌های قبل از اجرای آن را دید. صفحه‌های موقت مانند
وضعیت تونل و فهرست بکاپ پس از فشردن Enter درجا پاک می‌شوند و دیگر به تاریخچه
منو منتقل نمی‌شوند. جابه‌جایی بین صفحات و Exit هرگز از دستور پاک‌کردن کامل
Scrollback استفاده نمی‌کند.

گزینه‌ها با کلیدهای `Up` و `Down` جابه‌جا و با `Enter` انتخاب می‌شوند. برای
سازگاری با روش قبلی، نوشتن شماره گزینه و سپس `Enter` نیز پشتیبانی می‌شود.

منوی اصلی:

```text
1) Create a new tunnel (IPv4 / IPv6)
2) Manage tunnels
3) Show all tunnel statuses
4) Health check and auto-repair
5) Manage health-check cron
6) Backups and restore
7) Network diagnostics
8) Install or update the Backhaul core
9) Update Manager from GitHub
0) Exit
```

داخل منوی هر تونل می‌توان وضعیت، لاگ، Restart، اجرای خودکار پس از ریبوت، نگاشت
پورت‌ها و کانفیگ با توکن مخفی را مدیریت کرد. حذف تونل مستقیم نیست؛ ابتدا بکاپ
گرفته می‌شود و فایل‌ها به آرشیو قابل‌بازیابی منتقل می‌شوند.

## امکانات

- شناسایی سرویس‌های جدید و قدیمی مانند `backhaul-uk-client.service`،
  `backhaul-france.service` و `backhaul-ir2.service`
- ساخت چند تونل مستقل Server و Client
- پشتیبانی از IPv4 و IPv6
- پشتیبانی از `tcp`، `tcpmux`، `ws`، `wss`، `wsmux` و `wssmux`
- ساخت توکن تصادفی و عدم نمایش آن در منو
- افزودن و حذف نگاشت پورت با بکاپ، Restart و Rollback خودکار
- پشتیبانی از Mapping کانفیگ‌های جدید چندخطی و کانفیگ‌های قدیمی تک‌خطی
- Health Check دستی یا زمان‌بندی‌شده
- Cron شرطی؛ سرویس سالم را Restart نمی‌کند
- قفل `flock` برای جلوگیری از اجرای هم‌زمان Health Check
- بکاپ نسخه‌دار از کانفیگ‌ها، فایل‌های systemd، مسیر اصلی کانفیگ و Cron
- Restore تراکنشی بکاپ همراه با Safety Backup و Rollback در صورت شکست
- نصب اتمیک Manager و حفظ خودکار باینری موجود
- استقرار تراکنشی تونل با Rollback کانفیگ، Unit و وضعیت سرویس در صورت شکست
- دریافت آخرین Release رسمی Backhaul و بررسی SHA-256 منتشرشده در GitHub
- بررسی پایداری سرویس پس از Update و بازگردانی باینری قبلی در صورت Crash
- حذف امن Manager بدون قطع تونل‌ها
- تست خودکار منوها در PTY واقعی؛ CI نیز Bash Syntax و ShellCheck را اجرا می‌کند

## نصب روی سروری که Backhaul فعال دارد

این فرمان فقط Manager را نصب می‌کند، باینری و کانفیگ‌های فعلی را حفظ می‌کند و
Health Check را هر ۵ دقیقه فعال می‌کند:

```bash
bash <(curl -fsSL --ipv4 \
  https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main/install.sh) \
  --skip-binary --enable-health-cron 5
```

نصاب در این حالت هیچ سرویس Backhaul را Restart یا بازنویسی نمی‌کند.

## نصب تازه

```bash
bash <(curl -fsSL --ipv4 \
  https://raw.githubusercontent.com/radar-kx/Backhaul-homa-ghost-tunnel-manager/main/install.sh) \
  --enable-health-cron 5
```

اگر Backhaul از قبل وجود داشته باشد، نصاب آن را خودکار حفظ می‌کند. برای اجبار
به نصب مجدد هسته باید `--force-binary` را صریح وارد کرد.

## Cron هوشمند

Cron پیشنهادی:

```bash
sudo backhaul-manager cron install --interval 5
```

رفتار هر اجرا:

1. تمام سرویس‌های `backhaul-*.service` را پیدا می‌کند.
2. سرویس سالم و `active` را بدون تغییر رها می‌کند.
3. سرویس غیرفعال را فقط همان لحظه Restart می‌کند.
4. سرویس عمداً `disabled` شده را دست نمی‌زند تا حالت تعمیر یا توقف دستی لغو نشود.
5. با `flock` از اجرای هم‌زمان چند Health Check جلوگیری می‌کند.

در نتیجه Cron این پروژه با Cron قدیمیِ «ری‌استارت اجباری دوره‌ای» فرق دارد و
باعث قطعی برنامه‌ریزی‌شده تونل سالم نمی‌شود.

برای فعال‌کردن صریح تمام سرویس‌های `disabled` در یک بررسی دستی:

```bash
sudo bh health --repair --enable-disabled
```


## بروزرسانی امن هسته Backhaul

برای دریافت آخرین Release رسمی و بررسی SHA-256 منتشرشده برای Asset:

```bash
sudo bh binary install --latest
```

Manager پس از جایگزینی باینری، سرویس‌هایی را که قبلاً فعال بوده‌اند چند مرحله
بررسی می‌کند. اگر Restart ظاهراً موفق باشد ولی سرویس بلافاصله Crash کند، باینری
قبلی و وضعیت سرویس‌ها خودکار بازگردانده می‌شود.

اگر GitHub برای یک Asset قدیمی Digest منتشر نکرده باشد، دانلود آنلاین به‌صورت
پیش‌فرض متوقف می‌شود. عبور از این کنترل فقط با گزینه صریح زیر ممکن است و توصیه
نمی‌شود مگر اینکه فایل را از مسیر دیگری اعتبارسنجی کرده باشید:

```bash
sudo bh binary install --latest --allow-unverified-download
```

## بازیابی بکاپ

گزینه Restore فقط آرشیوهای داخل `/var/backups/backhaul-manager` را می‌پذیرد.
قبل از هر تغییر یک Safety Backup جدید می‌سازد، محتوای آرشیو را از نظر Traversal،
Symlink، فایل تکراری، Metadata ناشناخته، فایل بدون مرجع، مسیر غیرمجاز و سقف حجم
استخراج بررسی می‌کند و سپس فایل‌ها و وضعیت سرویس‌ها را تراکنشی بازمی‌گرداند.

```bash
sudo bh backup list
sudo bh backup restore /var/backups/backhaul-manager/BACKUP.tar.gz --yes
```

## معماری نمونه

برای هر خروجی یک پورت کنترل و یک بازه پورت عمومی مستقل در نظر بگیرید. در
مثال‌های این مخزن، `203.0.113.10` یک IP رزروشده مستنداتی است و باید با IP
واقعی سرور ورودی خودتان جایگزین شود. IPها، توکن‌ها و نقشه پورت‌های عملیاتی
زیرساخت واقعی نباید داخل مخزن عمومی قرار بگیرند.

## دستورات خط فرمان

```bash
# بازکردن منوی انگلیسی
sudo bh

# فهرست تمام سرویس‌ها
sudo bh list

# بررسی و ترمیم
sudo bh health --repair

# وضعیت Cron
sudo bh cron status

# بکاپ و بازیابی
sudo bh backup create
sudo bh backup list
sudo bh backup restore /var/backups/backhaul-manager/backhaul-backup-....tar.gz --yes

# نصب آخرین نسخه رسمی هسته همراه با بررسی Digest
sudo bh binary install --latest

# نگاشت‌های یک Server
sudo bh mapping list backhaul-tr-server.service
sudo bh mapping add backhaul-tr-server.service 8303=127.0.0.1:8093
sudo bh mapping remove backhaul-tr-server.service 8303

# لاگ و Restart
sudo bh logs backhaul-tr-client.service
sudo bh restart backhaul-tr-client.service

# عیب‌یابی کامل
sudo bh doctor
```

## ساخت Server

```bash
sudo bh server add \
  --name tr \
  --bind 0.0.0.0:9300 \
  --public-host 203.0.113.10 \
  --transport wsmux \
  --map 8300=127.0.0.1:8090 \
  --map 8301=127.0.0.1:8091 \
  --map 8302=127.0.0.1:8092 \
  --open-firewall
```

پس از اجرا، فرمان Client حاوی توکن همان تونل تولید می‌شود. این فرمان را عمومی
منتشر نکنید.

## ساخت Client

```bash
sudo bh client add \
  --name tr \
  --remote 203.0.113.10:9300 \
  --transport wsmux \
  --token 'TOKEN_GENERATED_ON_SERVER'
```

برای IPv6 آدرس را داخل براکت قرار دهید:

```text
[2001:db8::10]:9300
```

## فایل‌ها

| مسیر | کاربرد |
|---|---|
| `/usr/local/bin/backhaul` | هسته Backhaul |
| `/usr/local/bin/bh` | فرمان کوتاه منو و CLI |
| `/usr/local/sbin/backhaul-manager` | ابزار خط فرمان |
| `/usr/local/sbin/backhaul-menu` | منوی انگلیسی |
| `/opt/backhaul-tunnel-manager` | فایل‌های Manager |
| `/etc/backhaul` | کانفیگ‌های دارای توکن با سطح دسترسی محدود |
| `/etc/systemd/system/backhaul-*.service` | سرویس‌های تونل |
| `/etc/cron.d/backhaul-manager-health` | Health Check زمان‌بندی‌شده |
| `/var/backups/backhaul-manager` | بکاپ و آرشیو تونل‌ها |

## تفاوت با منوی Rathole v2

جریان منو و تجربه کاربری این پروژه با الهام از
[Musixal/Rathole-Tunnel](https://github.com/Musixal/Rathole-Tunnel) طراحی شده،
اما پیاده‌سازی این مخزن مستقل و مخصوص Backhaul است. رفتارهای پرریسک مانند توکن
پیش‌فرض، `kill -9` تمام پردازش‌ها، تغییر اجباری `/etc/hosts`، دستکاری گسترده
`sysctl.conf` و حذف بدون بکاپ استفاده نشده‌اند.

## حذف

پیش‌فرض فقط Manager و Cron آن را حذف می‌کند؛ تونل‌ها، کانفیگ‌ها و هسته فعال
می‌مانند:

```bash
sudo ./uninstall.sh
```

حذف کامل فقط با گزینه صریح و تایپ عبارت تأیید انجام می‌شود و قبل از حذف بکاپ
می‌گیرد:

```bash
sudo ./uninstall.sh --purge-all
```


## راهنماها

- راهنمای فارسی استقرار: [`docs/DEPLOYMENT_FA.md`](docs/DEPLOYMENT_FA.md)
- راهنمای فارسی عیب‌یابی: [`docs/TROUBLESHOOTING_FA.md`](docs/TROUBLESHOOTING_FA.md)
- English deployment guide: [`docs/DEPLOYMENT_EN.md`](docs/DEPLOYMENT_EN.md)
- English troubleshooting guide: [`docs/TROUBLESHOOTING_EN.md`](docs/TROUBLESHOOTING_EN.md)
- English project overview: [`README_EN.md`](README_EN.md)

## مجوز

کد مستقل این Manager تحت مجوز MIT منتشر می‌شود. پروژه Backhaul و پروژه
Rathole-Tunnel نرم‌افزارهای جداگانه با مجوزهای خودشان هستند؛ هیچ باینری یا کد
آن‌ها داخل این مخزن بازنشر نمی‌شود.
