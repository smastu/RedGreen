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
        "menu.layout.withFinder": "Side by Side with Finder",
        "menu.finder.withApp": "Put %@ and Finder Side by Side",
        "menu.finder.two": "Two Finder Windows Side by Side",
        "menu.switcher": "⌘Tab Switches Windows (like Windows Alt+Tab)",
        "menu.finderBar": "Editable Address Bar in Finder",
        "menu.cutPaste": "⌘X → ⌘V Moves Files in Finder",
        "menu.dockMin": "Click Front App's Dock Icon to Hide It (like Windows taskbar)",
        "menu.finderWinKeys": "Finder: Enter Opens, Delete Trashes, F2 Renames",
        "menu.confirmDelete": "Ask Before Moving to Trash with Delete",
        "trash.one": "Move “%@” to the Trash?",
        "trash.many": "Move %@ items to the Trash?",
        "trash.ok": "Move to Trash",
        "trash.cancel": "Cancel",
        "menu.yellow": "Yellow Button Hides the App (Long-press: Minimize Menu)",
        "menu.yellowHover": "Also Show These Menus When Hovering",
        "menu.red": "Long-press Red Button: Close Window or Quit App",
        "menu.close.window": "Close This Window Only",
        "menu.close.app": "Quit %@",
        "menu.hide.app": "Hide %@",
        "menu.min.window": "Minimize This Window",
        "menu.min.app": "Minimize All %@ Windows",
        "menu.min.all": "Minimize All Apps' Windows",
        "switch.minimized": "(minimized)",
        "switch.hint": "⌘ held: W close · M minimize · Q quit app · H hide app · F full screen · S search · ⌘` this app only",
        "switch.hintSearch": "Type to filter (English letters) · ↑↓ select · Return switch · Esc clear / close",
        "switch.searchPlaceholder": "Type part of a window title or app name",
        "switch.noMatch": "No matching windows",
        "menu.switcherExclude": "Apps Not Shown in ⌘Tab…",
        "file.switcherExclude.header": "# Apps not shown in the ⌘Tab list (one per line: app name or bundle ID). Lines starting with # are ignored",
        "switch.hidden": "(hidden)",
        "switch.noWindow": "(no windows)",
        "finderBar.placeholder": "Type a path and press Return",
        "finderBar.needPermission": "Allow RedGreen to control Finder: System Settings → Privacy & Security → Automation",
        "menu.minimizeAll": "Minimize All Windows to Dock",
        "menu.restoreAll": "Restore Minimized Windows (%@)",
        "log.minimizeAll": "Minimized all windows: %@",
        "menu.language": "Language",
        "menu.lang.auto": "Automatic (%@)",
        "menu.lang.openFolder": "Open language patch folder…",
        "menu.lang.export": "Export translation template…",
        "why.red": "Red button",
        "why.cmdW": "⌘W",
        "log.secureOn": "Secure input is on (password field, remote desktop, etc.): using the standard ⌘Tab for now",
        "log.secureOff": "Secure input is off: ⌘Tab switches windows again",
        "log.secureOnHotKey": "Secure input is on: ⌘Tab now works via a hotkey (arrows and letter keys are unavailable meanwhile)",
        "log.recycle": "Memory %@ MB (over %@ MB) and idle: restarting to return memory",
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
        "menu.layout.withFinder": "Finder と横に並べる",
        "menu.finder.withApp": "%@ と Finder を横に並べる",
        "menu.finder.two": "Finder を 2 つ横に並べる",
        "menu.switcher": "⌘Tab で窓ごとに切り替える（Windows の Alt+Tab 風）",
        "menu.finderBar": "Finder に編集できるアドレス欄を出す",
        "menu.cutPaste": "Finder で ⌘X → ⌘V をファイルの移動にする",
        "menu.dockMin": "前面のアプリの Dock アイコンを押したら隠す（Windows のタスクバー風）",
        "menu.finderWinKeys": "Finder で Enter で開く・Delete でゴミ箱・F2 で名前の変更",
        "menu.confirmDelete": "Delete でゴミ箱に入れる前に確認する",
        "trash.one": "「%@」をゴミ箱に入れますか？",
        "trash.many": "%@ 個の項目をゴミ箱に入れますか？",
        "trash.ok": "ゴミ箱に入れる",
        "trash.cancel": "キャンセル",
        "menu.yellow": "黄色ボタンでアプリを隠す（長押しでしまい方を選ぶ）",
        "menu.yellowHover": "黄・赤ボタンにマウスを乗せたときもメニューを出す",
        "menu.red": "赤ボタンの長押しで「窓だけ閉じる／アプリを終了」を選ぶ",
        "menu.close.window": "この窓だけ閉じる",
        "menu.close.app": "%@ を終了",
        "menu.hide.app": "%@ を隠す",
        "menu.min.window": "この窓を Dock にしまう",
        "menu.min.app": "%@ の窓をすべて Dock にしまう",
        "menu.min.all": "すべてのアプリの窓を Dock にしまう",
        "switch.minimized": "（最小化）",
        "switch.hint": "⌘ を押したまま：W 閉じる・M しまう・Q 終了・H 隠す・F 全画面・S 検索・⌘` 同じアプリだけ",
        "switch.hintSearch": "英字で絞り込み・↑↓ 選ぶ・Return 切り替え・Esc 消す／閉じる",
        "switch.searchPlaceholder": "窓の題名かアプリ名の一部を打つ（英字）",
        "switch.noMatch": "見つかりません",
        "menu.switcherExclude": "⌘Tab に出さないアプリ…",
        "file.switcherExclude.header": "# ⌘Tab の一覧に出さないアプリ（1 行に 1 つ。アプリ名かバンドル ID）。# の行は無視",
        "switch.hidden": "（非表示）",
        "switch.noWindow": "（窓なし）",
        "finderBar.placeholder": "パスを入力して Return",
        "finderBar.needPermission": "Finder の操作を許可してください（システム設定 → プライバシーとセキュリティ → オートメーション）",
        "menu.minimizeAll": "すべての窓を Dock にしまう",
        "menu.restoreAll": "しまった窓を戻す（%@ 枚）",
        "log.minimizeAll": "すべての窓を Dock にしまった：%@ 枚",
        "menu.language": "言語（Language）",
        "menu.lang.auto": "自動（%@）",
        "menu.lang.openFolder": "言語パッチのフォルダを開く…",
        "menu.lang.export": "翻訳用のひな形を書き出す…",
        "why.red": "赤ボタン",
        "why.cmdW": "⌘W",
        "log.secureOn": "セキュア入力がオン（パスワード欄・リモートデスクトップなど）：その間は標準の ⌘Tab に戻す",
        "log.secureOff": "セキュア入力がオフ：⌘Tab の窓切り替えに戻した",
        "log.secureOnHotKey": "セキュア入力がオン：⌘Tab はショートカットキーで受ける（その間は矢印・文字キーの操作は使えない）",
        "log.recycle": "メモリ %@ MB（%@ MB 超え）で使っていないので、メモリを返すため起動し直す",
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
    static var yellow: Bool {
        get { UserDefaults.standard.object(forKey: "yellow") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "yellow") }
    }
    static var yellowHover: Bool {
        get { UserDefaults.standard.object(forKey: "yellowHover") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "yellowHover") }
    }
    static var dockMin: Bool {
        get { UserDefaults.standard.object(forKey: "dockMin") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "dockMin") }
    }
    static var red: Bool {
        get { UserDefaults.standard.object(forKey: "red") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "red") }
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
    let line = "\(df.string(from: Date())) \(m) [\(String(format: "%.1f", Recycler.footprintMB()))MB]\n"
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
func setFrame(_ w: AXUIElement, _ r: CGRect, retries: Int = 4, done: ((CGRect) -> Void)? = nil) {
    var p = r.origin, s = r.size
    let pv = AXValueCreate(.cgPoint, &p)!, sv = AXValueCreate(.cgSize, &s)!
    // 位置 → 大きさ → 位置（画面の端で大きさが削られないように）
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
    AXUIElementSetAttributeValue(w, kAXSizeAttribute as CFString, sv)
    AXUIElementSetAttributeValue(w, kAXPositionAttribute as CFString, pv)
    // Finder などは反映が遅れて取りこぼすことがあるので、少し待って確かめ、ずれていればやり直す
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        guard let cur = currentFrame(w) else { return }
    if retries > 0, !approx(cur, r) { setFrame(w, r, retries: retries - 1, done: done) }
        else { done?(cur) }
    }
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

