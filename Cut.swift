import Cocoa

/// Finder で ⌘X → ⌘V をファイルの「移動」にする（Command X の代わり）
/// ⌘X で Finder の「コピー」を押して印を付け、次の ⌘V で「ここに項目を移動」（⌥⌘V）を押す（メニューは AX で押す）。
/// 名前の変更中や検索欄など、文字を入力している最中はふつうの ⌘X・⌘V のまま。
final class CutPaste {
    static let shared = CutPaste()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "cutPaste") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cutPaste"); if !newValue { shared.pending = nil } }
    }

    /// 切り取りの印：⌘C のあとのクリップボードの変更回数（ほかでコピーしたら印は無効）
    private var pending: Int?
    private let finderID = "com.apple.finder"

    /// Finder で Windows のキー：Enter で開く、Delete でゴミ箱、F2 で名前の変更
    static var winKeys: Bool {
        get { UserDefaults.standard.object(forKey: "finderWinKeys") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "finderWinKeys") }
    }

    /// RedGreen が自分で送ったキーの目印（自分で拾い直さないため）
    static let mark: Int64 = 0x5247

    /// tap から呼ぶ。true を返したら元のキーは捨てる
    func handle(_ e: CGEvent) -> Bool {
        if e.getIntegerValueField(.eventSourceUserData) == CutPaste.mark { return false }
        if CutPaste.winKeys, handleWinKeys(e) { return true }
        guard CutPaste.enabled else { return false }
        let f = e.flags
        guard f.contains(.maskCommand), !f.contains(.maskControl), !f.contains(.maskAlternate), !f.contains(.maskShift),
              !NSApp.isActive,                                           // RedGreen のアドレス欄に入力中は対象外
              let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == finderID else { return false }
        let key = e.getIntegerValueField(.keyboardEventKeycode)
        switch key {
        case 7:   // X
            if isTyping(front.processIdentifier) { return false }
            let pid = front.processIdentifier
            DispatchQueue.main.async {
                // Finder の「編集 → コピー」を押す（キーを作って送るより確実）
                guard self.pressMenu(pid, char: "C", mods: 0) else { NSSound.beep(); return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    let pb = NSPasteboard.general
                    let hasFiles = pb.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
                    self.pending = hasFiles ? pb.changeCount : nil
                }
            }
            return true
        case 9:   // V
            guard let p = pending, NSPasteboard.general.changeCount == p, !isTyping(front.processIdentifier) else {
                return false
            }
            pending = nil
            let pid = front.processIdentifier
            DispatchQueue.main.async {
                // 「編集 → ここに項目を移動」（⌥⌘V）。見つからなければふつうのペースト
                if !self.pressMenu(pid, char: "V", mods: 2) { _ = self.pressMenu(pid, char: "V", mods: 0) }
            }
            return true
        default:
            return false
        }
    }

    private func handleWinKeys(_ e: CGEvent) -> Bool {
        let f = e.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
        guard f.isEmpty, !NSApp.isActive,
              let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == finderID else { return false }
        let key = e.getIntegerValueField(.keyboardEventKeycode)
        guard key == 36 || key == 76 || key == 51 || key == 120 else { return false }
        let pid = front.processIdentifier
        guard inFileList(pid) else { return false }        // 名前の変更中・検索欄・確認の画面などはそのまま
        DispatchQueue.main.async {
            switch key {
            case 36, 76: _ = self.pressMenu(pid, char: "O", mods: 0)       // Enter → 開く（⌘O）
            case 51: self.confirmTrash(pid)                                // Delete → 確認してゴミ箱に入れる（⌘⌫）
            default: self.postReturn()                                     // F2 → 名前の変更（Return）
            }
        }
        return true
    }

    /// Delete の前に確認する（Windows と同じ）
    static var confirmDelete: Bool {
        get { UserDefaults.standard.object(forKey: "confirmDelete") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "confirmDelete") }
    }

    private let scriptQueue = DispatchQueue(label: "RedGreen.CutPaste.script")
    private lazy var selectionScript = NSAppleScript(source: """
        tell application "Finder"
            set out to {}
            repeat with i in (get selection)
                set end of out to name of i
            end repeat
            return out
        end tell
        """)

    /// 選んでいる項目の名前を Finder に聞いて、確認してからゴミ箱へ
    private func confirmTrash(_ pid: pid_t) {
        guard CutPaste.confirmDelete else { _ = pressMenu(pid, vkey: 51, mods: 0); return }
        let script = selectionScript
        scriptQueue.async {
            var err: NSDictionary?
            let r = script?.executeAndReturnError(&err)
            var names: [String] = []
            if let r, r.numberOfItems > 0 {
                for i in 1...r.numberOfItems { if let n = r.atIndex(i)?.stringValue { names.append(n) } }
            }
            DispatchQueue.main.async {
                if err != nil { _ = self.pressMenu(pid, vkey: 51, mods: 0); return }   // 聞けなければ確認なし（⌘⌫ と同じ）
                guard !names.isEmpty else { return }
                let alert = NSAlert()
                alert.messageText = names.count == 1 ? L("trash.one", names[0]) : L("trash.many", "\(names.count)")
                if names.count > 1 { alert.informativeText = names.prefix(8).joined(separator: "\n") + (names.count > 8 ? "\n…" : "") }
                alert.addButton(withTitle: L("trash.ok"))
                alert.addButton(withTitle: L("trash.cancel"))
                alert.icon = NSWorkspace.shared.icon(forFile: NSHomeDirectory() + "/.Trash")
                NSApp.activate(ignoringOtherApps: true)
                let ok = alert.runModal() == .alertFirstButtonReturn
                NSRunningApplication(processIdentifier: pid)?.activate()
                guard ok else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { _ = self.pressMenu(pid, vkey: 51, mods: 0) }
            }
        }
    }

    /// Finder のファイルの一覧（リスト・アイコン・カラム・ギャラリー表示、デスクトップ）にキーボードが向いているか
    private func inFileList(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let el: AXUIElement = axValue(app, kAXFocusedUIElementAttribute) else { return false }
        let role: String = axValue(el, kAXRoleAttribute) ?? ""
        return ["AXOutline", "AXList", "AXTable", "AXBrowser", "AXScrollArea", "AXGroup"].contains(role)
    }

    private func postReturn() {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            let ev = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: down)
            ev?.flags = []
            ev?.setIntegerValueField(.eventSourceUserData, value: CutPaste.mark)
            ev?.post(tap: .cgSessionEventTap)
        }
    }

    /// Finder で文字を入力中か（名前の変更・検索欄・「フォルダへ移動」など）
    private func isTyping(_ pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &v) == .success,
              let el = v, CFGetTypeID(el) == AXUIElementGetTypeID() else { return false }
        var r: CFTypeRef?
        AXUIElementCopyAttributeValue(el as! AXUIElement, kAXRoleAttribute as CFString, &r)
        let role = r as? String ?? ""
        return [kAXTextFieldRole, kAXTextAreaRole, kAXComboBoxRole, "AXSearchField"].contains(role)
    }

    /// メニューバーから、ショートカットが char＋mods（AX の値：⌥=2、⇧=1、⌃=4）の項目を探して押す
    private func pressMenu(_ pid: pid_t, char: String? = nil, vkey: Int? = nil, mods: Int) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = axValue(app, kAXMenuBarAttribute) else { return false }
        for top in axChildren(bar) {
            for menu in axChildren(top) {
                for it in axChildren(menu) {
                    let hit = char.map { (axValue(it, kAXMenuItemCmdCharAttribute) as String?) == $0 }
                        ?? ((axValue(it, kAXMenuItemCmdVirtualKeyAttribute) as Int?) == vkey)
                    guard hit,
                          (axValue(it, kAXMenuItemCmdModifiersAttribute) as Int?) ?? 0 == mods else { continue }
                    if (axValue(it, kAXEnabledAttribute) as Bool?) == false { return false }
                    return AXUIElementPerformAction(it, kAXPressAction as CFString) == .success
                }
            }
        }
        return false
    }

    private func axValue<T>(_ e: AXUIElement, _ a: String) -> T? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, a as CFString, &v) == .success else { return nil }
        return v as? T
    }

    private func axChildren(_ e: AXUIElement) -> [AXUIElement] {
        axValue(e, kAXChildrenAttribute) ?? []
    }
}
