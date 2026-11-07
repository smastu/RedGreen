// RedGreen：窓の赤・緑ボタンの動きを変える常駐アプリ
//  緑ボタン … 全画面ではなく、画面いっぱい（Dock とメニューバーを除く）に広げる。もう一度で元の大きさ。⌥ を押しながらなら標準の動作
//  緑ボタンを左右にドラッグ → 左半分・右半分、上にドラッグ → 画面いっぱい、長押し → 配置メニュー
//  最後の窓を閉じたら（赤ボタンでも ⌘W でも）アプリを終了する。除外リストのアプリは終了しない
//  しばらく使っていないアプリを自動で終了する（窓が 0 なら 10 分、窓があっても 30 分。Mac から離れている間は数えない）
//  メニューバーから、ほかのアプリをまとめて終了
import AppKit
import ApplicationServices

// MARK: - 設定

let supportDir: URL = {
    let d = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/RedGreen")
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
}()
let excludeFile = supportDir.appendingPathComponent("exclude.txt")
let defaultExclude = """
# 最後の窓を閉じても終了させないアプリ（1 行に 1 つ。アプリ名かバンドル ID）。# の行は無視
com.apple.finder
local.shimpei.teamslite
local.matsumoto.LiteDeck
local.matsumoto.ResourceWatch

"""

let keepFile = supportDir.appendingPathComponent("keep_running.txt")
let defaultKeep = """
# 自動終了・「まとめて終了」の対象外にするアプリ（1 行に 1 つ。アプリ名かバンドル ID）。# の行は無視
# exclude.txt に書いたアプリもこの対象外になる
# ターミナル（Claude Code などが動いている）
com.googlecode.iterm2
com.apple.Terminal
com.mitchellh.ghostty
dev.warp.Warp-Stable
net.kovidgoyal.kitty
org.alacritty
com.github.wez.wezterm
# 連絡・通知を受けるアプリ
local.shimpei.slacklite
local.shimpei.teamslite
# 音楽・会議
com.apple.Music
com.spotify.client
us.zoom.xos
com.microsoft.teams2
com.apple.FaceTime

"""

enum Prefs {
    /// 窓が 0 のアプリを自動終了するまでの分（0 ならしない）
    static var idleNoWindow: Int {
        get { UserDefaults.standard.object(forKey: "idleNoWindow") as? Int ?? 10 }
        set { UserDefaults.standard.set(newValue, forKey: "idleNoWindow") }
    }
    /// 窓があるアプリを自動終了するまでの分（0 ならしない）
    static var idleWindow: Int {
        get { UserDefaults.standard.object(forKey: "idleWindow") as? Int ?? 30 }
        set { UserDefaults.standard.set(newValue, forKey: "idleWindow") }
    }
    static func keep() -> Set<String> {
        if !FileManager.default.fileExists(atPath: keepFile.path) {
            try? defaultKeep.write(to: keepFile, atomically: true, encoding: .utf8)
        }
        let t = (try? String(contentsOf: keepFile, encoding: .utf8)) ?? defaultKeep
        return Set(t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }).union(excluded())
    }
    static func matches(_ app: NSRunningApplication, _ set: Set<String>) -> Bool {
        set.contains((app.bundleIdentifier ?? "").lowercased()) || set.contains((app.localizedName ?? "").lowercased())
    }
    static var green: Bool {
        get { UserDefaults.standard.object(forKey: "green") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "green") }
    }
    static var quitLast: Bool {
        get { UserDefaults.standard.object(forKey: "quitLast") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "quitLast") }
    }
    static func excluded() -> Set<String> {
        if !FileManager.default.fileExists(atPath: excludeFile.path) {
            try? defaultExclude.write(to: excludeFile, atomically: true, encoding: .utf8)
        }
        let t = (try? String(contentsOf: excludeFile, encoding: .utf8)) ?? defaultExclude
        return Set(t.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") })
    }
}

/// 動作の記録（~/Library/Logs/RedGreen.log）
func log(_ m: String) {
    let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/RedGreen.log")
    let df = DateFormatter(); df.dateFormat = "MM-dd HH:mm:ss"
    let line = "\(df.string(from: Date())) \(m)\n"
    if let h = try? FileHandle(forWritingTo: f) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
    else { try? line.write(to: f, atomically: true, encoding: .utf8) }
}

// MARK: - アクセシビリティの小道具