/// toggle：同じ配置がもう一度選ばれたら元に戻す。screen：並べる画面（省略時は窓のある画面）
func place(_ w: AXUIElement, _ layout: Layout, toggle: Bool = true, screen: CGRect? = nil) {
    memMark("緑ボタンの配置")
    guard let cur = currentFrame(w) else { return }
    savedFrames.removeAll { (attr($0.win, kAXRoleAttribute) as String?) == nil }   // 消えた窓は忘れる
    var original = cur
    if let i = savedFrames.firstIndex(where: { CFEqual($0.win, w) }) {
        if approx(cur, savedFrames[i].after) {
            original = savedFrames[i].frame
            if toggle, savedFrames[i].layout == layout {         // 同じ配置をもう一度 → 元に戻す
                setFrame(w, original)
                savedFrames.remove(at: i)
                return
            }
        }
        savedFrames.remove(at: i)
    }
    let v = screen ?? visibleAXFrame(containing: CGPoint(x: cur.midX, y: cur.midY))
    let half = (v.width / 2).rounded()
    let target: CGRect
    switch layout {
    case .fill: target = v
    case .left: target = CGRect(x: v.minX, y: v.minY, width: half, height: v.height)
    case .right: target = CGRect(x: v.minX + half, y: v.minY, width: v.width - half, height: v.height)
    }
    savedFrames.append((w, original, target, layout))
    setFrame(w, target) { actual in                        // アプリが大きさを調整したら、その大きさを覚える
        if let i = savedFrames.firstIndex(where: { CFEqual($0.win, w) }) { savedFrames[i].after = actual }
    }
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

/// 赤ボタン：すぐ離せば今までどおり（閉じて、最後の窓ならアプリも終了）。長押しで「窓だけ閉じる／アプリを終了」
var redDown: (button: AXUIElement, pid: pid_t, time: Date)?

func redReleased(_ r: (button: AXUIElement, pid: pid_t, time: Date)) {
    memMark("赤ボタン")
    if Date().timeIntervalSince(r.time) > 0.45 { showCloseMenu(r.button, pid: r.pid); return }
    let sub = isSubWindow(attr(r.button, kAXWindowAttribute) as AXUIElement?)
    let before = Prefs.quitLast && !sub ? standardWindowCount(r.pid) : 0
    if sub { log("赤ボタン：サブウィンドウなのでアプリは終了しない（\(NSRunningApplication(processIdentifier: r.pid)?.localizedName ?? "?")）") }
    AXUIElementPerformAction(r.button, kAXPressAction as CFString)
    if Prefs.quitLast { checkQuit(pid: r.pid, before: before, why: L("why.red")) }
}

func showCloseMenu(_ button: AXUIElement, pid: pid_t) {
    memMark("赤ボタンのメニュー")
    menuActions.removeAll()
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    let m = NSMenu()
    addItem(m, L("menu.close.window")) { AXUIElementPerformAction(button, kAXPressAction as CFString) }
    addItem(m, L("menu.close.app", name)) { NSRunningApplication(processIdentifier: pid)?.terminate() }
    m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

/// 黄色ボタン：クリックはアプリごと隠す（⌘H と同じ。しまう動きが出ない）、長押しでしまい方のメニュー
var yellowDown: (win: AXUIElement, time: Date)?

func yellowReleased(_ y: (win: AXUIElement, time: Date)) {
    memMark("黄色ボタン")
    if Date().timeIntervalSince(y.time) > 0.45 { showMinimizeMenu(y.win); return }
    var pid: pid_t = 0
    AXUIElementGetPid(y.win, &pid)
    let app = NSRunningApplication(processIdentifier: pid)
    let name = app?.localizedName ?? "?"
    if app?.hide() == true { log("黄色ボタン：隠した（\(name)）"); return }
    // 前面でないアプリなどで hide() が通らないことがあるので、アクセシビリティで隠す
    let ax = AXUIElementCreateApplication(pid)
    if AXUIElementSetAttributeValue(ax, kAXHiddenAttribute as CFString, kCFBooleanTrue) == .success {
        log("黄色ボタン：AX で隠した（\(name)）"); return
    }
    log("黄色ボタン：隠せないので Dock にしまう（\(name)）")
    AXUIElementSetAttributeValue(y.win, kAXMinimizedAttribute as CFString, kCFBooleanTrue)   // 隠せないアプリだけ従来どおり
}

func showMinimizeMenu(_ w: AXUIElement) {
    memMark("黄色ボタンのメニュー")
    menuActions.removeAll()
    var pid: pid_t = 0
    AXUIElementGetPid(w, &pid)
    let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
    let m = NSMenu()
    addItem(m, L("menu.hide.app", name)) {
        if NSRunningApplication(processIdentifier: pid)?.hide() != true {
            AXUIElementSetAttributeValue(AXUIElementCreateApplication(pid), kAXHiddenAttribute as CFString, kCFBooleanTrue)
        }
    }
    addItem(m, L("menu.min.window")) { AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanTrue) }
    addItem(m, L("menu.min.app", name)) { minimizeAllWindows(only: pid) }
    addItem(m, L("menu.min.all")) { minimizeAllWindows() }
    if !minimizedByUs.isEmpty {
        m.addItem(.separator())
        addItem(m, L("menu.restoreAll", "\(minimizedByUs.count)")) { restoreMinimizedWindows() }
    }
    m.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
}

/// 黄色・赤ボタンにマウスを乗せて止めたら、メニューを出す（macOS の緑ボタンと同じ）
/// 軽さ重視：マウスの位置を 0.15 秒ごとに見るだけ。止まったときだけ、そこが黄色・赤ボタンかを調べる（赤はすぐ、黄色は 0.5 秒で出す）
final class ButtonHover {
    private var lastPos = CGPoint.zero
    private var restSince = Date()
    private var checked = false
    private var shownAt: CGPoint?          // メニューを出したボタンの位置（離れるまで出し直さない）

    init() {
        Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) { [weak self] _ in autoreleasepool { self?.tick() } }
    }

    private func tick() {
        guard Prefs.yellowHover, Prefs.yellow || Prefs.red else { return }
        let m = NSEvent.mouseLocation
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        let p = CGPoint(x: m.x, y: primaryH - m.y)          // AX の座標（左上原点）
        if hypot(p.x - lastPos.x, p.y - lastPos.y) > 2 {
            lastPos = p; restSince = Date(); checked = false
            if let s = shownAt, hypot(p.x - s.x, p.y - s.y) > 12 { shownAt = nil }
            return
        }
        // 赤ボタンは止まったらすぐ（間違って押して終了しないように）、黄色は 0.5 秒止まったら
        let rest = Date().timeIntervalSince(restSince)
        guard !checked, shownAt == nil, rest > 0.1, NSEvent.pressedMouseButtons == 0 else { return }
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(p.x), Float(p.y), &el) == .success, let e = el,
              let sub: String = attr(e, kAXSubroleAttribute),
              (sub == kAXMinimizeButtonSubrole && Prefs.yellow) || (sub == kAXCloseButtonSubrole && Prefs.red)
        else { checked = true; return }
        if sub == kAXMinimizeButtonSubrole && rest <= 0.5 { return }   // 黄色はもう少し待つ
        checked = true
        guard let win: AXUIElement = attr(e, kAXWindowAttribute) else { return }
        var pid: pid_t = 0
        AXUIElementGetPid(e, &pid)
        if pid == getpid() { return }
        shownAt = p
        if sub == kAXMinimizeButtonSubrole { showMinimizeMenu(win) } else { showCloseMenu(e, pid: pid) }
    }
}
var buttonHover: ButtonHover?

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
    memMark("緑ボタンのメニュー")
    menuActions.removeAll()
    let m = NSMenu()
    addItem(m, L("menu.layout.left")) { place(w, .left) }
    addItem(m, L("menu.layout.right")) { place(w, .right) }
    addItem(m, L("menu.layout.fill")) { place(w, .fill) }
    m.addItem(.separator())
    addItem(m, L("menu.layout.withFinder")) { arrangeWithFinder(w) }
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

