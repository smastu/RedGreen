import Cocoa
import UniformTypeIdentifiers

/// Windows のショートカット（.lnk）をダブルクリックしたとき、Mac の対応パスを示して Finder で開く。
/// 旧「LNK解析.app」（~/mac-lnk-parser）の移植。RedGreen を .lnk の既定のアプリにして使う。
enum Lnk {
    static let utiID = "com.microsoft.windows-shortcut"

    struct Info {
        var isDir = false
        var localPath = ""     // C:\Dropbox\...
        var netPath = ""       // \\server\share\...
        var relPath = ""       // ..\Folder\...
        var workingDir = ""
        var machine = ""
        var windowsPath: String { !localPath.isEmpty ? localPath : netPath }
    }

    // MARK: 解析（MS-SHLLINK）

    static func parse(_ url: URL) -> (Info?, String?) {
        guard let d = try? Data(contentsOf: url) else { return (nil, L("lnk.err.read")) }
        let b = [UInt8](d)
        guard b.count >= 76, b[0] == 0x4C, b[1] == 0, b[2] == 0, b[3] == 0 else { return (nil, L("lnk.err.format")) }
        func u16(_ i: Int) -> Int { i + 2 <= b.count ? Int(b[i]) | Int(b[i+1]) << 8 : 0 }
        func u32(_ i: Int) -> Int { i + 4 <= b.count ? Int(b[i]) | Int(b[i+1]) << 8 | Int(b[i+2]) << 16 | Int(b[i+3]) << 24 : 0 }
        let cp932 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.dosJapanese.rawValue)))
        func ansi(_ s: Int, _ end: Int) -> String {       // 0 終端の ANSI（CP932）文字列
            guard s < end, end <= b.count else { return "" }
            var e = s; while e < end && b[e] != 0 { e += 1 }
            let slice = Data(b[s..<e])
            return String(data: slice, encoding: cp932) ?? String(decoding: slice, as: UTF8.self)
        }
        func utf16(_ s: Int, _ end: Int) -> String {      // 0 終端の UTF-16LE 文字列
            guard s < end, end <= b.count else { return "" }
            var e = s; while e + 1 < end && !(b[e] == 0 && b[e+1] == 0) { e += 2 }
            return String(data: Data(b[s..<e]), encoding: .utf16LittleEndian) ?? ""
        }

        var info = Info()
        let flags = u32(0x14)
        info.isDir = u32(0x18) & 0x10 != 0
        var i = 76
        if flags & 0x01 != 0 { i += 2 + u16(i) }                     // LinkTargetIDList
        if flags & 0x02 != 0 {                                       // LinkInfo
            let s = i, size = u32(i), hsize = u32(i+4), lf = u32(i+8)
            guard size >= 28, s + size <= b.count else { return (nil, L("lnk.err.broken")) }
            let end = s + size
            if lf & 0x01 != 0, u32(s+16) > 0 { info.localPath = ansi(s + u32(s+16), end) }
            if lf & 0x02 != 0, u32(s+20) > 0 {
                let ns = s + u32(s+20), nameOff = u32(ns+8)
                if nameOff > 0 { info.netPath = ansi(ns + nameOff, end) }
            }
            if hsize >= 0x24, u32(s+28) > 0 {                        // Unicode 版のローカルパスがあればそちらを使う
                let u = utf16(s + u32(s+28), end); if !u.isEmpty { info.localPath = u }
            }
            i = end
        }
        func str(_ i: inout Int) -> String {                         // StringData（文字数つき）
            let n = u16(i); i += 2
            if flags & 0x80 != 0 {
                let e = min(i + n * 2, b.count); defer { i = e }
                return String(data: Data(b[min(i, e)..<e]), encoding: .utf16LittleEndian) ?? ""
            }
            let e = min(i + n, b.count); defer { i = e }
            return String(data: Data(b[min(i, e)..<e]), encoding: cp932) ?? ""
        }
        if flags & 0x04 != 0 { _ = str(&i) }                         // 説明
        if flags & 0x08 != 0 { info.relPath = str(&i) }
        if flags & 0x10 != 0 { info.workingDir = str(&i) }
        if flags & 0x20 != 0 { _ = str(&i) }                         // 引数
        if flags & 0x40 != 0 { _ = str(&i) }                         // アイコン
        while i + 8 <= b.count {                                     // ExtraData（作成したマシンの名前）
            let size = u32(i); if size < 8 { break }
            if u32(i+4) == 0xA000_0003, size >= 32 { info.machine = ansi(i + 16, i + 32) }
            i += size
        }
        info.localPath = info.localPath.precomposedStringWithCanonicalMapping
        info.netPath = info.netPath.precomposedStringWithCanonicalMapping
        info.relPath = info.relPath.precomposedStringWithCanonicalMapping
        return (info, nil)
    }

    // MARK: Mac のパスを探す

    enum Found { case exact(String), byName(String, Int), none }

    static func resolve(_ lnk: URL, _ info: Info) -> Found {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        func exists(_ p: String) -> Bool { fm.fileExists(atPath: p) }
        // 1. .lnk の場所からの相対パス
        if !info.relPath.isEmpty {
            let p = (lnk.deletingLastPathComponent().path as NSString)
                .appendingPathComponent(info.relPath.replacingOccurrences(of: "\\", with: "/"))
            let n = (p as NSString).standardizingPath
            if exists(n) { return .exact(n) }
        }
        // 2. クラウドのフォルダ（C:\Dropbox\... → ~/Dropbox/...）
        let win = info.windowsPath.replacingOccurrences(of: "\\", with: "/")
        let cloud = (try? fm.contentsOfDirectory(atPath: home + "/Library/CloudStorage")) ?? []
        func roots(_ key: String) -> [String] {
            switch key {
            case "dropbox": return [home + "/Dropbox"] + cloud.filter { $0.hasPrefix("Dropbox") }.map { home + "/Library/CloudStorage/" + $0 }
            case "onedrive": return cloud.filter { $0.hasPrefix("OneDrive") }.map { home + "/Library/CloudStorage/" + $0 }
            default:
                let g = cloud.filter { $0.hasPrefix("GoogleDrive") }.map { home + "/Library/CloudStorage/" + $0 }
                return g.flatMap { [$0 + "/マイドライブ", $0 + "/My Drive", $0] }
            }
        }
        for key in ["dropbox", "onedrive", "google drive", "googledrive"] {
            guard let r = win.range(of: "/\(key)/", options: .caseInsensitive) else { continue }
            let sub = String(win[r.upperBound...])
            let rk = key.hasPrefix("google") ? "google" : key
            for root in roots(rk) {
                let p = ((root as NSString).appendingPathComponent(sub) as NSString).standardizingPath
                if exists(p) { return .exact(p) }
            }
        }
        // 3. 名前で探す（フォルダを整理して場所が変わったとき）。後ろからパスの名前が多く合うものを選ぶ
        let parts = win.split(separator: "/").map(String.init).filter { !$0.isEmpty && !$0.hasSuffix(":") }
        guard let name = parts.last else { return .none }
        let hits = spotlight(name: name, in: home)
        guard !hits.isEmpty else { return .none }
        func score(_ p: String) -> Int {
            let mp = p.split(separator: "/").map { String($0).precomposedStringWithCanonicalMapping.lowercased() }
            var n = 0
            for (a, b) in zip(mp.reversed(), parts.reversed().map { $0.lowercased() }) { if a == b { n += 1 } else { break } }
            return n
        }
        let best = hits.max { score($0) < score($1) }!
        return .byName(best, hits.count)
    }

    /// Spotlight で同じ名前の項目を探す（~/Dropbox と ~/Library/CloudStorage。最大 3 秒）
    static func spotlight(name: String, in home: String) -> [String] {
        var out: [String] = []
        let q = "kMDItemFSName == \"\(name.replacingOccurrences(of: "\"", with: "\\\""))\"c"
        for dir in [home + "/Dropbox", home + "/Library/CloudStorage"] where FileManager.default.fileExists(atPath: dir) {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            p.arguments = ["-onlyin", dir, q]
            let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { continue }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            out += String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
                .filter { !$0.contains("/.dropbox.cache/") && !$0.contains("/.Trash/") }
        }
        return Array(Set(out)).sorted()
    }

    // MARK: 画面

    static func open(_ urls: [URL]) {
        for u in urls where u.pathExtension.lowercased() == "lnk" { show(u) }
    }

    static func show(_ lnk: URL) {
        let (info, err) = parse(lnk)
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = L("lnk.title", lnk.lastPathComponent)
        guard let info = info else {
            log("LNK: \(lnk.path) → \(err ?? "")")
            a.alertStyle = .critical; a.informativeText = err ?? ""; a.addButton(withTitle: "OK"); a.runModal(); return
        }
        var lines = [L("lnk.kind", info.isDir ? L("lnk.folder") : L("lnk.file")),
                     L("lnk.win", info.windowsPath.isEmpty ? "—" : info.windowsPath)]
        if !info.relPath.isEmpty { lines.append(L("lnk.rel", info.relPath)) }
        if !info.machine.isEmpty { lines.append(L("lnk.machine", info.machine)) }
        let found = resolve(lnk, info)
        var target: String?
        switch found {
        case .exact(let p): target = p; lines.append("\n" + L("lnk.mac", p))
        case .byName(let p, let n):
            target = p
            lines.append("\n" + L("lnk.byName", p))
            if n > 1 { lines.append(L("lnk.byName.more", "\(n)")) }
        case .none: lines.append("\n" + L("lnk.notFound"))
        }
        a.informativeText = lines.joined(separator: "\n")
        log("LNK: \(lnk.lastPathComponent) → \(target ?? "見つからない")")
        if let t = target {
            a.alertStyle = .informational
            a.addButton(withTitle: L("lnk.btn.finder"))
            a.addButton(withTitle: L("lnk.btn.copy"))
            a.addButton(withTitle: L("lnk.btn.cancel"))
            switch a.runModal() {
            case .alertFirstButtonReturn:
                var isDir: ObjCBool = false
                FileManager.default.fileExists(atPath: t, isDirectory: &isDir)
                if isDir.boolValue && !t.hasSuffix(".app") { NSWorkspace.shared.open(URL(fileURLWithPath: t)) }
                else { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: t)]) }
            case .alertSecondButtonReturn: copy(t)
            default: break
            }
        } else {
            a.alertStyle = .warning
            a.addButton(withTitle: L("lnk.btn.copyWin"))
            a.addButton(withTitle: L("lnk.btn.close"))
            if a.runModal() == .alertFirstButtonReturn, !info.windowsPath.isEmpty { copy(info.windowsPath) }
        }
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }

    // MARK: 既定のアプリ

    /// .lnk の既定のアプリを RedGreen にする（初回だけ。旧 LNK解析.app が消えて開けなくなっていたため）
    static func claimDefaultOnce() {
        let key = "lnkDefaultSet"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        guard let t = UTType(filenameExtension: "lnk") else { return }
        NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: t) { e in
            DispatchQueue.main.async {
                if let e = e { log("LNK: 既定のアプリにできなかった（\(t.identifier)）：\(e.localizedDescription)") }
                else { log("LNK: .lnk の既定のアプリを RedGreen にした（\(t.identifier)）"); UserDefaults.standard.set(true, forKey: key) }
            }
        }
    }
}
