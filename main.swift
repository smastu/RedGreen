// RedGreen：窓の赤・緑ボタンの動きを変える常駐アプリ
//  緑ボタン … 全画面ではなく、画面いっぱい（Dock とメニューバーを除く）に広げる。もう一度で元の大きさ。⌥ を押しながらなら標準の動作
//  最後の窓を閉じたら（赤ボタンでも ⌘W でも）アプリを終了する。除外リストのアプリは終了しない
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

enum Prefs {
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

/// 広げる前の大きさ（もう一度押したら戻す）
var savedFrames: [(win: AXUIElement, frame: CGRect, filled: CGRect)] = []

func fill(window w: AXUIElement) {
    guard let p = axPoint(w), let s = axSize(w) else { return }
    let cur = CGRect(origin: p, size: s)
    let target = visibleAXFrame(containing: CGPoint(x: cur.midX, y: cur.midY))
    savedFrames.removeAll { (attr($0.win, kAXRoleAttribute) as String?) == nil }   // 消えた窓は忘れる
    if let i = savedFrames.firstIndex(where: { CFEqual($0.win, w) }),
       abs(cur.minX - savedFrames[i].filled.minX) < 8, abs(cur.minY - savedFrames[i].filled.minY) < 8,
       abs(cur.width - savedFrames[i].filled.width) < 8, abs(cur.height - savedFrames[i].filled.height) < 8 {
        setFrame(w, savedFrames[i].frame)            // 広げたままなら元に戻す
        savedFrames.remove(at: i)
        return
    }
    savedFrames.removeAll { CFEqual($0.win, w) }
    setFrame(w, target)
    let after = CGRect(origin: axPoint(w) ?? target.origin, size: axSize(w) ?? target.size)
    savedFrames.append((w, cur, after))
}

let systemWide = AXUIElementCreateSystemWide()
var swallowUp = false
var tap: CFMachPort?

/// マウスのクリックを見張り、緑ボタンなら横取りして「画面いっぱい」にする
let tapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if type == .leftMouseUp && swallowUp { swallowUp = false; return nil }
    guard type == .leftMouseDown, Prefs.green, !event.flags.contains(.maskAlternate) else {
        return Unmanaged.passUnretained(event)
    }
    let loc = event.location
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(loc.x), Float(loc.y), &el) == .success, let e = el,
          (attr(e, kAXRoleAttribute) as String?) == kAXButtonRole,
          let sub: String = attr(e, kAXSubroleAttribute),
          sub == kAXFullScreenButtonSubrole || sub == kAXZoomButtonSubrole,
          let win: AXUIElement = attr(e, kAXWindowAttribute) else {
        return Unmanaged.passUnretained(event)
    }
    swallowUp = true
    DispatchQueue.main.async { fill(window: win) }
    return nil
}

// MARK: - 最後の窓を閉じたら終了

final class AppWatch {
    let app: NSRunningApplication
    let ax: AXUIElement
    var observer: AXObserver?
    var hadWindow = false
    init(_ a: NSRunningApplication) { app = a; ax = AXUIElementCreateApplication(a.processIdentifier) }

    func standardWindows() -> [AXUIElement] {
        let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
        return ws.filter { (attr($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole }
    }

    func watch(window w: AXUIElement) {
        guard let o = observer else { return }
        AXObserverAddNotification(o, w, kAXUIElementDestroyedNotification as CFString,
                                  Unmanaged.passUnretained(self).toOpaque())
        if (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole { hadWindow = true }
    }

    func start() {
        var o: AXObserver?
        guard AXObserverCreate(app.processIdentifier, axCallback, &o) == .success, let o = o else { return }
        observer = o
        AXObserverAddNotification(o, ax, kAXWindowCreatedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
        ws.forEach { watch(window: $0) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
    }

    func stop() {
        if let o = observer { CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode) }
        observer = nil
    }

    /// 窓が閉じた：少し待って、普通の窓が 1 つも残っていなければ終了
    func windowClosed() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [self] in
            guard Prefs.quitLast, hadWindow, !app.isTerminated, standardWindows().isEmpty else { return }
            let ex = Prefs.excluded()
            if ex.contains((app.bundleIdentifier ?? "").lowercased()) || ex.contains((app.localizedName ?? "").lowercased()) { return }
            app.terminate()
        }
    }
}

let axCallback: AXObserverCallback = { _, element, note, refcon in
    guard let refcon = refcon else { return }
    let w = Unmanaged<AppWatch>.fromOpaque(refcon).takeUnretainedValue()
    if (note as String) == kAXWindowCreatedNotification { w.watch(window: element) }
    else if (note as String) == kAXUIElementDestroyedNotification { w.windowClosed() }
}

// MARK: - 本体

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
    var watches: [pid_t: AppWatch] = [:]
    var started = false

    func applicationDidFinishLaunching(_ n: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: "RedGreen")
        let m = NSMenu(); m.delegate = self; status.menu = m
        if UserDefaults.standard.object(forKey: "loginSet") == nil {
            setLogin(true); UserDefaults.standard.set(true, forKey: "loginSet")
        }
        // アクセシビリティの許可を待ってから始める（許可されるまで 2 秒ごとに確認）
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
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
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue)
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(mask), callback: tapCallback, userInfo: nil)
        if let t = tap {
            CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, t, 0), .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
        }
        NSWorkspace.shared.runningApplications.forEach { add($0) }
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                // 起動直後は窓がまだないので少し待つ
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.add(a) }
            }
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
                self?.watches.removeValue(forKey: a.processIdentifier)?.stop()
            }
        }
    }

    func add(_ a: NSRunningApplication) {
        guard a.activationPolicy == .regular, a.processIdentifier != getpid(),
              watches[a.processIdentifier] == nil, !a.isTerminated else { return }
        let w = AppWatch(a); w.start(); watches[a.processIdentifier] = w
    }

    // メニュー
    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        if !AXIsProcessTrusted() {
            m.addItem(withTitle: "⚠︎ アクセシビリティの許可が必要です…", action: #selector(openAX), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        let g = m.addItem(withTitle: "緑ボタンで画面いっぱいに広げる（⌥ で標準）", action: #selector(toggleGreen), keyEquivalent: "")
        g.target = self; g.state = Prefs.green ? .on : .off
        let q = m.addItem(withTitle: "最後の窓を閉じたらアプリを終了", action: #selector(toggleQuit), keyEquivalent: "")
        q.target = self; q.state = Prefs.quitLast ? .on : .off
        m.addItem(withTitle: "終了させないアプリを編集…", action: #selector(editExclude), keyEquivalent: "").target = self
        m.addItem(.separator())
        let l = m.addItem(withTitle: "ログイン時に起動", action: #selector(toggleLogin), keyEquivalent: "")
        l.target = self; l.state = loginOn ? .on : .off
        m.addItem(withTitle: "RedGreen を終了", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
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
