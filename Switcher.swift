// ⌘Tab を Windows の Alt+Tab 風に：アプリ単位ではなく窓単位で切り替える（最小化・非表示の窓も選べる）
//  ⌘ を押したまま Tab で次、⇧Tab・矢印で前後、離すと切り替え、Esc で取り消し、クリックでも選べる
//  すぐ離せば一覧は出さずに直前の窓へ
import AppKit
import Carbon
import ApplicationServices

// macOS 標準の ⌘Tab を止める／戻す（非公開 API。AltTab なども使っている）
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32
// AX の窓 → CGWindowID（非公開 API）
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

// MARK: - 窓 1 枚だけを前に出す（macOS の非公開の命令。AltTab と同じ方法）
// アプリごと前面にすると、そのアプリの窓が全部前に出てしまうため

@_silgen_name("_SLPSSetFrontProcessWithOptions")
func _SLPSSetFrontProcessWithOptions(_ psn: inout ProcessSerialNumber, _ wid: CGWindowID, _ mode: UInt32) -> CGError

@_silgen_name("SLPSPostEventRecordTo")
func SLPSPostEventRecordTo(_ psn: inout ProcessSerialNumber, _ bytes: inout UInt8) -> CGError

@_silgen_name("GetProcessForPID")
func GetProcessForPID(_ pid: pid_t, _ psn: inout ProcessSerialNumber) -> OSStatus

/// 選んだ窓だけを最前面に（ほかの窓・ほかのアプリの重なり順は変えない）。できなければ false
func focusOnlyWindow(_ w: AXUIElement, pid: pid_t) -> Bool {
    var wid: CGWindowID = 0
    guard _AXUIElementGetWindow(w, &wid) == .success, wid != 0 else { return false }
    var psn = ProcessSerialNumber()
    guard GetProcessForPID(pid, &psn) == noErr else { return false }
    guard _SLPSSetFrontProcessWithOptions(&psn, wid, 0x200) == .success else { return false }   // 0x200 = 利用者の操作として
    // その窓をキーウインドウにする合図（AltTab の makeKeyWindow と同じ中身）
    var bytes = [UInt8](repeating: 0, count: 0xf8)
    bytes[0x04] = 0xf8
    bytes[0x3a] = 0x10
    withUnsafeBytes(of: wid) { for (i, b) in $0.enumerated() { bytes[0x3c + i] = b } }
    for i in 0x20..<0x30 { bytes[i] = 0xff }
    bytes[0x08] = 0x01
    _ = SLPSPostEventRecordTo(&psn, &bytes[0])
    bytes[0x08] = 0x02
    _ = SLPSPostEventRecordTo(&psn, &bytes[0])
    AXUIElementPerformAction(w, kAXRaiseAction as CFString)
    return true
}


struct SwitchItem {
    let app: NSRunningApplication
    let window: AXUIElement?
    let title: String
    let minimized: Bool
    let hidden: Bool

    /// 絞り込み用の文字（題名・アプリ名・英字のアプリ名）
    var haystack: String {
        let en = app.bundleURL?.deletingPathExtension().lastPathComponent ?? ""
        return [title, app.localizedName ?? "", en].joined(separator: " ").lowercased()
    }
}

/// 一覧の中から選んだ項目にする操作
enum SwitchAction { case close, minimize, quit, hide, fullscreen }

/// ⌘Tab に出さないアプリ（1 行に 1 つ。アプリ名かバンドル ID）
let switcherExcludeFile = supportDir.appendingPathComponent("switcher_exclude.txt")