func attr<T>(_ e: AXUIElement, _ name: String) -> T? {
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, name as CFString, &v) == .success else { return nil }
    return v as? T
}
func axPoint(_ e: AXUIElement) -> CGPoint? {
    guard let v: AXValue = attr(e, kAXPositionAttribute) else { return nil }
    var p = CGPoint.zero; AXValueGetValue(v, .cgPoint, &p); return p
}
func axSize(_ e: AXUIElement) -> CGSize? {
    guard let v: AXValue = attr(e, kAXSizeAttribute) else { return nil }
    var s = CGSize.zero; AXValueGetValue(v, .cgSize, &s); return s
}
func setFrame(_ w: AXUIElement, _ r: CGRect) {
    var p = r.origin, s = r.size
    let pv = AXValueCreate(.cgPoint, &p)!, sv = AXValueCreate(.cgSize, &s)!
    // 位置 → 大きさ → 位置（画面の端で大きさが削られないように）
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
}

/// 画面の使える範囲を、アクセシビリティの座標（左上が原点、下向きが正）で返す
func visibleAXFrame(containing pt: CGPoint) -> CGRect {
    let primaryH = NSScreen.screens.first?.frame.height ?? 0
    func toAX(_ r: NSRect) -> CGRect { CGRect(x: r.minX, y: primaryH - r.maxY, width: r.width, height: r.height) }
    let screen = NSScreen.screens.first { toAX($0.frame).contains(pt) } ?? NSScreen.main ?? NSScreen.screens[0]
    return toAX(screen.visibleFrame)
}

// MARK: - 緑ボタン

enum Layout { case fill, left, right }

/// RedGreen が動かす前の大きさ（同じ配置をもう一度選んだら戻す）
var savedFrames: [(win: AXUIElement, frame: CGRect, after: CGRect, layout: Layout)] = []

func approx(_ a: CGRect, _ b: CGRect) -> Bool {
    abs(a.minX - b.minX) < 8 && abs(a.minY - b.minY) < 8 && abs(a.width - b.width) < 8 && abs(a.height - b.height) < 8
}

func currentFrame(_ w: AXUIElement) -> CGRect? {
    guard let p = axPoint(w), let s = axSize(w) else { return nil }
    return CGRect(origin: p, size: s)
}

/// RedGreen が動かしたままの窓なら、動かす前の大きさ
func originalFrame(_ w: AXUIElement) -> CGRect? {
    guard let cur = currentFrame(w), let e = savedFrames.first(where: { CFEqual($0.win, w) }), approx(cur, e.after) else { return nil }
    return e.frame
}

func place(_ w: AXUIElement, _ layout: Layout) {
    guard let cur = currentFrame(w) else { return }
    savedFrames.removeAll { (attr($0.win, kAXRoleAttribute) as String?) == nil }   // 消えた窓は忘れる
    var original = cur
    if let i = savedFrames.firstIndex(where: { CFEqual($0.win, w) }) {
        if approx(cur, savedFrames[i].after) {
            original = savedFrames[i].frame
            if savedFrames[i].layout == layout {                 // 同じ配置をもう一度 → 元に戻す
                setFrame(w, original)
                savedFrames.remove(at: i)
                return
            }
        }
        savedFrames.remove(at: i)
    }
    let v = visibleAXFrame(containing: CGPoint(x: cur.midX, y: cur.midY))
    let half = (v.width / 2).rounded()
    let target: CGRect
    switch layout {
    case .fill: target = v
    case .left: target = CGRect(x: v.minX, y: v.minY, width: half, height: v.height)
    case .right: target = CGRect(x: v.minX + half, y: v.minY, width: v.width - half, height: v.height)
    }
    setFrame(w, target)
    savedFrames.append((w, original, currentFrame(w) ?? target, layout))
}

func restore(_ w: AXUIElement) {
    guard let f = originalFrame(w) else { return }
    setFrame(w, f)
    savedFrames.removeAll { CFEqual($0.win, w) }
}

func fill(window w: AXUIElement) { place(w, .fill) }

/// 緑ボタンを押してから離すまで
var greenDown: (win: AXUIElement, loc: CGPoint, time: Date)?

