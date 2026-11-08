// ⌘Tab を Windows の Alt+Tab 風に：アプリ単位ではなく窓単位で切り替える（最小化・非表示の窓も選べる）
//  ⌘ を押したまま Tab で次、⇧Tab・矢印で前後、離すと切り替え、Esc で取り消し、クリックでも選べる
//  すぐ離せば一覧は出さずに直前の窓へ
import AppKit
import ApplicationServices

// macOS 標準の ⌘Tab を止める／戻す（非公開 API。AltTab なども使っている）
@_silgen_name("CGSSetSymbolicHotKeyEnabled")
func CGSSetSymbolicHotKeyEnabled(_ hotKey: Int32, _ enabled: Bool) -> Int32
// AX の窓 → CGWindowID（非公開 API）
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ id: UnsafeMutablePointer<CGWindowID>) -> AXError

struct SwitchItem {
    let app: NSRunningApplication
    let window: AXUIElement?
    let title: String
    let minimized: Bool
    let hidden: Bool
}

final class Switcher {
    static let shared = Switcher()

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "switcher") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "switcher"); shared.applySystemHotKeys() }
    }

    private(set) var active = false
    var items: [SwitchItem] = []
    var index = 0
    private let panel: NSPanel
    private let view: SwitchView

    private init() {
        view = SwitchView()
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.contentView = view
        view.onPick = { [weak self] i in self?.index = i; self?.confirm() }
    }

    /// 標準の ⌘Tab / ⇧⌘Tab を、この機能がオンで許可があるときだけ止める
    func applySystemHotKeys() {
        let off = Switcher.enabled && AXIsProcessTrusted()
        _ = CGSSetSymbolicHotKeyEnabled(1, !off)   // ⌘Tab
        _ = CGSSetSymbolicHotKeyEnabled(2, !off)   // ⇧⌘Tab
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
            if active && !flags.contains(.maskCommand) {
                DispatchQueue.main.async { self.confirm() }
            }
            return false
        }
        guard type == .keyDown else { return false }
        let key = e.getIntegerValueField(.keyboardEventKeycode)
        if !active {
            guard key == 48, flags.contains(.maskCommand),
                  !flags.contains(.maskControl), !flags.contains(.maskAlternate) else { return false }
            begin(backward: flags.contains(.maskShift))
            return true
        }
        switch key {
        case 48: move(flags.contains(.maskShift) ? -1 : 1)     // Tab
        case 126: move(-1)                                      // ↑
        case 125: move(1)                                       // ↓
        case 123: move(-view.columnStep)                        // ←（2 列なら隣の列へ）
        case 124: move(view.columnStep)                         // →
        case 53: cancel()                                       // Esc
        case 36, 76: DispatchQueue.main.async { self.confirm() } // Return
        default: break
        }
        return true
    }

    private func begin(backward: Bool) {
        items = collect()
        guard !items.isEmpty else { return }
        index = items.count > 1 ? (backward ? items.count - 1 : 1) : 0
        active = true
        // すぐ離したときは一覧を出さない（ちらつき防止）
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, self.active else { return }
            self.show()
        }
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        if abs(d) > 1 {   // 列の移動は端で止める（一周させない）
            index = max(0, min(items.count - 1, index + d))
            if panel.isVisible { view.update(items: items, selected: index) }
            return
        }
        index = (index + d + items.count) % items.count
        if panel.isVisible { view.update(items: items, selected: index) }
    }

    private func cancel() {
        active = false
        panel.orderOut(nil)
    }

    func confirm() {
        guard active else { return }
        active = false
        panel.orderOut(nil)
        guard items.indices.contains(index) else { return }
        let it = items[index]
        if it.app.isHidden { it.app.unhide() }
        if let w = it.window {
            if it.minimized { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse) }
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(w, kAXMainAttribute as CFString, kCFBooleanTrue)
        }
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
        view.update(items: items, selected: index)
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
        var ranked: [(SwitchItem, Int)] = []
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular && app.processIdentifier != getpid() && !app.isTerminated {
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

/// 一覧の表示（アイコン＋窓の題名＋アプリ名）
final class SwitchView: NSView {
    var onPick: ((Int) -> Void)?
    private var items: [SwitchItem] = []
    private var selected = 0
    private var first = 0
    private let rowH: CGFloat = 34
    private let colW: CGFloat = 560
    private let gap: CGFloat = 8
    private let pad: CGFloat = 10
    /// 使ってよい大きさ（画面に合わせて Switcher が決める）
    var limit = NSSize(width: 1200, height: 34 * 14 + 20)

    /// 1 列に入る行数（画面の高さから）
    private var maxRows: Int { max(3, Int((limit.height - pad * 2) / rowH)) }
    /// 列の数：1 列に入りきらなければ 2 列
    private var cols: Int { items.count > maxRows ? 2 : 1 }
    /// 実際の行数：2 列なら半分ずつ（入りきらなければ maxRows）
    private var rows: Int { cols == 1 ? max(1, items.count) : min(maxRows, (items.count + 1) / 2) }
    private var capacity: Int { rows * cols }
    private var columnWidth: CGFloat { min(colW, (limit.width - pad * 2 - gap * CGFloat(cols - 1)) / CGFloat(cols)) }
    private var width: CGFloat { pad * 2 + columnWidth * CGFloat(cols) + gap * CGFloat(cols - 1) }
    /// ←→ で動く量（2 列なら 1 列分）
    var columnStep: Int { cols == 2 ? rows : 1 }

    /// i 番目（表示の中での位置）の四角
    private func cellRect(_ k: Int) -> NSRect {
        let c = k / rows, r = k % rows
        return NSRect(x: pad + CGFloat(c) * (columnWidth + gap), y: pad + CGFloat(r) * rowH, width: columnWidth, height: rowH)
    }

    override var isFlipped: Bool { true }

    func update(items: [SwitchItem], selected: Int) {
        self.items = items
        self.selected = selected
        // 入りきらないときは、選んでいる位置が見えるように列単位でずらす
        if selected < first { first = (selected / rows) * rows }
        if selected >= first + capacity { first = (selected / rows - cols + 1) * rows }
        first = max(0, min(first, max(0, items.count - capacity)))
        if cols == 2 { first = (first / rows) * rows }
        setFrameSize(fittingSize)
        needsDisplay = true
    }

    override var fittingSize: NSSize {
        NSSize(width: width, height: CGFloat(rows) * rowH + pad * 2)
    }

    override func draw(_ dirty: NSRect) {
        let bg = NSBezierPath(roundedRect: bounds, xRadius: 14, yRadius: 14)
        NSColor.windowBackgroundColor.withAlphaComponent(0.96).setFill()
        bg.fill()
        NSColor.separatorColor.setStroke()
        bg.stroke()

        for k in 0..<capacity {
            let i = first + k
            guard i < items.count else { break }
            let it = items[i]
            let rect = cellRect(k)
            if i == selected {
                NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 8, yRadius: 8).fill()
            }
            if let icon = it.app.icon {
                icon.draw(in: NSRect(x: rect.minX + 8, y: rect.minY + 5, width: 24, height: 24))
            }
            let appName = it.app.localizedName ?? "?"
            var title = it.window == nil ? appName : (it.title.isEmpty ? appName : it.title)
            if it.window == nil { title += " " + L("switch.noWindow") }
            else if it.minimized { title += " " + L("switch.minimized") }
            else if it.hidden { title += " " + L("switch.hidden") }
            let sel = i == selected
            let main: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: sel ? .semibold : .regular),
                .foregroundColor: sel ? NSColor.white : NSColor.labelColor,
            ]
            let sub: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11),
                .foregroundColor: sel ? NSColor.white.withAlphaComponent(0.85) : NSColor.secondaryLabelColor,
            ]
            let appW: CGFloat = it.window == nil ? 0 : min(130, rect.width * 0.3)
            let titleRect = NSRect(x: rect.minX + 42, y: rect.minY + 8, width: rect.width - 50 - appW, height: 18)
            (title as NSString).draw(with: titleRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: main)
            if it.window != nil {
                let p = NSMutableParagraphStyle(); p.alignment = .right; p.lineBreakMode = .byTruncatingTail
                var a = sub; a[.paragraphStyle] = p
                (appName as NSString).draw(with: NSRect(x: rect.maxX - appW - 8, y: rect.minY + 10, width: appW, height: 16),
                                           options: [.usesLineFragmentOrigin], attributes: a)
            }
        }
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        for k in 0..<capacity where cellRect(k).contains(p) {
            if first + k < items.count { onPick?(first + k) }
            return
        }
    }
}
