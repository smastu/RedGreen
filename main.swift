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
var defaultExclude: String { """
\(L("file.exclude.header"))
com.apple.finder
local.shimpei.teamslite
local.matsumoto.LiteDeck
local.matsumoto.ResourceWatch

""" }

let keepFile = supportDir.appendingPathComponent("keep_running.txt")
var defaultKeep: String { """
\(L("file.keep.header"))
\(L("file.keep.terminals"))
com.googlecode.iterm2
com.apple.Terminal
com.mitchellh.ghostty
dev.warp.Warp-Stable
net.kovidgoyal.kitty
org.alacritty
com.github.wez.wezterm
\(L("file.keep.messaging"))
local.shimpei.slacklite
local.shimpei.teamslite
\(L("file.keep.media"))
com.apple.Music
com.spotify.client
us.zoom.xos
com.microsoft.teams2
com.apple.FaceTime

""" }

// MARK: - 言語（Language）
// 日本語・英語は内蔵。ほかの言語は「言語パッチ」（JSON）を置くと選べる：
//   ~/Library/Application Support/RedGreen/lang/<言語コード>.json  または  RedGreen.app/Contents/Resources/lang/
//   中身は {"_language": "表示名", "キー": "訳", ...}。足りないキーは英語になる。%@ は差し込み（数・順番を変えない）

struct LangPack {
    let id: String
    let name: String
    let table: [String: String]
}

enum Lang {
    static let en: [String: String] = [
        "menu.layout.left": "Left Half",
        "menu.layout.right": "Right Half",
        "menu.layout.fill": "Fill Screen",
        "menu.layout.restore": "Restore Original Size",
        "menu.layout.fullscreen": "Full Screen (macOS standard)",
        "menu.needAX": "⚠︎ Accessibility permission required…",
        "menu.green": "Green button: fill screen / halves (⌥ for standard)",
        "menu.quitLast": "Quit app when its last window closes",
        "menu.editExclude": "Edit apps that never quit…",
        "menu.off": "Off",
        "menu.minutes": "%@ min",
        "menu.idle": "Auto-quit unused apps",
        "menu.idle.noWindow": "Apps without windows: %@",
        "menu.idle.window": "Apps with windows: %@",
        "menu.idle.recent": "Recently auto-quit",
        "menu.editKeep": "Edit excluded apps…",
        "menu.quit": "Quit apps",
        "menu.quit.all": "Quit all (%@)",
        "menu.quit.note": "Excluded: terminals, messaging apps, etc. (Edit…)",
        "menu.login": "Launch at login",
        "menu.quitSelf": "Quit RedGreen",
        "menu.minimizeAll": "Minimize All Windows to Dock",
        "menu.restoreAll": "Restore Minimized Windows (%@)",
        "log.minimizeAll": "Minimized all windows: %@",
        "menu.language": "Language",
        "menu.lang.auto": "Automatic (%@)",
        "menu.lang.openFolder": "Open language patch folder…",
        "menu.lang.export": "Export translation template…",
        "why.red": "Red button",
        "why.cmdW": "⌘W",
        "log.launch": "Launched (permission=%@)",
        "log.start": "Started (permission granted)",
        "log.quitLast": "%@: %@ has no windows → quit %@",
        "log.autoQuit": "Auto-quit: %@ (unused for %@ min) %@",
        "log.menuQuit": "Quit from menu: %@ %@",
        "log.quitAll": "Quit all: %@ %@",
        "file.exclude.header": "# Apps that won't quit when their last window closes (one per line: app name or bundle ID). Lines starting with # are ignored",
        "file.keep.header": "# Apps never auto-quit or quit by \"Quit all\" (one per line: app name or bundle ID). Lines starting with # are ignored\n# Apps listed in exclude.txt are excluded too",
        "file.keep.terminals": "# Terminals (Claude Code etc. may be running)",
        "file.keep.messaging": "# Messaging / notification apps",
        "file.keep.media": "# Music / meetings",
    ]

