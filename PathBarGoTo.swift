import AppKit
import ApplicationServices

// MARK: - Finder のパスバーにマウスを止める／ダブルクリック → 「フォルダへ移動」（⌘⇧G）
// パスバーの空いているところをダブルクリックすると、Finder の「フォルダへ移動」を開き、
// 今のフォルダのパスを入れて全選択する（そのまま打ち直せる）。
// パスバーのフォルダ名のダブルクリックは Finder 標準（そのフォルダへ移動）のまま。

enum PathBarGoTo {
    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "pathBarGoTo") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "pathBarGoTo") }
    }

    /// パスバー上の部品のうち、Finder 標準のダブルクリックを優先するもの（フォルダ名など）
    private static let itemRoles: Set<String> = [
        kAXButtonRole, kAXMenuButtonRole, kAXStaticTextRole, kAXImageRole, kAXCellRole,
        kAXRowRole, kAXTextFieldRole, "AXPathComponent",
    ]

    private static let queue = DispatchQueue(label: "RedGreen.PathBarGoTo")

    /// ダブルクリック（イベントタップの中で呼ぶ）。開いたら true（呼び出し側はクリックを Finder に渡さない。
    /// 渡すと Finder がタイトルバーのダブルクリックとして窓を拡大・縮小してしまう）
    static func handle(_ event: CGEvent, element e: AXUIElement) -> Bool {
        guard enabled, event.getIntegerValueField(.mouseEventClickState) == 2,
              !event.flags.contains(.maskAlternate),
              let pid = emptySpot(e, event.location, why: "ダブルクリック") else { return false }
        open(pid: pid, waitMouseUp: true)
        return true
    }

    // マウスオーバー：パスバーの空いているところに hoverDelay 秒止めたら開く（離れるまで出し直さない）
    static let hoverDelay: TimeInterval = 0.25
    private static var hoverDone = false
    static func mouseMoved() { hoverDone = false }
    static func hover(_ p: CGPoint, rest: TimeInterval) {
        guard enabled, !hoverDone, rest > hoverDelay, NSEvent.pressedMouseButtons == 0 else { return }
        hoverDone = true
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &el) == .success, let e = el else { return }
        guard let pid = emptySpot(e, p, why: "マウスオーバー") else { return }
        open(pid: pid, waitMouseUp: false)
    }

    /// 前面の Finder の窓のパスバーの空いているところなら、その Finder の pid
    private static func emptySpot(_ e: AXUIElement, _ loc: CGPoint, why: String) -> pid_t? {
        guard let finder = finderApp,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == finder.processIdentifier else { return nil }
        var pid: pid_t = 0
        guard AXUIElementGetPid(e, &pid) == .success, pid == finder.processIdentifier,
              let w: AXUIElement = attr(e, kAXWindowAttribute),
              (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole,
              let f = currentFrame(w) else { return nil }
        // 「フォルダへ移動」などのシートが出ている間は何もしない
        if let kids: [AXUIElement] = attr(w, kAXChildrenAttribute),
           kids.contains(where: { (attr($0, kAXRoleAttribute) as String?) == kAXSheetRole }) { return nil }
        // 上（窓のタイトル）は反応しない：窓をドラッグするときに邪魔になるため
        // 下：パスバーの帯（窓の下端から。ステータスバーがあればその分も）
        guard finderPref("ShowPathbar") else { return nil }
        let band: CGFloat = finderPref("ShowStatusBar") ? 56 : 32
        let fromBottom = f.maxY - loc.y
        guard fromBottom >= 0, fromBottom <= band else { return nil }
        let role: String = attr(e, kAXRoleAttribute) ?? "?"
        log("パスバーの\(why)：\(roleChain(e)) 下端から \(Int(fromBottom))pt")
        guard !itemRoles.contains(role) else { return nil }        // フォルダ名 → Finder 標準
        // パスバー（AXList）が返ったときは、中のフォルダ名の上かどうかを位置で調べる
        if let item = childContaining(e, loc) {
            log("  フォルダ名の上なので Finder 標準：\(item)")
            return nil
        }
        return pid
    }

    private static func open(pid: pid_t, waitMouseUp: Bool) {
        queue.async {
            // マウスを離すまで待つ（押している間は Finder がキーを受け付けない）
            if waitMouseUp {
                for _ in 0..<40 where NSEvent.pressedMouseButtons & 1 != 0 { usleep(25_000) }
                usleep(80_000)
            }
            // ⌘⇧G（Finder が前面なので、ふつうのキー入力として送る）
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                let k = CGEvent(keyboardEventSource: src, virtualKey: 5, keyDown: down)   // G
                k?.flags = [.maskCommand, .maskShift]
                k?.post(tap: .cghidEventTap)
            }
            log("  ⌘⇧G を送った")
            // 開いてから今のフォルダを聞く（「Finder の操作」の許可待ちでキーが遅れないように）
            let path = (try? FinderAE.frontTarget().get()) ?? nil
            guard let path, !path.isEmpty else { log("  今のフォルダが分からないので空のまま"); return }
            // 入力欄が出るのを待って、今のフォルダのパスを入れて全選択
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            for _ in 0..<20 {
                usleep(50_000)
                guard let field: AXUIElement = attr(ax, kAXFocusedUIElementAttribute) else { continue }
                let r: String = attr(field, kAXRoleAttribute) ?? ""
                guard r == kAXTextFieldRole || r == kAXComboBoxRole else { continue }
                let value = path.hasSuffix("/") ? path : path + "/"
                arm(pid: pid, field: field)
                AXUIElementSetAttributeValue(field, kAXValueAttribute as CFString, value as CFTypeRef)
                var range = CFRange(location: 0, length: (value as NSString).length)
                if let v = AXValueCreate(.cfRange, &range) {
                    AXUIElementSetAttributeValue(field, kAXSelectedTextRangeAttribute as CFString, v)
                }
                return
            }
        }
    }

    // MARK: 開いた「フォルダへ移動」の外をクリックしたら取り消す
    // RedGreen が開いたものだけが対象（自分で ⌘⇧G を押したもの・ほかの確認の画面には手を出さない）。
    // クリックはそのまま渡すので、押した先の操作はふつうに効く。
    private static var armed: (pid: pid_t, panel: AXUIElement)?

    /// 入力欄を含むシート（無ければ窓）を覚える
    private static func arm(pid: pid_t, field: AXUIElement) {
        var cur: AXUIElement? = field
        var panel: AXUIElement?
        for _ in 0..<12 {
            guard let c = cur, let r: String = attr(c, kAXRoleAttribute) else { break }
            if r == kAXSheetRole || r == kAXWindowRole { panel = c; break }
            cur = attr(c, kAXParentAttribute)
        }
        guard let panel else { return }
        DispatchQueue.main.async { armed = (pid, panel) }
        log("  外をクリックしたら閉じる：\((attr(panel, kAXRoleAttribute) as String?) ?? "?")")
    }

    /// クリックのたびに呼ぶ（イベントタップの中。重い処理は別スレッドで）
    static func clicked(at loc: CGPoint) {
        guard let a = armed else { return }
        armed = nil
        queue.async {
            AXUIElementSetMessagingTimeout(a.panel, 0.3)
            guard let f = currentFrame(a.panel) else { return }      // もう閉じている
            guard !f.contains(loc) else {                              // 中のクリック → 見張りを続ける
                DispatchQueue.main.async { if armed == nil { armed = a } }
                return
            }
            log("「フォルダへ移動」の外をクリック → 閉じる")
            // 取り消しボタンがあれば押す。無ければ Finder に Esc を送る
            if let cancel: AXUIElement = attr(a.panel, kAXCancelButtonAttribute),
               AXUIElementPerformAction(cancel, kAXPressAction as CFString) == .success { return }
            let src = CGEventSource(stateID: .hidSystemState)
            for down in [true, false] {
                CGEvent(keyboardEventSource: src, virtualKey: 53, keyDown: down)?.postToPid(a.pid)   // Esc
            }
        }
    }

    /// 位置 p を含む子（パスバーの中のフォルダ名など）の説明。なければ nil
    private static func childContaining(_ e: AXUIElement, _ p: CGPoint) -> String? {
        guard let kids: [AXUIElement] = attr(e, kAXChildrenAttribute) else { return nil }
        for k in kids {
            guard let r = currentFrame(k), r.contains(p) else { continue }
            let role: String = attr(k, kAXRoleAttribute) ?? "?"
            let title: String = attr(k, kAXTitleAttribute) ?? attr(k, kAXDescriptionAttribute) ?? ""
            return "\(role) \(title)"
        }
        return nil
    }

    private static func finderPref(_ key: String) -> Bool {
        (CFPreferencesCopyAppValue(key as CFString, "com.apple.finder" as CFString) as? Bool) ?? false
    }

    /// 調べるための記録：押した部品から窓までの役割の並び
    private static func roleChain(_ e: AXUIElement) -> String {
        var out: [String] = []
        var cur: AXUIElement? = e
        for _ in 0..<6 {
            guard let c = cur, let r: String = attr(c, kAXRoleAttribute) else { break }
            if r == kAXWindowRole { break }
            let d: String = attr(c, kAXDescriptionAttribute) ?? ""
            let s: String = attr(c, kAXSubroleAttribute) ?? ""
            out.append([r, s, d].filter { !$0.isEmpty }.joined(separator: ":"))
            cur = attr(c, kAXParentAttribute)
        }
        return out.joined(separator: " < ")
    }
}