final class Switcher {
    static let shared = Switcher()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "switcher") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "switcher"); shared.applySystemHotKeys() }
    }

    static func excluded() -> Set<String> {
        if !FileManager.default.fileExists(atPath: switcherExcludeFile.path) {
            try? (L("file.switcherExclude.header") + "\n").write(to: switcherExcludeFile, atomically: true, encoding: .utf8)
        }
        let t = (try? String(contentsOf: switcherExcludeFile, encoding: .utf8)) ?? ""
        return Set(t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }

    private(set) var active = false
    private var all: [SwitchItem] = []          // 集めた全部
    var items: [SwitchItem] = []                // 絞り込んだあと（表示しているもの）
    var index = 0
    private var searching = false               // S で検索中（⌘ を離しても閉じない）
    private var query = ""
    private var onlyPid: pid_t?                 // ⌘` のときは前面のアプリの窓だけ
    private let panel: NSPanel
    private let view: SwitchView

    private init() {
        view = SwitchView()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.acceptsMouseMovedEvents = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = view
        view.onPick = { [weak self] i in self?.index = i; self?.confirm() }
        view.onAction = { [weak self] i, a in self?.index = i; self?.act(a) }
    }

    /// 標準の ⌘Tab / ⇧⌘Tab を、この機能がオンで許可があるときだけ止める
    func applySystemHotKeys() {
        // セキュア入力（パスワード欄・リモートデスクトップなど）の間はキーが見えないので、標準の ⌘Tab に任せる
        let off = Switcher.enabled && AXIsProcessTrusted() && !IsSecureEventInputEnabled()
        _ = CGSSetSymbolicHotKeyEnabled(1, !off)   // ⌘Tab
        _ = CGSSetSymbolicHotKeyEnabled(2, !off)   // ⇧⌘Tab
    }

    /// セキュア入力の入り切りを 1 秒ごとに見て、変わったときだけ標準の ⌘Tab を戻す／止める
    private var secureTimer: Timer?
    private var lastSecure = false
    func watchSecureInput() {
        secureTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            let on = IsSecureEventInputEnabled()
            guard on != self.lastSecure else { return }
            self.lastSecure = on
            if on, self.active { self.cancel() }
            log(on ? L("log.secureOn") : L("log.secureOff"))
            self.applySystemHotKeys()
        }
    }

    func restoreSystemHotKeys() {
        _ = CGSSetSymbolicHotKeyEnabled(1, true)
        _ = CGSSetSymbolicHotKeyEnabled(2, true)
    }

    /// イベントタップから呼ぶ。true なら飲み込む
    func handle(_ type: CGEventType, _ e: CGEvent) -> Bool {
        guard Switcher.enabled else { return false }
        let flags = e.flags
        if type == .flagsChanged {
            if active && !searching && !flags.contains(.maskCommand) {
                DispatchQueue.main.async { self.confirm() }
            }
            return false
        }
        guard type == .keyDown else { return false }
        let key = e.getIntegerValueField(.keyboardEventKeycode)
        let back = flags.contains(.maskShift)
        if !active {
            guard flags.contains(.maskCommand), !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return false }
            if key == 48 { begin(backward: back, sameApp: false); return true }   // ⌘Tab
            if key == 50 { begin(backward: back, sameApp: true); return true }    // ⌘`：前面のアプリの窓だけ
            return false
        }
        // 共通：移動・決定・取り消し
        switch key {
        case 48, 50: move(back ? -1 : 1); return true                             // Tab ・ `
        case 126: move(-1); return true                                            // ↑
        case 125: move(1); return true                                             // ↓
        case 123: move(-view.columnStep); return true                              // ←
        case 124: move(view.columnStep); return true                               // →
        case 36, 76: DispatchQueue.main.async { self.confirm() }; return true      // Return
        case 53:                                                                   // Esc
            if searching && !query.isEmpty { query = ""; refilter() } else { cancel() }
            return true
        default: break
        }
        if searching {
            if key == 51 { if !query.isEmpty { query.removeLast(); refilter() }; return true }   // ⌫
            var len = 0
            var buf = [UniChar](repeating: 0, count: 4)
            e.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &len, unicodeString: &buf)
            let s = String(utf16CodeUnits: buf, count: len)
            if let c = s.unicodeScalars.first, !CharacterSet.controlCharacters.contains(c) {
                query += s; refilter()
            }
            return true
        }
        switch key {
        case 1: searching = true; query = ""; show()            // S：検索（選んでいる位置はそのまま）
        case 13: act(.close)                                     // W
        case 46: act(.minimize)                                  // M
        case 12: act(.quit)                                      // Q
        case 4: act(.hide)                                       // H
        case 3: act(.fullscreen)                                 // F
        default: break
        }
        return true
    }

    private func begin(backward: Bool, sameApp: Bool) {
        all = collect()
        onlyPid = sameApp ? NSWorkspace.shared.frontmostApplication?.processIdentifier : nil
        searching = false
        query = ""
        items = filtered()
        guard !items.isEmpty else { return }
        index = items.count > 1 ? (backward ? items.count - 1 : 1) : 0
        active = true
        // すぐ離したときは一覧を出さない（ちらつき防止）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.active else { return }
            self.show()
        }
    }

    private func filtered() -> [SwitchItem] {
        let terms = query.lowercased().split(separator: " ").map(String.init)
        return all.filter { it in
            (onlyPid == nil || it.app.processIdentifier == onlyPid)
                && terms.allSatisfy { it.haystack.contains($0) }
        }
    }

    /// 絞り込み直して表示を更新。検索の文字が変わったら先頭の候補を選ぶ
    private func refilter() {
        items = filtered()
        index = 0
        if panel.isVisible || searching { show() }
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        if abs(d) > 1 {   // 列の移動は端で止める（一周させない）
            index = max(0, min(items.count - 1, index + d))
        } else {
            index = (index + d + items.count) % items.count
        }
        if panel.isVisible { view.update(items: items, selected: index, query: searching ? query : nil) }
    }

    /// 選んでいる項目に操作をして、一覧を作り直す
    private func act(_ a: SwitchAction) {
        guard items.indices.contains(index) else { return }
        let it = items[index]
        let w = it.window
        switch a {
        case .close:
            guard let w, let b: AXUIElement = attr(w, kAXCloseButtonAttribute) else { NSSound.beep(); return }
            AXUIElementPerformAction(b, kAXPressAction as CFString)
        case .minimize:
            guard let w else { NSSound.beep(); return }
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, it.minimized ? kCFBooleanFalse : kCFBooleanTrue)
        case .quit:
            it.app.terminate()
        case .hide:
            if it.app.isHidden { it.app.unhide() } else { it.app.hide() }
        case .fullscreen:
            guard let w else { NSSound.beep(); return }
            let fs = (attr(w, "AXFullScreen") as Bool?) == true
            AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, fs ? kCFBooleanFalse : kCFBooleanTrue)
        }
        // 窓の変化は少し遅れて反映されるので、待ってから作り直す
        DispatchQueue.main.asyncAfter(deadline: .now() + (a == .quit ? 0.6 : 0.35)) { [weak self] in
            guard let self, self.active else { return }
            self.all = self.collect()
            let keepIndex = self.index
            self.items = self.filtered()
            if self.items.isEmpty && !self.searching { self.cancel(); return }
            self.index = min(keepIndex, max(0, self.items.count - 1))
            self.show()
        }
    }

    private func cancel() {
        active = false
        searching = false
        panel.orderOut(nil)
    }

    func confirm() {
        guard active else { return }
        active = false
        searching = false
        panel.orderOut(nil)
        guard items.indices.contains(index) else { return }
        let it = items[index]
        if it.app.isHidden { it.app.unhide() }
        if let w = it.window {
            if it.minimized { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            if focusOnlyWindow(w, pid: it.app.processIdentifier) { return }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
        // 窓のないアプリ、または上の方法が使えないとき（アプリごと前面に）
        let ax = AXUIElementCreateApplication(it.app.processIdentifier)
        AXUIElementSetAttributeValue(ax, kAXFrontmostAttribute as CFString, kCFBooleanTrue)
        it.app.activate()
    }

    private func show() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens[0]
        let f = screen.visibleFrame
        // 高さは画面の 70% まで（上下 15% は空ける）。幅は画面の 90% まで
        view.limit = NSSize(width: f.width * 0.9, height: f.height * 0.7)
        view.update(items: items, selected: index, query: searching ? query : nil)
        let size = view.fittingSize
        // 少ないときは少し上寄せ。多いときも上下 15% の余白は守る
        var y = f.midY - size.height / 2 + f.height * 0.1
        y = min(y, f.maxY - f.height * 0.15 - size.height)
        y = max(y, f.minY + f.height * 0.15)
        panel.setFrame(NSRect(x: f.midX - size.width / 2, y: y, width: size.width, height: size.height), display: true)
        panel.orderFrontRegardless()
    }

    /// 窓の一覧：画面の前にある順（＝最近使った順に近い）→ 最小化・非表示 → 窓のないアプリ
    private func collect() -> [SwitchItem] {
        let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        let order = info.filter { ($0[kCGWindowLayer as String] as? Int) == 0 }
            .compactMap { $0[kCGWindowNumber as String] as? CGWindowID }
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let skip = Switcher.excluded()
        var ranked: [(SwitchItem, Int)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() && !app.isTerminated
            && !Prefs.matches(app, skip) {
            let ax = AXUIElementCreateApplication(app.processIdentifier)
            AXUIElementSetMessagingTimeout(ax, 0.2)
            let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
            var any = false
            for w in ws where (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole {
                any = true
                var id: CGWindowID = 0
                _ = _AXUIElementGetWindow(w, &id)
                let minimized = (attr(w, kAXMinimizedAttribute) as Bool?) == true
                let title: String = attr(w, kAXTitleAttribute) ?? ""
                let rank = order.firstIndex(of: id) ?? (10_000 + (minimized ? 1 : 0) + (app.isHidden ? 2 : 0))
                ranked.append((SwitchItem(app: app, window: w, title: title, minimized: minimized, hidden: app.isHidden), rank))
            }
            if !any {
                ranked.append((SwitchItem(app: app, window: nil, title: "", minimized: false, hidden: app.isHidden),
                               app.processIdentifier == front ? -1 : 20_000))
            }
        }
        return ranked.sorted { $0.1 < $1.1 }.map { $0.0 }
    }
}

/// 一覧の表示（アイコン＋窓の題名＋アプリ名）。上に検索欄（検索中だけ）、下にキーの案内
final class SwitchView: NSView {
    var onPick: ((Int) -> Void)?
    var onAction: ((Int, SwitchAction) -> Void)?
    private var items: [SwitchItem] = []
    private var selected = 0
    private var first = 0
    private var query: String?                  // nil なら検索していない
    private let rowH: CGFloat = 34
    private let colW: CGFloat = 560
    private let gap: CGFloat = 8
    private let pad: CGFloat = 10
    private let footH: CGFloat = 22
    private var headH: CGFloat { query == nil ? 0 : 34 }
    /// 使ってよい大きさ（画面に合わせて Switcher が決める）
    var limit = NSSize(width: 1200, height: 34 * 14 + 20)

    /// 1 列に入る行数（画面の高さから）
    private var maxRows: Int { max(3, Int((limit.height - pad * 2 - headH - footH) / rowH)) }
    /// 列の数：1 列に入りきらなければ 2 列
    private var cols: Int { items.count > maxRows ? 2 : 1 }
    /// 実際の行数：2 列なら半分ずつ（入りきらなければ maxRows）
    private var rows: Int { cols == 1 ? max(1, items.count) : min(maxRows, (items.count + 1) / 2) }
    private var capacity: Int { rows * cols }
    private var columnWidth: CGFloat { min(colW, (limit.width - pad * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)) }
    private var width: CGFloat { pad * 2 + columnWidth * CGFloat(cols) + gap * CGFloat(cols - 1) }
    /// ←→ で動く量（2 列なら 1 列分）
    var columnStep: Int { cols == 2 ? rows : 1 }

    /// k 番目（表示の中での位置）の四角
    private func cellRect(_ k: Int) -> NSRect {
        let c = k / rows, r = k % rows
        return NSRect(x: pad + CGFloat(c) * (columnWidth + gap), y: pad + headH + CGFloat(r) * rowH, width: columnWidth, height: rowH)
    }

    /// 行の右端の小さなボタン（窓があれば 閉じる・しまう、窓がなければ 終了）
    private func buttons(_ rect: NSRect, _ it: SwitchItem) -> [(SwitchAction, NSRect)] {
        let d: CGFloat = 16, y = rect.midY - d / 2
        if it.window == nil { return [(.quit, NSRect(x: rect.maxX - 10 - d, y: y, width: d, height: d))] }
        return [(.minimize, NSRect(x: rect.maxX - 10 - d * 2 - 8, y: y, width: d, height: d)),
                (.close, NSRect(x: rect.maxX - 10 - d, y: y, width: d, height: d))]
    }

    override var isFlipped: Bool { true }

    /// マウスを乗せている項目（薄く強調し、ボタンを出す）
    private var hover: Int?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    private func slot(at p: NSPoint) -> Int? {
        for k in 0..<capacity where cellRect(k).contains(p) { return first + k < items.count ? k : nil }
        return nil
    }

    override func mouseMoved(with e: NSEvent) {
        let h = slot(at: convert(e.locationInWindow, from: nil)).map { first + $0 }
        if h != hover { hover = h; needsDisplay = true }
    }

    override func mouseExited(with e: NSEvent) {
        if hover != nil { hover = nil; needsDisplay = true }
    }

    func update(items: [SwitchItem], selected: Int, query: String?) {
        if self.items.count != items.count { hover = nil }
        self.items = items
        self.selected = selected
        self.query = query
        // 入りきらないときは、選んでいる位置が見えるように列単位でずらす
        if selected < first { first = (selected / rows) * rows }
        if selected >= first + capacity { first = (selected / rows - cols + 1) * rows }
        first = max(0, min(first, max(0, items.count - capacity)))
        if cols == 2 { first = (first / rows) * rows }
        setFrameSize(fittingSize)
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        NSSize(width: max(width, 420), height: headH + CGFloat(rows) * rowH + pad * 2 + footH)
    }

    override func draw(_ dirty: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.stroke()

        let sub: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]

        // 検索欄
        if let q = query {
            let r = NSRect(x: pad, y: pad, width: bounds.width - pad * 2, height: 28)
            NSColor.textBackgroundColor.setFill()
            NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7).fill()
            NSColor.controlAccentColor.setStroke()
            NSBezierPath(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).stroke()
            if let mag = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) {
                mag.draw(in: NSRect(x: r.minX + 8, y: r.minY + 6, width: 16, height: 16))
            }
            let text = q.isEmpty ? L("switch.searchPlaceholder") : q + "▏"
            let a: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13),
                                                    .foregroundColor: q.isEmpty ? NSColor.placeholderTextColor : NSColor.labelColor]
            (text as NSString).draw(at: NSPoint(x: r.minX + 30, y: r.minY + 6), withAttributes: a)
        }

        if items.isEmpty {
            (L("switch.noMatch") as NSString).draw(at: NSPoint(x: pad + 14, y: pad + headH + 9), withAttributes: sub)
        }

        for k in 0..<capacity {
            let i = first + k
            guard i < items.count else { break }
            let it = items[i]
            let rect = cellRect(k)
            let sel = i == selected
            let hov = i == hover
            if sel {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            } else if hov {
                NSColor.controlAccentColor.withAlphaComponent(0.25).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
                NSColor.controlAccentColor.withAlphaComponent(0.7).setStroke()
                let b = NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                b.lineWidth = 1
                b.stroke()
            }
            if let icon = it.app.icon {
                icon.draw(in: NSRect(x: rect.minX + 8, y: rect.minY + 5, width: 24, height: 24))
            }
            let appName = it.app.localizedName ?? "?"
            var title = it.window == nil ? appName : (it.title.isEmpty ? appName : it.title)
            if it.window == nil { title += " " + L("switch.noWindow") }
            else if it.minimized { title += " " + L("switch.minimized") }
            else if it.hidden { title += " " + L("switch.hidden") }
            let main: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: sel ? .semibold : .regular),
                .foregroundColor: sel ? NSColor.white : NSColor.labelColor,
            ]
            var subRow = sub
            if sel { subRow[.foregroundColor] = NSColor.white.withAlphaComponent(0.85) }
            // マウスを乗せた行は右端にボタンを出すので、その分あける
            let btnW: CGFloat = hov ? (it.window == nil ? 30 : 54) : 0
            let appW: CGFloat = it.window == nil ? 0 : min(130, rect.width * 0.3)
            let titleRect = NSRect(x: rect.minX + 42, y: rect.minY + 8, width: rect.width - 50 - appW - btnW, height: 18)
            if it.app.bundleIdentifier == "com.apple.finder", it.title.hasPrefix("/") {
                // Finder はフォルダ名を目立たせ、その後ろに親の場所を薄く（長ければ頭を省く）
                let path = it.title
                var name = (path as NSString).lastPathComponent
                if it.minimized { name += " " + L("switch.minimized") } else if it.hidden { name += " " + L("switch.hidden") }
                let parent = (((path as NSString).deletingLastPathComponent) as NSString).abbreviatingWithTildeInPath
                let nameW = min((name as NSString).size(withAttributes: main).width + 2, titleRect.width)
                (name as NSString).draw(with: NSRect(x: titleRect.minX, y: titleRect.minY, width: nameW, height: 18),
                                        options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: main)
                let restW = titleRect.width - nameW - 10
                if restW > 40, path != "/" {
                    let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingHead
                    var a = subRow; a[.paragraphStyle] = p
                    (parent as NSString).draw(with: NSRect(x: titleRect.minX + nameW + 10, y: titleRect.minY + 2, width: restW, height: 16),
                                              options: [.usesLineFragmentOrigin], attributes: a)
                }
            } else {
                (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: main)
            }
            if it.window != nil {
                let p = NSMutableParagraphStyle(); p.alignment = .right; p.lineBreakMode = .byTruncatingTail
                var a = subRow; a[.paragraphStyle] = p
                (appName as NSString).draw(with: NSRect(x: rect.maxX - appW - 8 - btnW, y: rect.minY + 10, width: appW, height: 16),
                                           options: [.usesLineFragmentOrigin], attributes: a)
            }
            if hov {
                for (act, r) in buttons(rect, it) {
                    let color: NSColor = act == .minimize ? .systemYellow : .systemRed
                    color.setFill()
                    NSBezierPath(ovalIn: r).fill()
                    let sym = act == .minimize ? "minus" : "xmark"
                    if let img = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                        .withSymbolConfiguration(.init(pointSize: 9, weight: .bold)) {
                        let tinted = NSImage(size: img.size, flipped: false) { b in
                            img.draw(in: b); NSColor.black.withAlphaComponent(0.6).set(); b.fill(using: .sourceAtop); return true
                        }
                        tinted.draw(in: NSRect(x: r.midX - img.size.width / 2, y: r.midY - img.size.height / 2,
                                               width: img.size.width, height: img.size.height))
                    }
                }
            }
        }

        // キーの案内
        let hint = query == nil ? L("switch.hint") : L("switch.hintSearch")
        let p = NSMutableParagraphStyle(); p.alignment = .center; p.lineBreakMode = .byTruncatingTail
        var a = sub; a[.paragraphStyle] = p; a[.font] = NSFont.systemFont(ofSize: 10.5)
        (hint as NSString).draw(with: NSRect(x: pad, y: bounds.height - pad - footH + 5, width: bounds.width - pad * 2, height: 16),
                                options: [.usesLineFragmentOrigin], attributes: a)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let k = slot(at: p) else { return }
        let i = first + k
        for (act, r) in buttons(cellRect(k), items[i]) where r.insetBy(dx: -3, dy: -3).contains(p) {
            onAction?(i, act)
            return
        }
        onPick?(i)
    }
}
