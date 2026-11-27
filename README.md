# sub2api-setup

این اسکریپت [sub2api](https://github.com/Wei-Shaw/sub2api) رو یه‌جا روی اوبونتو نصب می‌کنه. اگه بخوای، پشت CDN آروان و VPN هم می‌برتش.

## چیکار می‌کنه

- اول سیستم رو چک می‌کنه: root بودن، نسخه اوبونتو، رم، دیسک و اینترنت.
- پیش‌نیازها و Docker رو نصب یا آپدیت می‌کنه.
- sub2api رو با Docker بالا میاره. اپ فقط روی `127.0.0.1:8080` گوش میده.
- nginx رو روی پورت 80 جلوش می‌ذاره که با استریم هم مشکلی نداشته باشه.
- **اختیاری:** پورت 80 و 443 فقط برای IPهای آروان (و IPهایی که خودت میدی، مثل سرور ریلی) باز می‌مونه.
- **اختیاری:** همه ترافیک خروجی سرور و داکر از VPN رد میشه. اگه VPN قطع شد یا نشتی داشت، کیل‌سوییچ نت رو کامل می‌بنده.
  - SSH و پنل همچنان کار می‌کنن.
  - ورودی VPN هم لینک ساب قبول می‌کنه، هم یه لینک تکی (`vless://`، `vmess://` یا `trojan://`).
  - ساب هر ۳۰ دقیقه خودش آپدیت میشه.
- آخرش اطلاعات لاگین ادمین رو نشون میده.

## نصب

```bash
git clone https://github.com/Doonkoob/sub2api-setup.git
```

```bash
cd sub2api-setup
```

```bash
sudo bash setup.sh
```

اسکریپت ازت می‌پرسه: دامنه‌ها، ایمیل و رمز ادمین، قفل آروان، IPهای مجاز، و اینکه VPN بخوای یا نه.

اگه نمی‌خوای سوال بپرسه، همه رو با متغیر بده:

```bash
sudo ASSUME_YES=1 DOMAINS="ai.example.com" ORIGIN_LOCK=yes ORIGIN_ALLOW="203.0.113.10" VPN=yes VPN_SOURCE="https://host:2096/sub/xxxx" bash setup.sh
```

جواب‌ها توی `/etc/sub2api-setup.conf` ذخیره میشن. هر وقت دوباره اجراش کنی، همه‌چیز آپدیت میشه و دیتا و رمزها سر جاشون می‌مونن.

## رکورد CDN

دامنه رو با این تنظیمات بزن روی IP سرور (یا سرور ریلی):

- Cloud روشن
- پروتکل اتصال به مبدأ: HTTP
- پورت: 80

## دستورای به‌دردبخور

وضعیت VPN:

```bash
vpnctl.sh status
```

گرفتن دوباره ساب:

```bash
vpnctl.sh update force
```

برداشتن کیل‌سوییچ (نت بدون VPN باز میشه):

```bash
vpnctl.sh rollback
```

آپدیت لیست IPهای آروان:

```bash
originlock.sh refresh
```

برداشتن قفل آروان:

```bash
originlock.sh off
```

لاگ sub2api:

```bash
docker compose -f /opt/sub2api-deploy/docker-compose.yml logs -f sub2api
```