func greenReleased(_ g: (win: AXUIElement, loc: CGPoint, time: Date), at up: CGPoint) {
    let dx = up.x - g.loc.x, dy = up.y - g.loc.y
    if abs(dx) > 30, abs(dx) > abs(dy) { place(g.win, dx < 0 ? .left : .right); return }
    if dy < -30 { place(g.win, .fill); return }
    if Date().timeIntervalSince(g.time) > 0.45 { showLayoutMenu(g.win); return }
    place(g.win, .fill)
}

/// 長押しで出す配置メニュー
final class MenuAction: NSObject {
    let f: () -> Void
    init(_ f: @escaping () -> Void) { self.f = f }
    @objc func run() { f() }
}
var menuActions: [MenuAction] = []

func addItem(_ m: NSMenu, _ title: String, _ f: @escaping () -> Void) {
    let a = MenuAction(f)
    menuActions.append(a)
    let it = m.addItem(withTitle: title, action: #selector(MenuAction.run), keyEquivalent: "")
    it.target = a
}

func showLayoutMenu(_ w: AXUIElement) {
    menuActions.removeAll()
    let m = NSMenu()
    addItem(m, "左半分") { place(w, .left) }
    addItem(m, "右半分") { place(w, .right) }
    addItem(m, "画面いっぱい") { place(w, .fill) }
    if originalFrame(w) != nil {
        m.addItem(.separator())
        addItem(m, "元の大きさに戻す") { restore(w) }
    }
    m.addItem(.separator())
    addItem(m, "全画面（macOS 標準）") {
        AXUIElementSetAttributeValue(w, "AXFullScreen" as CFString, kCFBooleanTrue)
    }
    m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

let systemWide = AXUIElementCreateSystemWide()
var swallowUp = false
var tap: CFMachPort?

/// アプリの普通の窓（最小化中も含む）の数
func standardWindowCount(_ pid: pid_t) -> Int {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
    return ws.filter { (attr($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }.count
}

var pendingQuit = Set<pid_t>()

/// 窓を閉じる操作のあと、そのアプリの窓が 0 になっていたら終了（保存の確認などで遅れることがあるので数回確かめる）
func checkQuit(pid: pid_t, before: Int, why: String) {
    guard Prefs.quitLast, before > 0, pid != getpid(), !pendingQuit.contains(pid),
          let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular else { return }
    let ex = Prefs.excluded()
    if ex.contains((app.bundleIdentifier ?? "").lowercased()) || ex.contains((app.localizedName ?? "").lowercased()) { return }
    pendingQuit.insert(pid)
    var tries = [0.7, 2.0, 5.0]
    func step() {
        guard !tries.isEmpty else { pendingQuit.remove(pid); return }
        let d = tries.removeFirst()
        DispatchQueue.main.asyncAfter(deadline: .now() + d) {
            guard !app.isTerminated else { pendingQuit.remove(pid); return }
            let n = standardWindowCount(pid)
            if n == 0 {
                log("\(why)：\(app.localizedName ?? "?") の窓が 0 → 終了 \(app.terminate())")
                pendingQuit.remove(pid)
            } else { step() }
        }
    }
    step()
}

/// クリックとキーを見張る：緑ボタンは横取りして「画面いっぱい」、赤ボタンと ⌘W は閉じたあとの窓の数を確かめる
let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseUp && swallowUp {
        swallowUp = false
        if let g = greenDown {
            greenDown = nil
            let up = event.location
            DispatchQueue.main.async { greenReleased(g, at: up) }
        }
        return nil
    }
    if type == .keyDown {
        let f = event.flags
        if f.contains(.maskCommand), !f.contains(.maskControl), !f.contains(.maskAlternate),
           event.getIntegerValueField(.keyboardEventKeycode) == 13,                // W
           let front = NSWorkspace.shared.frontmostApplication {
            let pid = front.processIdentifier
            let before = Prefs.quitLast ? standardWindowCount(pid) : 0
            DispatchQueue.main.async { checkQuit(pid: pid, before: before, why: "⌘W") }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }
    let loc = event.location
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(loc.x), Float(loc.y), &el) == .success, let e = el,
          (attr(e, kAXRoleAttribute) as String?) == kAXButtonRole,
          let sub: String = attr(e, kAXSubroleAttribute) else {
        return Unmanaged.passUnretained(event)
    }
    if sub == kAXCloseButtonSubrole {
        var pid: pid_t = 0
        if Prefs.quitLast, AXUIElementGetPid(e, &pid) == .success {
            let before = standardWindowCount(pid)
            DispatchQueue.main.async { checkQuit(pid: pid, before: before, why: "赤ボタン") }
        }
        return Unmanaged.passUnretained(event)
    }
    guard Prefs.green, !event.flags.contains(.maskAlternate),
          sub == kAXFullScreenButtonSubrole || sub == kAXZoomButtonSubrole,
          let win: AXUIElement = attr(e, kAXWindowAttribute) else {
        return Unmanaged.passUnretained(event)
    }
    swallowUp = true
    greenDown = (win, loc, Date())       // 離したときに、クリック・ドラッグ・長押しを見分ける
    return nil
}

// MARK: - 使っていないアプリの自動終了

/// 「使っていない時間」は、Mac を使っている間（最後の操作から 2 分以内）だけ 1 分ずつ数える。
/// 前面に来たら 0 に戻す。離席中に全部終了してしまうことはない
final class IdleWatcher {
    var inactive: [pid_t: Int] = [:]
    var recent: [String] = []          // 最近自動終了したアプリ（メニューに出す）

    init() {
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.inactive[a.processIdentifier] = 0
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.inactive[a.processIdentifier] = nil
            }
        }
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.tick() }
    }

    func tick() {
        guard Prefs.idleNoWindow > 0 || Prefs.idleWindow > 0 else { return }
        let userIdle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
        guard userIdle < 120 else { return }          // 離席中は数えない
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let keep = Prefs.keep()
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            let pid = app.processIdentifier
            guard pid != getpid(), pid != front, !app.isTerminated, !Prefs.matches(app, keep) else { continue }
            let n = (inactive[pid] ?? 0) + 1
            inactive[pid] = n
            let limit = standardWindowCount(pid) == 0 ? Prefs.idleNoWindow : Prefs.idleWindow
            guard limit > 0, n >= limit else { continue }
            let name = app.localizedName ?? "?"
            log("自動終了：\(name)（\(n) 分使っていない）\(app.terminate())")
            inactive[pid] = 0              // 保存の確認などで終わらなかったら、また同じ時間待つ
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            recent.insert("\(df.string(from: Date())) \(name)", at: 0)
            recent = Array(recent.prefix(5))
        }
    }
}

