#if canImport(AppKit)
import AppKit

/// Built-in guide in English, Persian and Arabic.
final class GuideWindowController: NSWindowController {
    private struct Guide {
        var title: String
        var rightToLeft: Bool
        var sections: [(String, String)]
    }

    private static let guides: [Guide] = [
        Guide(title: "English", rightToLeft: false, sections: [
            ("RTL Terminal Guide", "A quick guide to the terminal features and shortcuts on macOS."),
            ("Display direction",
             "Smart RTL (View menu, ⇧⌘R) right-aligns lines that contain Persian or Arabic and keeps English words, numbers and paths in their own order. Letters stay joined even when it is off. Row RTL (⌥⌘R) is off by default; it forces right-to-left rows, also in full-screen applications, and may move their borders."),
            ("Copy and paste",
             "Select text and press ⌘C to copy; ⌘V pastes. Copied files are pasted as quoted paths and clipboard images as a path to a PNG file. Double-click selects a word, triple-click a line. ⌃C always interrupts the running command."),
            ("Mouse in terminal applications",
             "When an application captures the mouse, hold Shift to select text. Right-click opens the Copy/Paste menu."),
            ("Opening links",
             "HTTP/HTTPS links are blue. Hold ⌘ and click to open a link."),
            ("Tabs and windows",
             "⌘T opens a tab in the current folder, ⌘N a new window, ⌘W closes a tab. ⇧⌘[ and ⇧⌘] (or ⌃Tab) switch tabs."),
            ("Finder",
             "Drop a folder on the Dock icon, or use Finder ▸ Services ▸ New RTL Terminal Tab at Folder. Files dropped on the terminal are typed as paths."),
            ("Keyboard",
             "Ctrl shortcuts work with Persian and Arabic keyboard layouts too. Enable “Use Option as Meta key” in Settings for Emacs/readline Alt shortcuts.")
        ]),
        Guide(title: "فارسی", rightToLeft: true, sections: [
            ("راهنمای RTL Terminal", "راهنمای سریع امکانات و میانبرهای ترمینال در macOS."),
            ("جهت نمایش",
             "گزینه Smart RTL در منوی View (یا ⇧⌘R) سطرهای فارسی و عربی را راست چین می کند و ترتیب کلمات انگلیسی، عددها و مسیرها را حفظ می کند. اتصال حروف حتی با خاموش بودن آن حفظ می شود. گزینه Row RTL (یا ⌥⌘R) به صورت پیش فرض خاموش است و جهت کل سطر را حتی در برنامه های تمام صفحه راست به چپ می کند؛ ممکن است جای کادرهای رابط آن ها تغییر کند."),
            ("کپی و چسباندن",
             "متن را انتخاب کنید و برای کپی ⌘C و برای چسباندن ⌘V را بزنید. فایل های کپی شده به صورت مسیر و تصویرهای کلیپ بورد به صورت مسیر یک فایل PNG چسبانده می شوند. دوبار کلیک یک کلمه و سه بار کلیک یک سطر را انتخاب می کند. ⌃C همیشه فرمان جاری را متوقف می کند."),
            ("ماوس در برنامه های ترمینالی",
             "در برنامه هایی که ماوس را دریافت می کنند، برای انتخاب متن کلید Shift را نگه دارید. راست کلیک منوی Copy و Paste را باز می کند."),
            ("بازکردن لینک ها",
             "لینک های HTTP و HTTPS آبی هستند. برای بازکردن لینک ⌘ را نگه دارید و کلیک کنید."),
            ("زبانه ها و پنجره ها",
             "⌘T یک زبانه در همان پوشه، ⌘N یک پنجره جدید باز می کند و ⌘W زبانه را می بندد. با ⇧⌘[ و ⇧⌘] یا ⌃Tab بین زبانه ها جابه جا شوید."),
            ("Finder",
             "یک پوشه را روی آیکون Dock بیندازید یا از Finder گزینه Services و سپس New RTL Terminal Tab at Folder را انتخاب کنید. فایل هایی که روی ترمینال رها شوند به صورت مسیر تایپ می شوند."),
            ("صفحه کلید",
             "میانبرهای Ctrl با چیدمان فارسی و عربی صفحه کلید هم کار می کنند. برای میانبرهای Alt در readline و Emacs گزینه Use Option as Meta key را در Settings فعال کنید.")
        ]),
        Guide(title: "العربية", rightToLeft: true, sections: [
            ("دليل RTL Terminal", "دليل سريع لميزات الطرفية واختصاراتها في macOS."),
            ("اتجاه العرض",
             "خيار Smart RTL في قائمة View (أو ⇧⌘R) يحاذي الأسطر العربية والفارسية إلى اليمين ويحافظ على ترتيب الكلمات الإنجليزية والأرقام والمسارات. تبقى الحروف متصلة حتى عند تعطيله. خيار Row RTL (أو ⌥⌘R) معطّل افتراضياً ويفرض اتجاه السطر من اليمين إلى اليسار حتى في التطبيقات بملء الشاشة؛ قد يغيّر مواضع حدود واجهتها."),
            ("النسخ واللصق",
             "حدّد النص واضغط ⌘C للنسخ و⌘V للصق. تُلصق الملفات المنسوخة كمسارات وصور الحافظة كمسار لملف PNG. النقر المزدوج يحدد كلمة والنقر الثلاثي يحدد سطراً. يرسل ⌃C دائماً إشارة الإيقاف."),
            ("الفأرة في تطبيقات الطرفية",
             "في التطبيقات التي تلتقط الفأرة، اضغط Shift لتحديد النص. النقر الأيمن يفتح قائمة النسخ واللصق."),
            ("فتح الروابط",
             "تظهر روابط HTTP/HTTPS باللون الأزرق. اضغط ⌘ مع النقر لفتح الرابط."),
            ("الألسنة والنوافذ",
             "⌘T يفتح لساناً في المجلد الحالي، و⌘N نافذة جديدة، و⌘W يغلق اللسان. للتنقل بين الألسنة استخدم ⇧⌘[ و⇧⌘] أو ⌃Tab."),
            ("Finder",
             "اسحب مجلداً إلى أيقونة Dock أو استخدم Finder ثم Services ثم New RTL Terminal Tab at Folder. الملفات المسحوبة إلى الطرفية تُكتب كمسارات."),
            ("لوحة المفاتيح",
             "اختصارات Ctrl تعمل أيضاً مع تخطيط لوحة المفاتيح العربي والفارسي. فعّل Use Option as Meta key في الإعدادات لاختصارات Alt في readline وEmacs.")
        ])
    ]

