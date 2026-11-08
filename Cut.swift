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

    /// tap から呼ぶ。true を返したら元のキーは捨てる
    func handle(_ e: CGEvent) -> Bool {
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
    private func pressMenu(_ pid: pid_t, char: String, mods: Int) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.5)
        guard let bar: AXUIElement = axValue(app, kAXMenuBarAttribute) else { return false }
        for top in axChildren(bar) {
            for menu in axChildren(top) {
                for it in axChildren(menu) {
                    guard (axValue(it, kAXMenuItemCmdCharAttribute) as String?) == char,
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