    static let ja: [String: String] = [
        "menu.layout.left": "左半分",
        "menu.layout.right": "右半分",
        "menu.layout.fill": "画面いっぱい",
        "menu.layout.restore": "元の大きさに戻す",
        "menu.layout.fullscreen": "全画面（macOS 標準）",
        "menu.needAX": "⚠︎ アクセシビリティの許可が必要です…",
        "menu.green": "緑ボタンで画面いっぱい・左右半分（⌥ で標準）",
        "menu.quitLast": "最後の窓を閉じたらアプリを終了",
        "menu.editExclude": "終了させないアプリを編集…",
        "menu.off": "しない",
        "menu.minutes": "%@ 分",
        "menu.idle": "使っていないアプリを自動で終了",
        "menu.idle.noWindow": "窓がないアプリ：%@",
        "menu.idle.window": "窓があるアプリ：%@",
        "menu.idle.recent": "最近自動終了したアプリ",
        "menu.editKeep": "対象外のアプリを編集…",
        "menu.quit": "アプリをまとめて終了",
        "menu.quit.all": "すべて終了（%@ 個）",
        "menu.quit.note": "対象外：ターミナル・連絡アプリなど（編集…）",
        "menu.login": "ログイン時に起動",
        "menu.quitSelf": "RedGreen を終了",
        "menu.minimizeAll": "すべての窓を Dock にしまう",
        "menu.restoreAll": "しまった窓を戻す（%@ 枚）",
        "log.minimizeAll": "すべての窓を Dock にしまった：%@ 枚",
        "menu.language": "言語（Language）",
        "menu.lang.auto": "自動（%@）",
        "menu.lang.openFolder": "言語パッチのフォルダを開く…",
        "menu.lang.export": "翻訳用のひな形を書き出す…",
        "why.red": "赤ボタン",
        "why.cmdW": "⌘W",
        "log.launch": "起動 許可=%@",
        "log.start": "開始（許可あり）",
        "log.quitLast": "%@：%@ の窓が 0 → 終了 %@",
        "log.autoQuit": "自動終了：%@（%@ 分使っていない）%@",
        "log.menuQuit": "メニューから終了：%@ %@",
        "log.quitAll": "まとめて終了：%@ %@",
        "file.exclude.header": "# 最後の窓を閉じても終了させないアプリ（1 行に 1 つ。アプリ名かバンドル ID）。# の行は無視",
        "file.keep.header": "# 自動終了・「まとめて終了」の対象外にするアプリ（1 行に 1 つ。アプリ名かバンドル ID）。# の行は無視\n# exclude.txt に書いたアプリもこの対象外になる",
        "file.keep.terminals": "# ターミナル（Claude Code などが動いている）",
        "file.keep.messaging": "# 連絡・通知を受けるアプリ",
        "file.keep.media": "# 音楽・会議",
    ]

    static let userDir: URL = {
        let d = supportDir.appendingPathComponent("lang")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// 選べる言語：内蔵（en, ja）＋アプリ同梱のパッチ＋ユーザーのパッチ（同じ id なら後のものが優先）
    static func packs() -> [LangPack] {
        var byID: [String: LangPack] = [
            "en": LangPack(id: "en", name: "English", table: en),
            "ja": LangPack(id: "ja", name: "日本語", table: ja),
        ]
        let dirs = [Bundle.main.resourceURL?.appendingPathComponent("lang"), userDir].compactMap { $0 }
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for f in files where f.pathExtension == "json" && !f.lastPathComponent.hasPrefix("_") {
                guard let d = try? Data(contentsOf: f),
                      let obj = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { continue }
                let id = f.deletingPathExtension().lastPathComponent
                let base = byID[id]?.table ?? [:]                 // 内蔵言語への上書きは差分だけでよい
                byID[id] = LangPack(id: id, name: obj["_language"] ?? byID[id]?.name ?? id,
                                    table: base.merging(obj) { _, new in new })
            }
        }
        return byID.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// "auto" または言語の id
    static var setting: String {
        get { UserDefaults.standard.string(forKey: "language") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "language"); reload() }
    }

    /// 「自動」のときに使う言語：システムの優先言語の順に、合うものを探す
    static func autoPack(_ all: [LangPack]) -> LangPack {
        for pref in Locale.preferredLanguages {
            let parts = pref.split(separator: "-").map(String.init)
            var candidates = [pref]
            if parts.count >= 2 { candidates.append(parts[0] + "-" + parts[1]) }   // zh-Hans-JP → zh-Hans
            candidates.append(parts[0])                                            // ja-JP → ja
            for c in candidates {
                if let p = all.first(where: { $0.id.caseInsensitiveCompare(c) == .orderedSame }) { return p }
            }
        }
        return all.first { $0.id == "en" }!
    }