/// 設定・環境設定などのサブウィンドウか。閉じても「最後の窓」とみなさない（アプリを終了しない）
/// 目印：SwiftUI の Settings 窓の識別子、題名、黄色ボタンがない・押せない（設定窓はふつう最小化できない）
func isSubWindow(_ w: AXUIElement?) -> Bool {
    guard let w else { return false }
    if (attr(w, kAXSubroleAttribute) as String?) != kAXStandardWindowSubrole { return true }
    let id = ((attr(w, kAXIdentifierAttribute) as String?) ?? "").lowercased()
    if id.contains("settings") || id.contains("preferences") { return true }
    let t = ((attr(w, kAXTitleAttribute) as String?) ?? "").lowercased()
    for k in ["設定", "環境設定", "settings", "preferences", "options", "オプション", "について", "about "] where t.contains(k) { return true }
    guard let mb: AXUIElement = attr(w, kAXMinimizeButtonAttribute) else { return true }
    if (attr(mb, kAXEnabledAttribute) as Bool?) == false { return true }
    return false
}

/// 窓を閉じる操作のあと、そのアプリの窓が 0 になっていたら終了（保存の確認などで遅れることがあるので数回確かめる）
func checkQuit(pid: pid_t, before: Int, why: String) {
    memMark("最後の窓で終了の確認")
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
/// メニューバー常駐のアプリは自分宛てのイベントをほとんど受け取らないので、AppKit の一時データの片づけ（autorelease）が
/// なかなか走らず、クリックやキーのたびに溜まっていく。入口ごとにその場で片づける
let tapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    autoreleasepool { tapBody(proxy, type, event, refcon) }
}
let tapBody: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = tap { CGEvent.tapEnable(tap: t, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    if (type == .keyDown || type == .flagsChanged) && Switcher.shared.handle(type, event) { return nil }
    if type == .flagsChanged { return Unmanaged.passUnretained(event) }
    if type == .keyDown { memMark("キー入力") }
    if type == .keyDown && CutPaste.shared.handle(event) { return nil }
    if type == .leftMouseUp && swallowUp {
        swallowUp = false
        if let r = redDown {
            redDown = nil
            DispatchQueue.main.async { redReleased(r) }
            return nil
        }
        if let y = yellowDown {
            yellowDown = nil
            DispatchQueue.main.async { yellowReleased(y) }
            return nil
        }
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
            let ax = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(ax, 0.3)
            if isSubWindow(attr(ax, kAXFocusedWindowAttribute) as AXUIElement?) { return Unmanaged.passUnretained(event) }
            let before = Prefs.quitLast ? standardWindowCount(pid) : 0
            DispatchQueue.main.async { checkQuit(pid: pid, before: before, why: L("why.cmdW")) }
        }
        return Unmanaged.passUnretained(event)
    }
    guard type == .leftMouseDown else { return Unmanaged.passUnretained(event) }
    memMark("クリック")
    let loc = event.location
    var el: AXUIElement?
    guard AXUIElementCopyElementAtPosition(systemWide, Float(loc.x), Float(loc.y), &el) == .success, let e = el else {
        return Unmanaged.passUnretained(event)
    }
    if Prefs.dockMin, !event.flags.contains(.maskAlternate), appsLauncherToggle(e) {
        swallowUp = true
        return nil
    }
    if Prefs.dockMin, !event.flags.contains(.maskAlternate), let app = dockClickedApp(e), dockToggle(app) {
        swallowUp = true
        return nil
    }
    guard (attr(e, kAXRoleAttribute) as String?) == kAXButtonRole,
          let sub: String = attr(e, kAXSubroleAttribute) else {
        return Unmanaged.passUnretained(event)
    }
    if sub == kAXCloseButtonSubrole, Prefs.red, !event.flags.contains(.maskAlternate) {
        var pid: pid_t = 0
        if AXUIElementGetPid(e, &pid) == .success, pid != getpid() {
            swallowUp = true
            redDown = (e, pid, Date())
            return nil
        }
    }
    if sub == kAXCloseButtonSubrole {
        var pid: pid_t = 0
        if Prefs.quitLast, AXUIElementGetPid(e, &pid) == .success,
           !isSubWindow(attr(e, kAXWindowAttribute) as AXUIElement?) {
            let before = standardWindowCount(pid)
            DispatchQueue.main.async { checkQuit(pid: pid, before: before, why: L("why.red")) }
        }
        return Unmanaged.passUnretained(event)
    }
    if sub == kAXMinimizeButtonSubrole {
        guard Prefs.yellow, !event.flags.contains(.maskAlternate),
              let win: AXUIElement = attr(e, kAXWindowAttribute) else { return Unmanaged.passUnretained(event) }
        swallowUp = true
        yellowDown = (win, Date())
        return nil
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
        Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in autoreleasepool { self?.tick() } }
    }

    func tick() {
        memMark("自動終了の見回り")
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

// MARK: - Finder と横に並べる（コピー・アップロード用）

/// 普通の窓（最小化していないもの）を前から順に
func visibleStandardWindows(_ pid: pid_t) -> [AXUIElement] {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
    return ws.filter { (attr($0, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole
                       && (attr($0, kAXMinimizedAttribute) as Bool?) != true }
}

/// アプリの操作中の窓（なければ一番前の普通の窓）
func mainWindow(_ pid: pid_t) -> AXUIElement? {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    if let w: AXUIElement = attr(ax, kAXFocusedWindowAttribute),
       (attr(w, kAXSubroleAttribute) as String?) == kAXStandardWindowSubrole { return w }
    return visibleStandardWindows(pid).first
}

var finderApp: NSRunningApplication? {
    NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.finder").first
}

/// Finder の窓を少なくとも n 枚用意する（足りなければ ⌘N で開く）
func ensureFinderWindows(_ n: Int, _ done: @escaping ([AXUIElement]) -> Void) {
    guard let finder = finderApp else { done([]); return }
    let pid = finder.processIdentifier
    var ws = visibleStandardWindows(pid)
    guard ws.count < n else { done(ws); return }
    // ⌘N を Finder に直接送る
    let src = CGEventSource(stateID: .hidSystemState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 45, keyDown: down)   // N
        e?.flags = .maskCommand
        e?.postToPid(pid)
    }
    var tries = 0
    func wait() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            let now = visibleStandardWindows(pid)
            tries += 1
            if now.count > ws.count {
                ws = now
                ensureFinderWindows(n, done)                 // まだ足りなければもう 1 枚
            } else if tries < 15 { wait() }
            else { done(now) }
        }
    }
    wait()
}

