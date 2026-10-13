<div align="center">
  <img src="Resources/AppIcon.png" width="128" height="128" alt="RTL Terminal logo">

  # RTL Terminal for macOS

  **A macOS terminal emulator with Persian, Arabic and right-to-left text support**

  **ترمینال مک با پشتیبانی از فارسی، عربی و نمایش راست به چپ**

  **محاكي طرفية لنظام macOS يدعم العربية والفارسية واتجاه الكتابة من اليمين إلى اليسار**

  **Amin Taghikhani**

  [English](#english) · [فارسی](#فارسی) · [العربية](#العربية)

  <br>

  ## Direct Download · دانلود مستقیم · تنزيل مباشر

  **Latest version for macOS 12 or later, Apple Silicon and Intel**

  **آخرین نسخه برای macOS 12 و جدیدتر، Apple Silicon و Intel**

  **أحدث إصدار لنظام macOS 12 أو أحدث، لمعالجات Apple Silicon وIntel**

  ### [⬇️ Download installer (DMG)](https://github.com/taghikhani/RtlTerminal-mac/releases/latest/download/RtlTerminal-macOS.dmg)

  ### [⬇️ دانلود فایل نصب (DMG)](https://github.com/taghikhani/RtlTerminal-mac/releases/latest/download/RtlTerminal-macOS.dmg)

  ### [⬇️ تنزيل ملف التثبيت (DMG)](https://github.com/taghikhani/RtlTerminal-mac/releases/latest/download/RtlTerminal-macOS.dmg)

  [ZIP version · نسخه ZIP · نسخة ZIP](https://github.com/taghikhani/RtlTerminal-mac/releases/latest/download/RtlTerminal-macOS.zip) · [All releases · همه نسخه ها · كل الإصدارات](https://github.com/taghikhani/RtlTerminal-mac/releases)

  After moving the app to Applications, run this once in Terminal:<br>
  <div dir="rtl">
  بعد از کشیدن برنامه به Applications، بار اول این دستور را در ترمینال بزنید:<br>
  بعد نقل التطبيق إلى مجلد Applications، نفّذ هذا الأمر مرة واحدة في الطرفية:
  </div>
  <div>
  xattr -dr com.apple.quarantine /Applications/RtlTerminal.app
  </div>

---

## English

### RTL Terminal for macOS

**RTL Terminal for macOS** is a terminal emulator for Persian, Arabic and other right-to-left language users. It is the macOS version of [RTL Terminal](https://github.com/mirbehnam/RtlTerminal): the Windows version's core logic (VT screen model, Smart RTL algorithm and row layout) was ported to Swift, and the interface was rebuilt with AppKit, CoreText and the native macOS PTY.

### Features

- **Smart RTL** right-aligns lines containing Persian or Arabic while English words, numbers, paths (`/usr/local/bin`) and options (`--version`) keep their own order.
- **Row RTL** forces right-to-left rows, including in full-screen applications (off by default).
- Persian and Arabic letters are always shaped and joined (CoreText), and fitted to their terminal cells.
- Optional **separate font for right-to-left words** (e.g. Vazirmatn) next to the monospaced terminal font.
- ANSI, bright, dim, 256 and RGB colors; bold, italic, underline and strikethrough.
- Interactive CLI/TUI applications (vim, htop, Claude Code, Codex, OpenCode…) with alternate screen, bracketed paste, SGR mouse reporting, focus reporting and synchronized output.
- Box-drawing and block characters drawn geometrically so they join seamlessly.
- Native macOS window tabs (`⌘T`) that open in the current tab's folder.
- `⌘C` / `⌘V`; copied files paste as quoted paths and clipboard images as the path of a PNG file (handy for AI command-line tools).
- Dropping files on the terminal types their paths.
- Link detection; `⌘`-click opens links.
- Ctrl shortcuts work while a Persian or Arabic keyboard layout is active.
- Dark, light or system theme. Light mode adapts the 16 ANSI colors only.
- 2,000 / 5,000 / 10,000-line history; `⌘K` clears it.
- Export the session to a UTF-8 text file (`⌘S`).
- Ten most recent directories in the Shell menu.
- Open a terminal at a folder from Finder › Services, or by dropping the folder on the Dock icon.
- Built-in guide in English, Persian and Arabic.

### Requirements

- macOS 12 Monterey or later (Apple Silicon or Intel)
- To build from source: Xcode or the Command Line Tools with Swift 5.9+ (`xcode-select --install`)

### Build from Source

```bash
git clone https://github.com/taghikhani/RtlTerminal-mac.git
cd RtlTerminal-mac
./scripts/build-app.sh                 # dist/RtlTerminal.app, .zip and .dmg
cp -R dist/RtlTerminal.app /Applications/
```

```bash
UNIVERSAL=1 ./scripts/build-app.sh     # arm64 + x86_64 (requires full Xcode)
swift run RtlTerminal                  # run without bundling
swift test                             # unit tests (Swift 6 toolchain)
```

The app is ad-hoc signed. If macOS refuses to open it, right-click the app and choose Open once, or run the `xattr` command above. Set `SIGN_IDENTITY="Developer ID Application: …"` to sign for distribution.

### Keyboard and Mouse Shortcuts

| Action | Shortcut |
|---|---|
| New tab in the current folder | `⌘T` |
| New window | `⌘N` |
| Close tab | `⌘W` |
| Previous / next tab | `⇧⌘[` / `⇧⌘]` or `⌃Tab` |
| Copy / paste | `⌘C` / `⌘V` |
| Select all | `⌘A` |
| Interrupt the running command | `⌃C` |
| Clear scrollback | `⌘K` |
| Export session | `⌘S` |
| Smart RTL | `⇧⌘R` |
| Row RTL | `⌥⌘R` |
| Bigger / smaller / actual font size | `⌘+` / `⌘-` / `⌘0` |
| Open a link | `⌘`-click |
| Select text in apps that capture the mouse | Hold `Shift` |
| Settings | `⌘,` |

### Opening from Finder

After copying the app to `/Applications` and running it once, right-click a folder in Finder and choose **Services › New RTL Terminal Tab at Folder**. If the item is missing, enable it in System Settings › Keyboard › Keyboard Shortcuts › Services. Dropping a folder on the Dock icon also opens a terminal there.

### Releases

The only version number is in the `VERSION` file. Every push to `main` runs `.github/workflows/macos.yml`, which tests, builds a universal app and publishes it as release `v<VERSION>`; pushing again without changing `VERSION` replaces that release's files. To ship a new version, change `VERSION` and push. The download links above always point to the latest release.

### Project Layout

| Path | Contents |
|---|---|
| `Sources/RtlTerminalCore` | Platform-independent core: VT/xterm parser and screen buffer, Smart RTL, row layout, key encoding, link detection, themes |
| `Sources/RtlTerminal` | AppKit app: PTY session, CoreText renderer, windows/tabs, menus, settings, guide |
| `Tests/RtlTerminalCoreTests` | Unit tests, including ports of the Windows version's buffer regressions |

### Differences from the Windows Version

- Uses the native macOS PTY instead of ConPTY; the default shell is the user's login shell (usually zsh).
- Shortcuts follow macOS conventions (`⌘C` copies, `⌃C` interrupts).
- Right-click opens a Copy/Paste menu.
- Finder Services replace the Windows folder context menu.
- No automatic update check.

### Known Limitations

- Smart RTL uses directional spans, not the full Unicode bidi algorithm (same as the Windows version).
- Only SGR (1006) mouse reporting is implemented.

### Credits and License

Developed by **Amin Taghikhani**. Based on [RTL Terminal](https://github.com/mirbehnam/RtlTerminal) by behnamapps (behnam tajadini). MIT License, see [LICENSE](LICENSE).

---

<div dir="rtl">

## فارسی

### ترمینال RTL برای macOS

‏**RTL Terminal for macOS** یک شبیه ساز ترمینال برای کاربران فارسی، عربی و دیگر زبان های راست به چپ است. این برنامه نسخه macOS پروژه [RTL Terminal](https://github.com/mirbehnam/RtlTerminal) است: منطق اصلی نسخه ویندوز (مدل صفحه VT، الگوریتم Smart RTL و چیدمان سطرها) به Swift منتقل شده و رابط کاربری با AppKit و CoreText و PTY خود macOS بازنویسی شده است.

### امکانات

- ‏**Smart RTL**: سطرهای دارای متن فارسی یا عربی راست چین می شوند و کلمات انگلیسی، عددها، مسیرها (مثل `/usr/local/bin`) و گزینه ها (مثل `--version`) ترتیب خودشان را حفظ می کنند.
- ‏**Row RTL**: راست به چپ کردن اجباری کل سطر، حتی در برنامه های تمام صفحه (پیش فرض خاموش).
- حروف فارسی و عربی همیشه به هم متصل نمایش داده می شوند (شکل دهی با CoreText).
- امکان انتخاب **فونت جداگانه برای متن راست به چپ** (مثلا Vazirmatn) در کنار فونت monospace ترمینال.
- رنگ های ANSI، رنگ های روشن، dim، ۲۵۶ رنگ و RGB؛ bold، italic، underline و strikethrough.
- اجرای برنامه های تعاملی و TUI (مثل vim، htop، Claude Code، Codex، OpenCode) با پشتیبانی از alternate screen، bracketed paste، گزارش ماوس SGR، focus reporting و synchronized output.
- رسم دقیق کاراکترهای جعبه ای و بلوکی، بدون فاصله بین خانه ها.
- زبانه های بومی macOS (`⌘T`) که در همان پوشه زبانه فعلی باز می شوند.
- کپی و چسباندن با `⌘C` و `⌘V`؛ فایل های کپی شده به صورت مسیر و تصویرهای کلیپ بورد به صورت مسیر یک فایل PNG چسبانده می شوند (مناسب ابزارهای هوش مصنوعی خط فرمان).
- رهاکردن فایل روی ترمینال، مسیر آن را تایپ می کند.
- تشخیص لینک ها و بازکردن آن ها با `⌘ + کلیک`.
- میانبرهای Ctrl با چیدمان فارسی صفحه کلید هم کار می کنند.
- تم تیره، روشن یا هماهنگ با سیستم.
- تاریخچه ۲۰۰۰، ۵۰۰۰ یا ۱۰۰۰۰ خطی؛ پاک کردن تاریخچه با `⌘K`.
- خروجی گرفتن از محتوای جلسه در یک فایل متنی UTF-8 (`⌘S`).
- فهرست ده پوشه اخیر در منوی Shell.
- بازکردن ترمینال در یک پوشه از Finder (منوی Services) یا با انداختن پوشه روی آیکون Dock.
- راهنمای داخلی به انگلیسی، فارسی و عربی.

### پیش نیازها

- ‏macOS 12 (Monterey) یا جدیدتر، روی Apple Silicon یا Intel
- برای ساخت از کد منبع: Xcode یا Command Line Tools با Swift 5.9 یا جدیدتر (`xcode-select --install`)

### ساخت از کد منبع

```bash
git clone https://github.com/taghikhani/RtlTerminal-mac.git
cd RtlTerminal-mac
./scripts/build-app.sh
cp -R dist/RtlTerminal.app /Applications/
```

اسکریپت، فایل `dist/RtlTerminal.app` و نسخه های `zip` و `dmg` آن را می سازد. برای نسخه universal (هم Apple Silicon و هم Intel) که به Xcode کامل نیاز دارد، `UNIVERSAL=1 ./scripts/build-app.sh` را اجرا کنید.

برنامه با امضای ad-hoc ساخته می شود. اگر macOS اجازه بازکردن نمی دهد، یک بار روی برنامه راست کلیک کرده و Open را بزنید، یا دستور `xattr` بالای همین صفحه را اجرا کنید.

### میانبرها

| کار | میانبر |
|---|---|
| زبانه جدید در پوشه فعلی | `⌘T` |
| پنجره جدید | `⌘N` |
| بستن زبانه | `⌘W` |
| زبانه قبلی و بعدی | `⇧⌘[` و `⇧⌘]` یا `⌃Tab` |
| کپی و چسباندن | `⌘C` و `⌘V` |
| انتخاب همه | `⌘A` |
| متوقف کردن فرمان | `⌃C` |
| پاک کردن تاریخچه | `⌘K` |
| خروجی گرفتن از جلسه | `⌘S` |
| Smart RTL | `⇧⌘R` |
| Row RTL | `⌥⌘R` |
| بزرگ و کوچک کردن فونت | `⌘+` و `⌘-` و `⌘0` |
| بازکردن لینک | `⌘ + کلیک` |
| انتخاب متن در برنامه هایی که ماوس را می گیرند | نگه داشتن `Shift` |
| تنظیمات | `⌘,` |

### بازکردن از Finder

بعد از کپی برنامه در `/Applications` و یک بار اجرای آن، در Finder روی یک پوشه راست کلیک کنید و از **Services** گزینه **New RTL Terminal Tab at Folder** را انتخاب کنید. اگر این گزینه دیده نمی شود، آن را در System Settings › Keyboard › Keyboard Shortcuts › Services فعال کنید. انداختن پوشه روی آیکون برنامه در Dock هم ترمینال را در همان پوشه باز می کند.

### انتشار نسخه جدید

شماره نسخه فقط در فایل `VERSION` است. با هر push به `main`، برنامه تست و ساخته می شود و به صورت نسخه `v<VERSION>` منتشر می شود. برای انتشار نسخه جدید، عدد داخل `VERSION` را عوض کنید و push کنید. لینک های دانلود بالای صفحه همیشه به آخرین نسخه اشاره می کنند.

### تفاوت با نسخه ویندوز

- به جای ConPTY از PTY خود macOS استفاده می شود و shell پیش فرض، login shell کاربر (معمولا zsh) است.
- میانبرها مطابق عادت macOS هستند (`⌘C` برای کپی و `⌃C` برای توقف).
- راست کلیک منوی Copy و Paste را باز می کند.
- به جای منوی راست کلیک ویندوز، از Services در Finder استفاده می شود.
- بررسی خودکار به روزرسانی در این نسخه وجود ندارد.

### محدودیت های شناخته شده

- ‏Smart RTL از بازه های جهت دار استفاده می کند، نه الگوریتم کامل bidi یونیکد (مثل نسخه ویندوز).
- فقط گزارش ماوس SGR (1006) پیاده سازی شده است.

### سازنده و مجوز

ساخته شده توسط **Amin Taghikhani**. بر اساس [RTL Terminal](https://github.com/mirbehnam/RtlTerminal) ساخته behnamapps (behnam tajadini). مجوز MIT؛ فایل [LICENSE](LICENSE) را ببینید.

</div>

---

<div dir="rtl">

## العربية

### ‏RTL Terminal لنظام macOS

‏**RTL Terminal for macOS** محاكي طرفية لمستخدمي العربية والفارسية وغيرهما من اللغات التي تُكتب من اليمين إلى اليسار. وهو إصدار macOS من مشروع [RTL Terminal](https://github.com/mirbehnam/RtlTerminal): نُقل المنطق الأساسي لإصدار ويندوز (نموذج شاشة VT وخوارزمية Smart RTL وتخطيط الأسطر) إلى Swift، وأُعيد بناء الواجهة باستخدام AppKit وCoreText وPTY الأصلي في macOS.

### الميزات

- ‏**Smart RTL**: يحاذي الأسطر التي تحتوي على العربية أو الفارسية إلى اليمين، مع الحفاظ على ترتيب الكلمات الإنجليزية والأرقام والمسارات (مثل `/usr/local/bin`) والخيارات (مثل `--version`).
- ‏**Row RTL**: يفرض اتجاه السطر من اليمين إلى اليسار، حتى في التطبيقات بملء الشاشة (معطّل افتراضياً).
- تبقى الحروف العربية والفارسية متصلة دائماً (التشكيل عبر CoreText) وتُضبط داخل خلايا الطرفية.
- إمكانية اختيار **خط مستقل للنص من اليمين إلى اليسار** (مثل Vazirmatn) إلى جانب الخط أحادي المسافة للطرفية.
- ألوان ANSI والألوان الساطعة وdim و256 لوناً وRGB؛ مع bold وitalic وunderline وstrikethrough.
- تشغيل التطبيقات التفاعلية وتطبيقات TUI (مثل vim وhtop وClaude Code وCodex وOpenCode) مع دعم alternate screen وbracketed paste وتقارير فأرة SGR وfocus reporting وsynchronized output.
- رسم دقيق لأحرف الصناديق والكتل دون فراغات بين الخلايا.
- ألسنة macOS الأصلية (`⌘T`) تُفتح في مجلد اللسان الحالي.
- النسخ واللصق عبر `⌘C` و`⌘V`؛ تُلصق الملفات المنسوخة كمسارات وصور الحافظة كمسار لملف PNG (مفيد لأدوات الذكاء الاصطناعي في سطر الأوامر).
- إسقاط الملفات على الطرفية يكتب مساراتها.
- اكتشاف الروابط وفتحها عبر `⌘` مع النقر.
- اختصارات Ctrl تعمل أيضاً مع تخطيط لوحة المفاتيح العربي والفارسي.
- سمة داكنة أو فاتحة أو متوافقة مع النظام.
- سجل بطول 2000 أو 5000 أو 10000 سطر؛ ويُمسح عبر `⌘K`.
- تصدير محتوى الجلسة إلى ملف نصي UTF-8 (`⌘S`).
- قائمة بآخر عشرة مجلدات في قائمة Shell.
- فتح الطرفية في مجلد من Finder (قائمة Services) أو بسحب المجلد إلى أيقونة Dock.
- دليل مدمج بالإنجليزية والفارسية والعربية.

### المتطلبات

- ‏macOS 12 (Monterey) أو أحدث، على Apple Silicon أو Intel
- للبناء من المصدر: Xcode أو Command Line Tools مع Swift 5.9 أو أحدث (`xcode-select --install`)

### البناء من المصدر

```bash
git clone https://github.com/taghikhani/RtlTerminal-mac.git
cd RtlTerminal-mac
./scripts/build-app.sh
cp -R dist/RtlTerminal.app /Applications/
```

ينشئ السكربت الملف `dist/RtlTerminal.app` ونسختي `zip` و`dmg` منه. لبناء نسخة universal (لـ Apple Silicon وIntel معاً)، وهي تتطلب Xcode الكامل، نفّذ `UNIVERSAL=1 ./scripts/build-app.sh`.

يُوقَّع التطبيق توقيعاً ad-hoc. إذا رفض macOS فتحه، انقر عليه بالزر الأيمن واختر Open مرة واحدة، أو نفّذ أمر `xattr` الموجود أعلى هذه الصفحة.

### الاختصارات

| الإجراء | الاختصار |
|---|---|
| لسان جديد في المجلد الحالي | `⌘T` |
| نافذة جديدة | `⌘N` |
| إغلاق اللسان | `⌘W` |
| اللسان السابق والتالي | `⇧⌘[` و`⇧⌘]` أو `⌃Tab` |
| النسخ واللصق | `⌘C` و`⌘V` |
| تحديد الكل | `⌘A` |
| إيقاف الأمر الجاري | `⌃C` |
| مسح السجل | `⌘K` |
| تصدير الجلسة | `⌘S` |
| Smart RTL | `⇧⌘R` |
| Row RTL | `⌥⌘R` |
| تكبير الخط وتصغيره وإعادته | `⌘+` و`⌘-` و`⌘0` |
| فتح رابط | `⌘` مع النقر |
| تحديد النص في التطبيقات التي تلتقط الفأرة | الضغط على `Shift` |
| الإعدادات | `⌘,` |

### الفتح من Finder

بعد نسخ التطبيق إلى `/Applications` وتشغيله مرة واحدة، انقر بالزر الأيمن على مجلد في Finder واختر من **Services** الخيار **New RTL Terminal Tab at Folder**. إذا لم يظهر الخيار، فعّله من System Settings › Keyboard › Keyboard Shortcuts › Services. كما أن سحب مجلد إلى أيقونة التطبيق في Dock يفتح الطرفية في ذلك المجلد.

### نشر إصدار جديد

رقم الإصدار موجود فقط في ملف `VERSION`. مع كل push إلى `main` يُختبر التطبيق ويُبنى ويُنشر كإصدار `v<VERSION>`. لنشر إصدار جديد، غيّر الرقم في `VERSION` ثم نفّذ push. روابط التنزيل أعلى الصفحة تشير دائماً إلى أحدث إصدار.

### الفروق عن إصدار ويندوز

- يُستخدم PTY الأصلي في macOS بدلاً من ConPTY، والـ shell الافتراضي هو login shell الخاص بالمستخدم (غالباً zsh).
- الاختصارات تتبع أعراف macOS (`⌘C` للنسخ و`⌃C` للإيقاف).
- النقر الأيمن يفتح قائمة Copy وPaste.
- تحل Services في Finder محل قائمة النقر الأيمن في ويندوز.
- لا يوجد فحص تلقائي للتحديثات في هذا الإصدار.

### القيود المعروفة

- يستخدم Smart RTL مقاطع اتجاهية، وليس خوارزمية bidi الكاملة في يونيكود (كما في إصدار ويندوز).
- لم يُنفَّذ سوى تقارير الفأرة بصيغة SGR (1006).

### المطوّر والترخيص

تطوير **Amin Taghikhani**. مبني على [RTL Terminal](https://github.com/mirbehnam/RtlTerminal) من behnamapps (behnam tajadini). ترخيص MIT؛ راجع ملف [LICENSE](LICENSE).

</div>