    static var current: LangPack = resolve()

    static func resolve() -> LangPack {
        let all = packs()
        if setting != "auto", let p = all.first(where: { $0.id == setting }) { return p }
        return autoPack(all)
    }

    static func reload() { current = resolve() }

    /// 翻訳用のひな形（英語）を書き出す
    static func exportTemplate() -> URL {
        var t = en
        t["_language"] = "Your language name (e.g. Français)"
        let url = userDir.appendingPathComponent("_template.json")
        if let d = try? JSONSerialization.data(withJSONObject: t, options: [.prettyPrinted, .sortedKeys]) {
            try? d.write(to: url)
        }
        return url
    }
}

/// 表示する文字列（%@ に args を順に差し込む）
func L(_ key: String, _ args: String...) -> String {
    let f = Lang.current.table[key] ?? Lang.en[key] ?? key
    return args.isEmpty ? f : String(format: f, arguments: args.map { $0 as NSString })
}

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
    addItem(m, L("menu.layout.left")) { place(w, .left) }
    addItem(m, L("menu.layout.right")) { place(w, .right) }
    addItem(m, L("menu.layout.fill")) { place(w, .fill) }
    if originalFrame(w) != nil {
        m.addItem(.separator())
        addItem(m, L("menu.layout.restore")) { restore(w) }
    }
    m.addItem(.separator())
    addItem(m, L("menu.layout.fullscreen")) {
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
                log(L("log.quitLast", why, app.localizedName ?? "?", "\(app.terminate())"))
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
            DispatchQueue.main.async { checkQuit(pid: pid, before: before, why: L("why.cmdW")) }
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
            DispatchQueue.main.async { checkQuit(pid: pid, before: before, why: L("why.red")) }
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
            log(L("log.autoQuit", name, "\(n)", "\(app.terminate())"))
            inactive[pid] = 0              // 保存の確認などで終わらなかったら、また同じ時間待つ
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            recent.insert("\(df.string(from: Date())) \(name)", at: 0)
            recent = Array(recent.prefix(5))
        }
    }
}

// MARK: - すべての窓を Dock にしまう

/// RedGreen がしまった窓（「戻す」で元に戻す）
var minimizedByUs: [AXUIElement] = []

func minimizeAllWindows() {
    var done: [AXUIElement] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
        let ax = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(ax, 0.5)
        let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
        for w in ws where (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
                       && (attr(w, kAXMinimizedAttribute) as Bool?) != true {
            if AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) == .success {
                done.append(w)
            }
        }
    }
    minimizedByUs = done
    log(L("log.minimizeAll", "\(done.count)"))
}