/// 左右に並べて、両方を前に出す（左の窓を操作中にする）
func sideBySide(_ left: AXUIElement, _ right: AXUIElement) {
    guard let cur = currentFrame(left) else { return }
    let screen = visibleAXFrame(containing: CGPoint(x: cur.midX, y: cur.midY))
    place(left, .left, toggle: false, screen: screen)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
        place(right, .right, toggle: false, screen: screen)
    }
    var lp: pid_t = 0, rp: pid_t = 0
    AXUIElementGetPid(left, &lp); AXUIElementGetPid(right, &rp)
    AXUIElementPerformAction(right, kAXRaiseAction as CFString)
    if lp != rp { NSRunningApplication(processIdentifier: rp)?.activate() }
    AXUIElementPerformAction(left, kAXRaiseAction as CFString)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
        NSRunningApplication(processIdentifier: lp)?.activate()
    }
}

/// アプリの窓を左、Finder を右に
func arrangeWithFinder(_ w: AXUIElement) {
    var pid: pid_t = 0
    AXUIElementGetPid(w, &pid)
    if pid == finderApp?.processIdentifier { arrangeFinders(); return }
    ensureFinderWindows(1) { fs in
        if let f = fs.first { sideBySide(w, f) }
    }
}

/// Finder を 2 枚、左右に
func arrangeFinders() {
    ensureFinderWindows(2) { fs in
        if fs.count >= 2 { sideBySide(fs[0], fs[1]) }
    }
}