    private let scrollView = NSTextView.scrollableTextView()
    private var textView: NSTextView { scrollView.documentView as! NSTextView }
    private let languages = NSSegmentedControl()

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "RTL Terminal Guide"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        languages.segmentCount = Self.guides.count
        for (index, guide) in Self.guides.enumerated() {
            languages.setLabel(guide.title, forSegment: index)
        }
        let preferred = Locale.preferredLanguages.first ?? "en"
        languages.selectedSegment = preferred.hasPrefix("fa") ? 1 : preferred.hasPrefix("ar") ? 2 : 0
        languages.target = self
        languages.action = #selector(languageChanged)
        languages.translatesAutoresizingMaskIntoConstraints = false

        textView.isEditable = false
        textView.textContainerInset = NSSize(width: 16, height: 16)
        textView.drawsBackground = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(languages)
        content.addSubview(scrollView)
        NSLayoutConstraint.activate([
            languages.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            languages.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            scrollView.topAnchor.constraint(equalTo: languages.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: content.bottomAnchor)
        ])
        window.contentView = content
        window.center()
        show(Self.guides[languages.selectedSegment])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    @objc private func languageChanged() {
        show(Self.guides[languages.selectedSegment])
    }

    private func show(_ guide: Guide) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.baseWritingDirection = guide.rightToLeft ? .rightToLeft : .leftToRight
        paragraph.alignment = guide.rightToLeft ? .right : .left
        paragraph.paragraphSpacing = 10
        paragraph.lineSpacing = 3

        let text = NSMutableAttributedString()
        for (index, section) in guide.sections.enumerated() {
            let headingSize: CGFloat = index == 0 ? 20 : 14
            text.append(NSAttributedString(string: section.0 + "\n", attributes: [
                .font: NSFont.boldSystemFont(ofSize: headingSize),
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph
            ]))
            text.append(NSAttributedString(string: section.1 + "\n\n", attributes: [
                .font: NSFont.systemFont(ofSize: 13),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph
            ]))
        }
        textView.textStorage?.setAttributedString(text)
    }
}
#endif
