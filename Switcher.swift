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
    private var panel: NSPanel?
    private var teardownWork: DispatchWorkItem?
    private var view = SwitchView()

    private init() {}

    /// 一覧の窓は出すときに作り、閉じたら捨てる（描画用のメモリ 10MB 以上を持ち続けないため）
    private func ensurePanel() -> NSPanel {
        if let p = panel { return p }
        let v = SwitchView()
        if SwitchView.cpuDraw { v.wantsLayer = true; v.layerContentsRedrawPolicy = .onSetNeedsDisplay }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 560, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        p.level = .popUpMenu
        p.acceptsMouseMovedEvents = true
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        p.contentView = v
        if ProcessInfo.processInfo.environment["RG_SYNC_DRAW"] != nil {
            v.wantsLayer = true
            v.layer?.drawsAsynchronously = false
            v.canDrawConcurrently = false
            p.contentView?.superview?.wantsLayer = true
            p.contentView?.superview?.layer?.drawsAsynchronously = false
        }
        v.onPick = { [weak self] i in self?.index = i; self?.confirm() }
        v.onAction = { [weak self] i, a in self?.index = i; self?.act(a) }
        panel = p; view = v
        return p
    }

    private func hidePanel() {
        panel?.orderOut(nil)
        teardownWork?.cancel()
        let w = DispatchWorkItem { [weak self] in
            guard let self, !self.active, let p = self.panel,
                  ProcessInfo.processInfo.environment["RG_KEEP_PANEL"] == nil else { return }
            p.contentView = nil
            p.close()
            self.panel = nil
            self.view = SwitchView()
            self.all = []; self.items = []
            malloc_zone_pressure_relief(nil, 0)       // 空いた分を OS に返す
        }
        teardownWork = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)   // 続けて ⌘Tab したときは作り直さない
    }

    /// 標準の ⌘Tab / ⇧⌘Tab を、この機能がオンで許可があるときだけ止める
    func applySystemHotKeys() {
        // セキュア入力（パスワード欄・リモートデスクトップなど）の間はキーが見えないので、標準の ⌘Tab に任せる
        let off = Switcher.enabled && AXIsProcessTrusted() && (!IsSecureEventInputEnabled() || !hotKeyRefs.isEmpty)
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
            if on { self.registerHotKeys() } else { self.unregisterHotKeys() }
            log(on ? (self.hotKeyRefs.isEmpty ? L("log.secureOn") : L("log.secureOnHotKey")) : L("log.secureOff"))
            self.applySystemHotKeys()
        }
    }

    // MARK: セキュア入力の間はショートカットキーとして ⌘Tab を受け取る（キーはイベントタップに届かないが、⌘ を離したのは届く）
    fileprivate var hotKeyRefs: [EventHotKeyRef] = []
    private var hotKeyHandler: EventHandlerRef?

    private func registerHotKeys() {
        guard Switcher.enabled, hotKeyRefs.isEmpty else { return }
        if hotKeyHandler == nil {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, ev, _ in
                var hk = EventHotKeyID()
                GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &hk)
                DispatchQueue.main.async { Switcher.shared.hotKeyPressed(hk.id) }
                return noErr
            }, 1, &spec, nil, &hotKeyHandler)
        }
        let sig = OSType(0x52_47_53_57)   // 'RGSW'
        for (id, mods) in [(UInt32(1), cmdKey), (UInt32(2), cmdKey | shiftKey), (UInt32(3), cmdKey), (UInt32(4), cmdKey | shiftKey)] {
            var ref: EventHotKeyRef?
            let key = id <= 2 ? UInt32(kVK_Tab) : UInt32(kVK_ANSI_Grave)
            if RegisterEventHotKey(key, UInt32(mods), EventHotKeyID(signature: sig, id: id), GetApplicationEventTarget(), 0, &ref) == noErr,
               let ref { hotKeyRefs.append(ref) }
        }
    }

    private func unregisterHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs.removeAll()
    }

    /// 1: ⌘Tab 2: ⇧⌘Tab 3: ⌘` 4: ⇧⌘`
    fileprivate func hotKeyPressed(_ id: UInt32) {
        let back = id == 2 || id == 4
        if active { move(back ? -1 : 1) } else { begin(backward: back, sameApp: id >= 3) }
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

    /// 調査用（RG_DEBUG=1 で起動したときだけ）：一覧を出して消すのを n 回くり返し、メモリを記録する
    var debugMoves = Int(ProcessInfo.processInfo.environment["RG_DEBUG_MOVES"] ?? "") ?? 0
    func debugCycle(_ n: Int, gap: Double) {
        guard n > 0 else { return }
        begin(backward: false, sameApp: false)
        // 実際の使い方に合わせ、出したまま選択を何度も動かす（描き直しを起こす）
        for k in 0..<debugMoves {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3 + Double(k) * 0.08) { [weak self] in self?.move(1) }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6 + Double(debugMoves) * 0.08) { [weak self] in
            self?.cancel()
            DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
                log(String(format: "debug cycle 残り%d %.1fMB", n - 1, Recycler.footprintMB()))
                self?.debugCycle(n - 1, gap: gap)
            }
        }
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
        if panel?.isVisible == true || searching { show() }
    }

    private func move(_ d: Int) {
        guard !items.isEmpty else { return }
        if abs(d) > 1 {   // 列の移動は端で止める（一周させない）
            index = max(0, min(items.count - 1, index + d))
        } else {
            index = (index + d + items.count) % items.count
        }
        if panel?.isVisible == true { view.update(items: items, selected: index, query: searching ? query : nil) }
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
        hidePanel()
    }

    func confirm() {
        guard active else { return }
        active = false
        searching = false
        hidePanel()
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
        memMark("⌘Tab の一覧")
        let p = ensurePanel()
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
        var x = f.midX - size.width / 2
        if ProcessInfo.processInfo.environment["RG_DEBUG_OFFSCREEN"] != nil { x = -20000 }   // 調査用：見えない所に出す
        p.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        p.orderFrontRegardless()
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

    /// 描画は自前の CPU のビットマップに描いて層に貼るだけにする。
    /// AppKit 任せだと、選択を動かして描き直しが続くと Core Animation が GPU（Metal）での描画に切り替え、
    /// その準備で一時的に 60MB 前後を使い、閉じたあとも 10MB ほど戻らなかった（2026-11-09 の計測）
    static let cpuDraw = ProcessInfo.processInfo.environment["RG_APPKIT_DRAW"] == nil
    override var wantsUpdateLayer: Bool { SwitchView.cpuDraw }
    override func updateLayer() {
        guard let layer else { return }
        let scale = window?.backingScaleFactor ?? 2
        let w = Int(ceil(bounds.width * scale)), h = Int(ceil(bounds.height * scale))
        guard w > 0, h > 0 else { return }
        // 絵の置き場は OS から直接借りる（mmap）。malloc に任せると、捨てた後も「空き」として抱えたまま返さなかった
        let bpr = w * 4, size = bpr * h
        // 画面と同じ色の決まりで描く（違うと表示の前に同じ大きさの複製が作られる）
        let cs = window?.screen?.colorSpace?.cgColorSpace ?? NSScreen.main?.colorSpace?.cgColorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let mem = mmap(nil, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0), mem != MAP_FAILED,
              let ctx = CGContext(data: mem, width: w, height: h, bitsPerComponent: 8, bytesPerRow: bpr,
                                  space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return }
        // 上が原点（isFlipped）に合わせる
        ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: scale, y: -scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: true)
        effectiveAppearance.performAsCurrentDrawingAppearance { self.draw(self.bounds) }
        NSGraphicsContext.restoreGraphicsState()
        // 絵は同じ置き場をそのまま使い、絵が要らなくなったら munmap で OS に返す
        guard let provider = CGDataProvider(dataInfo: nil, data: mem, size: size, releaseData: { _, p, n in
                  munmap(UnsafeMutableRawPointer(mutating: p), n) }),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bpr,
                                space: cs,
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { munmap(mem, size); return }
        layer.contentsScale = scale
        layer.contents = img
    }

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