// MARK: - Dock のアイコンで最小化（Windows のタスクバー風）

/// 押したのが Dock のアプリのアイコンなら、そのアプリ（動いているものだけ）
func dockClickedApp(_ e: AXUIElement) -> NSRunningApplication? {
    guard (attr(e, kAXSubroleAttribute) as String?) == "AXApplicationDockItem" else { return nil }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &v) == .success,
          let url = (v as? URL) ?? (v as? NSURL as URL?) else { return nil }
    let path = url.standardizedFileURL.path
    // 同じアプリから複数のプロセスが動くことがある（ResourceWatch のメニューバー係と窓係など）。Dock に出ている方（.regular）を選ぶ。
    // 普通のアプリでないもの（「アプリ」＝Apps.app のような裏方のアプリ）は Dock に任せる（横取りすると閉じられなくなる）
    return NSWorkspace.shared.runningApplications.first {
        $0.processIdentifier != getpid() && $0.activationPolicy == .regular && $0.bundleURL?.standardizedFileURL.path == path
    }
}

/// Dock の「アプリ」（Apps.app）：開いているときに押すと、macOS は「外を押した」で閉じた直後に開き直してしまう。
/// 開いているときはクリックを止めて、閉じるだけにする（画面は Siri のプロセスが出している）
let appsLauncherPath = "/System/Applications/Apps.app"
func appsLauncherToggle(_ e: AXUIElement) -> Bool {
    guard (attr(e, kAXSubroleAttribute) as String?) == "AXApplicationDockItem" else { return false }
    var v: CFTypeRef?
    guard AXUIElementCopyAttributeValue(e, kAXURLAttribute as CFString, &v) == .success,
          let url = (v as? URL) ?? (v as? NSURL as URL?), url.standardizedFileURL.path == appsLauncherPath,
          appsLauncherShown() else { return false }
    DispatchQueue.main.async {
        NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: appsLauncherPath), configuration: NSWorkspace.OpenConfiguration())
    }
    return true
}

