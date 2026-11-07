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
    if type == .leftMouseUp && swallowUp { swallowUp = false; return nil }
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
    DispatchQueue.main.async { fill(window: win) }
    return nil
}

// MARK: - 本体

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var status: NSStatusItem!
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