/// まとめて終了の対象（自分・前面のアプリも含め、対象外リスト以外の普通のアプリ）
func quittableApps() -> [NSRunningApplication] {
    let keep = Prefs.keep()
    return NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && $0.processIdentifier != getpid() && !Prefs.matches($0, keep)
    }.sorted { ($0.localizedName ?? "") < ($1.localizedName ?? "") }
}

// MARK: - 本体

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var started = false
    var idle: IdleWatcher?

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "RedGreen")
        let m = NSMenu(); m.delegate = self; status.menu = m
        if UserDefaults.standard.object(forKey: "loginSet") == nil {
            setLogin(true); UserDefaults.standard.set(true, forKey: "loginSet")
        }
        // アクセシビリティの許可を待ってから始める（許可されるまで 2 秒ごとに確認）
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        log("起動 許可=\(AXIsProcessTrusted())")
        if AXIsProcessTrustedWithOptions(opts) { startAll() }
        else {
            Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                if AXIsProcessTrusted() { t.invalidate(); self?.startAll() }
            }
        }
    }

    func startAll() {
        guard !started else { return }
        started = true
        log("開始（許可あり）")
        idle = IdleWatcher()
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.keyDown.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil)
        if let t = tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        }
        AXUIElementSetMessagingTimeout(systemWide, 0.3)
    }

    // メニュー
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if !AXIsProcessTrusted() {
            m.addItem(withTitle: "⚠︎ アクセシビリティの許可が必要です…", action: #selector(openAX), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        let g = m.addItem(withTitle: "緑ボタンで画面いっぱい・左右半分（⌥ で標準）", action: #selector(toggleGreen), keyEquivalent: "")
        g.target = self; g.state = Prefs.green ? .on : .off
        let q = m.addItem(withTitle: "最後の窓を閉じたらアプリを終了", action: #selector(toggleQuit), keyEquivalent: "")
        q.target = self; q.state = Prefs.quitLast ? .on : .off
        m.addItem(withTitle: "終了させないアプリを編集…", action: #selector(editExclude), keyEquivalent: "").target = self
        m.addItem(.separator())

        // 自動終了
        let auto = NSMenu()
        func minutesMenu(_ title: String, _ cur: Int, _ set: @escaping (Int) -> Void) {
            let sub = NSMenu()
            for v in [0, 5, 10, 15, 30, 60, 120] {
                let it = NSMenuItem(title: v == 0 ? "しない" : "\(v) 分", action: #selector(MenuAction.run), keyEquivalent: "")
                let a = MenuAction { set(v) }
                self.minuteActions.append(a)
                it.target = a
                it.state = v == cur ? .on : .off
                sub.addItem(it)
            }
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = sub
            auto.addItem(item)
        }
        minuteActions.removeAll()
        minutesMenu("窓がないアプリ：\(label(Prefs.idleNoWindow))", Prefs.idleNoWindow) { Prefs.idleNoWindow = $0 }
        minutesMenu("窓があるアプリ：\(label(Prefs.idleWindow))", Prefs.idleWindow) { Prefs.idleWindow = $0 }
        auto.addItem(.separator())
        auto.addItem(withTitle: "対象外のアプリを編集…", action: #selector(editKeep), keyEquivalent: "").target = self
        if let r = idle?.recent, !r.isEmpty {
            auto.addItem(.separator())
            auto.addItem(withTitle: "最近自動終了したアプリ", action: nil, keyEquivalent: "")
            for x in r { auto.addItem(withTitle: "  " + x, action: nil, keyEquivalent: "") }
        }
        let autoItem = m.addItem(withTitle: "使っていないアプリを自動で終了", action: nil, keyEquivalent: "")
        autoItem.submenu = auto

        // まとめて終了
        let apps = quittableApps()
        let quit = NSMenu()
        let all = quit.addItem(withTitle: "すべて終了（\(apps.count) 個）", action: #selector(quitAll), keyEquivalent: "")
        all.target = self
        all.isEnabled = !apps.isEmpty
        quit.addItem(.separator())
        for a in apps {
            let it = NSMenuItem(title: a.localizedName ?? "?", action: #selector(MenuAction.run), keyEquivalent: "")
            let act = MenuAction { log("メニューから終了：\(a.localizedName ?? "?") \(a.terminate())") }
            minuteActions.append(act)
            it.target = act
            it.image = a.icon.map { i in let c = i.copy() as! NSImage; c.size = NSSize(width: 16, height: 16); return c }
            quit.addItem(it)
        }
        quit.addItem(.separator())
        quit.addItem(withTitle: "対象外：ターミナル・連絡アプリなど（編集…）", action: #selector(editKeep), keyEquivalent: "").target = self
        let quitItem = m.addItem(withTitle: "アプリをまとめて終了", action: nil, keyEquivalent: "")
        quitItem.submenu = quit
        m.addItem(.separator())
        let l = m.addItem(withTitle: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
        l.target = self; l.state = loginOn ? .on : .off
        m.addItem(withTitle: "RedGreen を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    var minuteActions: [MenuAction] = []
    func label(_ v: Int) -> String { v == 0 ? "しない" : "\(v) 分" }
    @objc func quitAll() {
        for a in quittableApps() { log("まとめて終了：\(a.localizedName ?? "?") \(a.terminate())") }
    }
    @objc func editKeep() {
        _ = Prefs.keep()
        NSWorkspace.shared.open([keepFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func toggleGreen() { Prefs.green.toggle() }
    @objc func toggleQuit() { Prefs.quitLast.toggle() }
    @objc func editExclude() {
        _ = Prefs.excluded()
        NSWorkspace.shared.open([excludeFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func openAX() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // ログイン時の起動（LaunchAgent）
    let agent = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/local.matsumoto.RedGreen.plist")
    var loginOn: Bool { FileManager.default.fileExists(atPath: agent.path) }
    @objc func toggleLogin() { setLogin(!loginOn) }
    func setLogin(_ on: Bool) {
        if on {
            let plist: [String: Any] = ["Label": "local.matsumoto.RedGreen",
                                        "ProgramArguments": ["/usr/bin/open", "-a", Bundle.main.bundlePath],
                                        "RunAtLoad": true]
            try? FileManager.default.createDirectory(at: agent.deletingLastPathComponent(), withIntermediateDirectories: true)
            (plist as NSDictionary).write(to: agent, atomically: true)
        } else {
            try? FileManager.default.removeItem(at: agent)
        }
    }
}

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let d = App()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        app.run()
    }
}
