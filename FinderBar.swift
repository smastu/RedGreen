// Finder に Windows 風のアドレス欄：前面の Finder の窓の下端（パスバーの位置）に、今のフォルダのフルパスを出す。
//  クリックすると全選択で編集でき、Return でそのフォルダへ移動（ファイルなら開く）、Esc で取り消し。~ も使える
//  Finder の今のフォルダは AppleScript で取る（初回に「オートメーション」の許可が出る）
import AppKit
import ApplicationServices

final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// クリックしたら全選択（Windows のアドレス欄と同じ）
final class AddressField: NSTextField {
    override func mouseDown(with e: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: e)
        if !wasEditing { currentEditor()?.selectAll(nil) }
    }

    /// RedGreen には「編集」メニューがないので、⌘A・⌘C・⌘V・⌘X・⌘Z・⇧⌘Z をここで受け取る
    override func performKeyEquivalent(with e: NSEvent) -> Bool {
        let mods = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard mods == .command || mods == [.command, .shift], let editor = currentEditor() as? NSTextView,
              let key = e.charactersIgnoringModifiers?.lowercased() else { return super.performKeyEquivalent(with: e) }
        switch (key, mods.contains(.shift)) {
        case ("a", false): editor.selectAll(nil)
        case ("c", false): editor.copy(nil)
        case ("v", false): editor.pasteAsPlainText(nil)
        case ("x", false): editor.cut(nil)
        case ("z", false): editor.undoManager?.undo()
        case ("z", true): editor.undoManager?.redo()
        default: return super.performKeyEquivalent(with: e)
        }
        return true
    }
}

final class FinderBar: NSObject, NSTextFieldDelegate {
    static let shared = FinderBar()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "finderBar") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "finderBar") }
    }

    private let panel: KeyPanel
    private let field = AddressField(string: "")
    private var timer: Timer?
    private var lastWindow: AXUIElement?
    private var lastTitle = ""
    private var editing = false
    private let height: CGFloat = 26

    private override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 26),
                         styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]

        let bg = NSVisualEffectView()
        bg.material = .titlebar
        bg.state = .active
        bg.blendingMode = .behindWindow
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = bg

        let icon = NSImageView(image: NSImage(systemSymbolName: "folder", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = .secondaryLabelColor
        icon.translatesAutoresizingMaskIntoConstraints = false

        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: 12)
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.lineBreakMode = .byTruncatingHead
        field.placeholderString = L("finderBar.placeholder")
        field.delegate = self
        field.allowsEditingTextAttributes = false
        field.translatesAutoresizingMaskIntoConstraints = false

        bg.addSubview(icon)
        bg.addSubview(field)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 16),
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -8),
            field.centerYAnchor.constraint(equalTo: bg.centerYAnchor),
        ])
    }

    /// 軽さ重視：Finder が前面のときだけ 0.25 秒ごとに窓を追い、それ以外は止める
    func start() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontChanged(isFinder: a?.bundleIdentifier == "com.apple.finder")
        }
        frontChanged(isFinder: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder")
    }

    private func frontChanged(isFinder: Bool) {
        if isFinder && FinderBar.enabled {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
                tick()
            }
        } else {
            timer?.invalidate()
            timer = nil
            if !editing { panel.orderOut(nil) }
        }
    }

    func settingChanged() {
        frontChanged(isFinder: NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder")
    }

    /// 前面の Finder の窓を追いかける（Finder が前面のときだけ表示）
    private func tick() {
        guard FinderBar.enabled, let finder = finderApp,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier else {
            if panel.isVisible && !editing { panel.orderOut(nil) }
            return
        }
        let ax = AXUIElementCreateApplication(finder.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.2)
        guard let w: AXUIElement = attr(ax, kAXFocusedWindowAttribute),
              (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              (attr(w, "AXFullScreen") as Bool?) != true,
              let f = currentFrame(w), f.width > 200 else {
            if panel.isVisible && !editing { panel.orderOut(nil) }
            return
        }
        // アクセシビリティの座標（左上原点）→ 画面の座標（左下原点）。窓の下端の内側に置く
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let rect = NSRect(x: f.minX + 8, y: primaryH - f.maxY + 4, width: f.width - 16, height: height)
        if panel.frame != rect { panel.setFrame(rect, display: true) }
        if !panel.isVisible { panel.orderFront(nil) }

        let title: String = attr(w, kAXTitleAttribute) ?? ""
        let changedWindow = lastWindow.map { !CFEqual($0, w) } ?? true
        if !editing && (changedWindow || title != lastTitle) {
            lastWindow = w
            lastTitle = title
            refreshPath()
        }
    }

    /// AppleScript は専用の裏スレッドで動かす（Finder の返事待ちや許可の確認で、キー操作を止めないため）
    private let scriptQueue = DispatchQueue(label: "RedGreen.FinderBar.script")
    private var fetching = false

    private lazy var getScript = NSAppleScript(source: """
        tell application "Finder"
            if (count of Finder windows) = 0 then return ""
            try
                return POSIX path of (target of Finder window 1 as alias)
            on error
                return ""
            end try
        end tell
        """)

    private func refreshPath() {
        guard !fetching else { lastTitle = ""; return }       // 実行中なら次の tick でもう一度
        fetching = true
        let script = getScript
        scriptQueue.async { [weak self] in
            var err: NSDictionary?
            let r = script?.executeAndReturnError(&err)
            let code = err?[NSAppleScript.errorNumber] as? Int
            var p = r?.stringValue ?? ""
            if p.count > 1 && p.hasSuffix("/") { p.removeLast() }
            DispatchQueue.main.async {
                guard let self else { return }
                self.fetching = false
                guard !self.editing else { return }
                if let code {
                    self.field.stringValue = ""
                    self.field.placeholderString = (code == -1743) ? L("finderBar.needPermission") : self.lastTitle
                    return
                }
                self.field.placeholderString = L("finderBar.placeholder")
                self.field.stringValue = p.isEmpty ? self.lastTitle : p   // 「最近の項目」など、場所のない窓は名前だけ
            }
        }
    }

    // MARK: 編集

    func controlTextDidBeginEditing(_ obj: Notification) {
        editing = true
        (obj.userInfo?["NSFieldEditor"] as? NSTextView)?.allowsUndo = true
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy sel: Selector) -> Bool {
        if sel == #selector(NSResponder.insertNewline(_:)) { commit(); return true }
        if sel == #selector(NSResponder.cancelOperation(_:)) { finishEditing(); return true }
        return false
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        if editing { editing = false; lastTitle = "" }      // 編集をやめたら表示を戻す
    }

    private func commit() {
        let raw = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = (raw as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard !p.isEmpty, FileManager.default.fileExists(atPath: p, isDirectory: &isDir) else {
            NSSound.beep()
            return
        }
        if isDir.boolValue {
            let esc = p.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            scriptQueue.async {
                var err: NSDictionary?
                NSAppleScript(source: "tell application \"Finder\" to set target of Finder window 1 to (POSIX file \"\(esc)\" as alias)")?
                    .executeAndReturnError(&err)
                if err != nil { DispatchQueue.main.async { NSSound.beep() } }
            }
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: p))
        }
        finishEditing()
    }

    /// 編集を終えて、キーボードを Finder の窓に返す
    private func finishEditing() {
        editing = false
        lastTitle = ""
        panel.makeFirstResponder(nil)
        if let w = lastWindow {
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        finderApp?.activate()
    }
}