func restoreMinimizedWindows() {
    for w in minimizedByUs.reversed() where (attr(w, kAXMinimizedAttribute) as Bool?) == true {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
    }
    minimizedByUs = []
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
        log(L("log.launch", "\(AXIsProcessTrusted())"))
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
        log(L("log.start"))
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
            m.addItem(withTitle: L("menu.needAX"), action: #selector(openAX), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        let g = m.addItem(withTitle: L("menu.green"), action: #selector(toggleGreen), keyEquivalent: "")
        g.target = self; g.state = Prefs.green ? .on : .off
        let q = m.addItem(withTitle: L("menu.quitLast"), action: #selector(toggleQuit), keyEquivalent: "")
        q.target = self; q.state = Prefs.quitLast ? .on : .off
        m.addItem(withTitle: L("menu.editExclude"), action: #selector(editExclude), keyEquivalent: "").target = self
        m.addItem(.separator())

        m.addItem(withTitle: L("menu.minimizeAll"), action: #selector(minimizeAll), keyEquivalent: "").target = self
        let stillMin = minimizedByUs.filter { (attr($0, kAXMinimizedAttribute) as Bool?) == true }
        if !stillMin.isEmpty {
            m.addItem(withTitle: L("menu.restoreAll", "\(stillMin.count)"), action: #selector(restoreAll), keyEquivalent: "").target = self
        }
        m.addItem(.separator())

        // 自動終了
        let auto = NSMenu()
        func minutesMenu(_ title: String, _ cur: Int, _ set: @escaping (Int) -> Void) {
            let sub = NSMenu()
            for v in [0, 5, 10, 15, 30, 60, 120] {
                let it = NSMenuItem(title: label(v), action: #selector(MenuAction.run), keyEquivalent: "")
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
        minutesMenu(L("menu.idle.noWindow", label(Prefs.idleNoWindow)), Prefs.idleNoWindow) { Prefs.idleNoWindow = $0 }
        minutesMenu(L("menu.idle.window", label(Prefs.idleWindow)), Prefs.idleWindow) { Prefs.idleWindow = $0 }
        auto.addItem(.separator())
        auto.addItem(withTitle: L("menu.editKeep"), action: #selector(editKeep), keyEquivalent: "").target = self
        if let r = idle?.recent, !r.isEmpty {
            auto.addItem(.separator())
            auto.addItem(withTitle: L("menu.idle.recent"), action: nil, keyEquivalent: "")
            for x in r { auto.addItem(withTitle: "  " + x, action: nil, keyEquivalent: "") }
        }
        let autoItem = m.addItem(withTitle: L("menu.idle"), action: nil, keyEquivalent: "")
        autoItem.submenu = auto

        // まとめて終了
        let apps = quittableApps()
        let quit = NSMenu()
        let all = quit.addItem(withTitle: L("menu.quit.all", "\(apps.count)"), action: #selector(quitAll), keyEquivalent: "")
        all.target = self
        all.isEnabled = !apps.isEmpty
        quit.addItem(.separator())
        for a in apps {
            let it = NSMenuItem(title: a.localizedName ?? "?", action: #selector(MenuAction.run), keyEquivalent: "")
            let act = MenuAction { log(L("log.menuQuit", a.localizedName ?? "?", "\(a.terminate())")) }
            minuteActions.append(act)
            it.target = act
            it.image = a.icon.map { i in let c = i.copy() as! NSImage; c.size = NSSize(width: 16, height: 16); return c }
            quit.addItem(it)
        }
        quit.addItem(.separator())
        quit.addItem(withTitle: L("menu.quit.note"), action: #selector(editKeep), keyEquivalent: "").target = self
        let quitItem = m.addItem(withTitle: L("menu.quit"), action: nil, keyEquivalent: "")
        quitItem.submenu = quit
        m.addItem(.separator())
        // 言語
        let langMenu = NSMenu()
        let packs = Lang.packs()
        let autoItem2 = NSMenuItem(title: L("menu.lang.auto", Lang.autoPack(packs).name), action: #selector(MenuAction.run), keyEquivalent: "")
        let autoAct = MenuAction { Lang.setting = "auto" }
        minuteActions.append(autoAct)
        autoItem2.target = autoAct
        autoItem2.state = Lang.setting == "auto" ? .on : .off
        langMenu.addItem(autoItem2)
        langMenu.addItem(.separator())
        for p in packs {
            let it = NSMenuItem(title: p.name, action: #selector(MenuAction.run), keyEquivalent: "")
            let act = MenuAction { Lang.setting = p.id }
            minuteActions.append(act)
            it.target = act
            it.state = Lang.setting == p.id ? .on : .off
            langMenu.addItem(it)
        }
        langMenu.addItem(.separator())
        langMenu.addItem(withTitle: L("menu.lang.openFolder"), action: #selector(openLangFolder), keyEquivalent: "").target = self
        langMenu.addItem(withTitle: L("menu.lang.export"), action: #selector(exportLang), keyEquivalent: "").target = self
        let langItem = m.addItem(withTitle: L("menu.language"), action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        m.addItem(.separator())
        let l = m.addItem(withTitle: L("menu.login"), action: #selector(toggleLogin), keyEquivalent: "")
        l.target = self; l.state = loginOn ? .on : .off
        m.addItem(withTitle: L("menu.quitSelf"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
    var minuteActions: [MenuAction] = []
    func label(_ v: Int) -> String { v == 0 ? L("menu.off") : L("menu.minutes", "\(v)") }
    @objc func quitAll() {
        for a in quittableApps() { log(L("log.quitAll", a.localizedName ?? "?", "\(a.terminate())")) }
    }
    @objc func minimizeAll() { minimizeAllWindows() }
    @objc func restoreAll() { restoreMinimizedWindows() }
    @objc func openLangFolder() { NSWorkspace.shared.open(Lang.userDir) }
    @objc func exportLang() { NSWorkspace.shared.activateFileViewerSelecting([Lang.exportTemplate()]) }
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
