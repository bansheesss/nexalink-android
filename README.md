# ViunaLink برای اندروید (Viewer)

اپ اندروید برای کنترل کامپیوتری که **ViunaLink ویندوز** روی آن Host است.
پروتکل و رمزنگاری با پیاده‌سازی مرجع ViunaLink ویندوز هماهنگ است (X25519 + scrypt(پسورد) + HKDF + AES‑256‑GCM).

## امکانات
- نمایش زنده‌ی صفحه (JPEG/WebP)، نمایش fps و ping
- لمس: تپ = کلیک چپ، نگه‌داشتن = کلیک راست، کشیدن = درگ، دو انگشت = اسکرول
- صفحه‌کلید (تایپ مستقیم) + کلیدهای ویژه (Esc, Tab, Enter, جهت‌ها, F1–F12) + Ctrl/Alt/Shift/Win
- کلیپ‌بورد متنی دوطرفه
- ارسال و دریافت فایل (طرف مقابل باید بپذیرد، با SHA‑256 بررسی می‌شود)
- اتصال با IP یا شناسه‌ی ۹ رقمی در LAN و از طریق Relay قابل تنظیم؛ «جستجو در شبکه»
- انتخاب مانیتور، کیفیت، fps و مقیاس تصویر؛ پیشنهاد اتصال مجدد

محدودیت‌ها: فقط Viewer است (گوشی نمی‌تواند Host باشد)، شناسه در LAN ابتدا مستقیم بررسی می‌شود؛ در صورت نبود میزبان محلی، اتصال از طریق Relay قابل تنظیم است،
فایل‌های دریافتی در پوشه‌ی اختصاصی برنامه ذخیره می‌شوند
(`Android/data/com.viunalink.viunalink/files/ViunaLink`)، چیدمان کیبورد ترجمه نمی‌شود.

## ساخت APK با GitHub Actions
```bash
cd Android
git init && git add . && git commit -m "ViunaLink Android"
git branch -M main
git remote add origin https://github.com/<you>/viunalink-android.git
git push -u origin main
```
با push، workflow «Build APK» در تب Actions اجرا می‌شود (یا Run workflow). خروجی در Artifacts با نام
`viunalink-apk`: فایل‌های `viunalink-1.2.0-arm64-v8a-release.apk` (اکثر گوشی‌ها)،
`...-armeabi-v7a-...` (۳۲ بیتی قدیمی) و `...-x86_64-...` (شبیه‌ساز).
APK با کلید debug امضا می‌شود؛ برای Play Store باید keystore بسازید.

Workflow دو job دارد:
1. **golden-drift**: ریپوی ViunaLink ویندوز (`bansheesss/nexalink-windows`) را checkout می‌کند، `tool/gen_golden.py` را اجرا می‌کند و با
   `test/vectors/golden.json` مقایسه می‌کند. اگر پروتکل نسخه مرجع ویندوز تغییر کند و تست‌های اندروید به‌روز نشوند، قرمز می‌شود.
2. **build**: Flutter 3.24.5 و Java 17، ساخت پوشه‌ی `android/` در صورت نبودن، `flutter analyze`،
   **`flutter test`** (تست سازگاری با نسخه مرجع ویندوز) و فقط در صورت سبز بودن تست‌ها `flutter build apk`.

## تست سازگاری (golden vectors)
`tool/gen_golden.py` با ثابت‌کردن کلیدها و salt، ماژول‌های واقعی Python در مخزن ویندوز را اجرا می‌کند و این‌ها را ذخیره می‌کند:
خروجی scrypt/X25519/HKDF، بایت‌به‌بایت هندشیک موفق و ناموفق، فریم‌های رمزشده‌ی دو جهت،
بسته‌بندی ماوس/کیبورد/فریم/JSON، توالی پیام‌های انتقال فایل، `safe_name` و بسته‌های discovery.
تست‌های Dart همان بایت‌ها را بازتولید می‌کنند و رفتارهای امنیتی (رمز اشتباه، میزبان جعلی، دست‌کاری و replay
فریم، طول نامعتبر، نوع پیام ناشناخته) را بررسی می‌کنند.

بازتولید vectorها: `python tool/gen_golden.py --repo ../nexalink-windows --out test/vectors/golden.json`
(نیاز: `pip install cryptography`).

## اجرای محلی
```bash
flutter create --platforms=android --org com.viunalink --project-name viunalink .   # فقط بار اول
git checkout lib pubspec.yaml; rm -f test/widget_test.dart; python tool/patch_android.py
flutter pub get && flutter test && flutter run
```

## راه‌اندازی اتصال اینترنتی با Relay

برای Relay باید یک VPS عمومی داشته باشید؛ خود اپ اندروید سرور Relay اجرا نمی‌کند و فقط Viewer است. راهنمای کامل نصب سرور روی Ubuntu، تنظیم DNS و TLS، ساخت توکن، اجرای خودکار با systemd، تنظیم میزبان Windows و عیب‌یابی در [راهنمای رسمی Relay در مخزن Windows](https://github.com/bansheesss/nexalink-windows/blob/main/docs/RELAY_SETUP.md) آمده است.

خلاصه تنظیم Android:
1. در فیلد «آدرس IP یا شناسه‌ی ۹ رقمی»، شناسه‌ی ۹ رقمی میزبان Windows را وارد کنید؛ برای اتصال Relay از IP استفاده نکنید.
2. رمز دائمی یا رمز یکبارمصرف میزبان را وارد کنید.
3. بخش «تنظیم اتصال اینترنتی (Relay)» را باز کنید.
4. آدرس سرور را فقط به‌صورت hostname مثل `relay.example.com` وارد کنید (بدون `https://`)، پورت `7072`، توکن مشترک VPS و گزینه‌ی TLS را روشن کنید.
5. اتصال را بزنید. برنامه ابتدا LAN را برای همان شناسه بررسی می‌کند و اگر میزبان پیدا نشود از Relay استفاده می‌کند.

همین hostname، پورت، توکن و TLS باید در تنظیمات «شبکه و اینترنت» میزبان Windows هم ثبت شده باشد و وضعیت Relay میزبان آنلاین باشد. تنظیمات Relay در Android در حال حاضر برای همان اجرای اپ/فرم اتصال وارد می‌شوند و در این نسخه به‌عنوان پروفایل دائمی ذخیره نمی‌شوند.

## وضعیت شبکه و مجوزها

در شروع برنامه، اتصال TCP به `google.com:443` بررسی می‌شود و هم‌زمان کشف میزبان ViunaLink در شبکه محلی انجام می‌گیرد. نشانگر نارنجی یعنی میزبان محلی پیدا شده، سبز یعنی اینترنت برقرار است و میزبان محلی پیدا نشده، و قرمز یعنی هیچ‌کدام در دسترس نیستند. این بررسی ICMP ping نیست؛ اتصال TCP است تا روی شبکه‌هایی که ICMP را مسدود می‌کنند نتیجه اشتباه ندهد.

مجوزهای شبکه اندروید از نوع عادی (normal) هستند و پنجره تأیید runtime نمایش نمی‌دهند؛ با این حال برنامه برای ارتباط شبکه‌ای نمی‌تواند کاملاً بدون مجوز سیستمی باشد.