/// 「アプリ」の画面が出ているか（Siri のプロセスの大きな窓が画面の上の層にある）
func appsLauncherShown() -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { w in
        guard let layer = w[kCGWindowLayer as String] as? Int, layer > 0, layer < 1000,
              let pid = w[kCGWindowOwnerPID as String] as? pid_t,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat], (b["Width"] ?? 0) > 300 else { return false }
        var buf = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 else { return false }
        return String(cString: buf).contains("/Siri")
    }
}

/// しまってある窓を戻す（RedGreen 以外でしまったもの：⌘M・黄色ボタンなど）。戻せたら true
/// 「アプリのアイコンにしまう」設定だと、しまった窓は窓の一覧から消えるので、「ウインドウ」メニューの ◆ の項目も押す
func restoreMinimized(_ pid: pid_t) -> Bool {
    let ax = AXUIElementCreateApplication(pid)
    AXUIElementSetMessagingTimeout(ax, 0.5)
    var done = false
    let ws: [AXUIElement] = attr(ax, kAXWindowsAttribute) ?? []
    for w in ws where (attr(w, kAXMinimizedAttribute) as Bool?) == true {
        AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        done = true
    }
    if done { return true }
    guard let bar: AXUIElement = attr(ax, kAXMenuBarAttribute) else { return false }
    for top in (attr(bar, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
        for menu in (attr(top, kAXChildrenAttribute) as [AXUIElement]?) ?? [] {
            let items: [AXUIElement] = attr(menu, kAXChildrenAttribute) ?? []
            // 「しまう」（⌘M）がある menu が「ウインドウ」メニュー
            guard items.contains(where: { (attr($0, kAXMenuItemCmdCharAttribute) as String?) == "M"
                                          && ((attr($0, kAXMenuItemCmdModifiersAttribute) as Int?) ?? 0) == 0 }) else { continue }
            for it in items {
                let mark: String = attr(it, kAXMenuItemMarkCharAttribute) ?? ""
                if mark == "◆" || mark == "◇" {
                    AXUIElementPerformAction(it, kAXPressAction as CFString)
                    done = true
                }
            }
            return done
        }
    }
    return false
}

/// RedGreen が Dock のクリックでしまった窓（もう一度押したら戻す）
var dockMinimized: [pid_t: [AXUIElement]] = [:]

/// アプリの窓が画面に出ているか。ステージマネージャでは、しまった窓も AXMinimized が false のままなので、
/// 画面の窓の一覧で見る（横の列の小さな縮小表示は数えない）
func hasVisibleWindow(_ pid: pid_t) -> Bool {
    let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
    return list.contains { w in
        guard (w[kCGWindowOwnerPID as String] as? Int32) == pid, (w[kCGWindowLayer as String] as? Int) == 0,
              let b = w[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
        return (b["Width"] ?? 0) >= 200 && (b["Height"] ?? 0) >= 150
    }
}

/// Dock のアイコンを押したとき：
/// 前面のアプリで窓が出ていればしまう。窓が出ていなければ、しまってある窓を戻して前に出す。どちらでもなければ Dock に任せる
func dockToggle(_ app: NSRunningApplication) -> Bool {
    memMark("Dock のクリック")
    let pid = app.processIdentifier
    let isFront = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    if app.isHidden {                                        // 隠したアプリは一瞬で戻す
        DispatchQueue.main.async { app.unhide(); app.activate() }
        return true
    }
    if hasVisibleWindow(pid) {
        guard isFront else { return false }                 // 後ろのアプリは Dock に任せて前に出す
        DispatchQueue.main.async { _ = app.hide() }         // しまう代わりにアプリごと隠す（動きが出ない）
        return true
    }
    guard let ws = dockMinimized.removeValue(forKey: pid), !ws.isEmpty else {
        // メニューをたどるのは時間がかかることがあるので、クリックの受け取りの中ではやらない
        DispatchQueue.main.async {
            if restoreMinimized(pid) {
                app.activate()
            } else if let url = app.bundleURL {
                // 戻す窓がなければ、Dock と同じく開き直す（窓を出し直すアプリなら新しい窓が出る）
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        }
        return true
    }
    DispatchQueue.main.async {
        for w in ws.reversed() {
            AXUIElementSetAttributeValue(w, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
            AXUIElementPerformAction(w, kAXRaiseAction as CFString)
        }
        minimizedByUs.removeAll { m in ws.contains { CFEqual($0, m) } }
        NSRunningApplication(processIdentifier: pid)?.activate()
    }
    return true
}

// MARK: - すべての窓を Dock にしまう

/// RedGreen がしまった窓（「戻す」で元に戻す）
var minimizedByUs: [AXUIElement] = []

/// only を渡すとそのアプリの窓だけ
func minimizeAllWindows(only: pid_t? = nil) {
    memMark("すべてしまう")
    var done: [AXUIElement] = []
    for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid()
                                                         && (only == nil || app.processIdentifier == only) {
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
    minimizedByUs = only == nil ? done : minimizedByUs + done
    log(L("log.minimizeAll", "\(done.count)"))
}

func restoreMinimizedWindows() {
    memMark("しまった窓を戻す")
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
        Switcher.shared.applySystemHotKeys()
        Switcher.shared.watchSecureInput()
        Recycler.shared.start()
        if ProcessInfo.processInfo.environment["RG_DEBUG"] != nil {
            DistributedNotificationCenter.default().addObserver(forName: .init("RedGreen.debug.cycle"), object: nil, queue: .main) { n in
                let parts = (n.object as? String ?? "10 2").split(separator: " ")
                Switcher.shared.debugCycle(Int(parts.first ?? "10") ?? 10, gap: Double(parts.last ?? "2") ?? 2)
            }
        }
        FinderBar.shared.start()
        buttonHover = ButtonHover()
        let mask = (1 << CGEventType.leftMouseDown.rawValue) | (1 << CGEventType.leftMouseUp.rawValue) | (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.flagsChanged.rawValue)
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
        memMark("メニューバーのメニュー")
        m.removeAllItems()
        if !AXIsProcessTrusted() {
            m.addItem(withTitle: L("menu.needAX"), action: #selector(openAX), keyEquivalent: "").target = self
            m.addItem(.separator())
        }
        let g = m.addItem(withTitle: L("menu.green"), action: #selector(toggleGreen), keyEquivalent: "")
        g.target = self; g.state = Prefs.green ? .on : .off
        let y = m.addItem(withTitle: L("menu.yellow"), action: #selector(toggleYellow), keyEquivalent: "")
        y.target = self; y.state = Prefs.yellow ? .on : .off
        let rd = m.addItem(withTitle: L("menu.red"), action: #selector(toggleRed), keyEquivalent: "")
        rd.target = self; rd.state = Prefs.red ? .on : .off
        let yh = m.addItem(withTitle: L("menu.yellowHover"), action: #selector(toggleYellowHover), keyEquivalent: "")
        yh.target = self; yh.state = Prefs.yellowHover ? .on : .off; yh.indentationLevel = 1
        let q = m.addItem(withTitle: L("menu.quitLast"), action: #selector(toggleQuit), keyEquivalent: "")
        q.target = self; q.state = Prefs.quitLast ? .on : .off
        m.addItem(withTitle: L("menu.editExclude"), action: #selector(editExclude), keyEquivalent: "").target = self
        let sw = m.addItem(withTitle: L("menu.switcher"), action: #selector(toggleSwitcher), keyEquivalent: "")
        sw.target = self; sw.state = Switcher.enabled ? .on : .off
        let se = m.addItem(withTitle: L("menu.switcherExclude"), action: #selector(editSwitcherExclude), keyEquivalent: "")
        se.target = self; se.indentationLevel = 1
        let dk = m.addItem(withTitle: L("menu.dockMin"), action: #selector(toggleDockMin), keyEquivalent: "")
        dk.target = self; dk.state = Prefs.dockMin ? .on : .off
        let wk = m.addItem(withTitle: L("menu.finderWinKeys"), action: #selector(toggleWinKeys), keyEquivalent: "")
        wk.target = self; wk.state = CutPaste.winKeys ? .on : .off
        let cd = m.addItem(withTitle: L("menu.confirmDelete"), action: #selector(toggleConfirmDelete), keyEquivalent: "")
        cd.target = self; cd.state = CutPaste.confirmDelete ? .on : .off; cd.indentationLevel = 1
        cd.isEnabled = CutPaste.winKeys
        let cx = m.addItem(withTitle: L("menu.cutPaste"), action: #selector(toggleCut), keyEquivalent: "")
        cx.target = self; cx.state = CutPaste.enabled ? .on : .off
        let fb = m.addItem(withTitle: L("menu.finderBar"), action: #selector(toggleFinderBar), keyEquivalent: "")
        fb.target = self; fb.state = FinderBar.enabled ? .on : .off
        m.addItem(.separator())

        // Finder と並べる（メニューを開いたときの前面のアプリが対象）
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
           front.bundleIdentifier != "com.apple.finder", front.activationPolicy == .regular {
            let it = m.addItem(withTitle: L("menu.finder.withApp", front.localizedName ?? "?"),
                               action: #selector(MenuAction.run), keyEquivalent: "")
            let pid = front.processIdentifier
            let act = MenuAction { if let w = mainWindow(pid) { arrangeWithFinder(w) } }
            finderActions = [act]
            it.target = act
            it.isEnabled = mainWindow(pid) != nil
        }
        m.addItem(withTitle: L("menu.finder.two"), action: #selector(twoFinders), keyEquivalent: "").target = self
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
    var finderActions: [MenuAction] = []
    @objc func twoFinders() { arrangeFinders() }
    @objc func minimizeAll() { minimizeAllWindows() }
    @objc func restoreAll() { restoreMinimizedWindows() }
    @objc func openLangFolder() { NSWorkspace.shared.open(Lang.userDir) }
    @objc func exportLang() { NSWorkspace.shared.activateFileViewerSelecting([Lang.exportTemplate()]) }
    @objc func editKeep() {
        _ = Prefs.keep()
        NSWorkspace.shared.open([keepFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
    @objc func toggleSwitcher() { Switcher.enabled.toggle() }
    @objc func toggleYellow() { Prefs.yellow.toggle() }
    @objc func toggleYellowHover() { Prefs.yellowHover.toggle() }
    @objc func toggleRed() { Prefs.red.toggle() }
    @objc func toggleCut() { CutPaste.enabled.toggle() }
    @objc func toggleDockMin() { Prefs.dockMin.toggle() }
    @objc func toggleWinKeys() { CutPaste.winKeys.toggle() }
    @objc func toggleConfirmDelete() { CutPaste.confirmDelete.toggle() }
    @objc func toggleFinderBar() { FinderBar.enabled.toggle(); FinderBar.shared.settingChanged() }
    func applicationWillTerminate(_ n: Notification) { Switcher.shared.restoreSystemHotKeys() }
    @objc func toggleGreen() { Prefs.green.toggle() }
    @objc func toggleQuit() { Prefs.quitLast.toggle() }
    @objc func editSwitcherExclude() {
        _ = Switcher.excluded()
        NSWorkspace.shared.open([switcherExcludeFile], withApplicationAt: URL(fileURLWithPath: "/System/Applications/TextEdit.app"),
                                configuration: NSWorkspace.OpenConfiguration())
    }
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

var signalSources: [DispatchSourceSignal] = []

@main
struct Main {
    static func main() {
        let app = NSApplication.shared
        let d = App()
        app.delegate = d
        app.setActivationPolicy(.accessory)
        // pkill などで止められても、標準の ⌘Tab を必ず戻す
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { Switcher.shared.restoreSystemHotKeys(); exit(0) }
            src.resume()
            signalSources.append(src)
        }
        app.run()
    }
}
