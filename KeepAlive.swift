import AppKit

// MARK: - 落ちたら起動し直す（keep_alive.txt に書いたアプリだけ。初期値は空）
// アプリが勝手に終了したとき（クラッシュ・自分で落ちた）だけ、3 秒後に裏で起動し直す。
// 利用者や RedGreen が終了させたときは起動し直さない：
//   ⌘Q・メニューの「終了」（終了の瞬間に前面だった）、Dock のメニュー、強制終了（アクティビティモニタ等が前面）、
//   RedGreen の自動終了・まとめて終了・赤ボタン、ログアウト・再起動・システム終了
// 起動し直しは 1 つのアプリにつき 10 分に 3 回まで（起動してすぐ落ちる場合に繰り返さない）

let keepAliveFile = supportDir.appendingPathComponent("keep_alive.txt")
var defaultKeepAlive: String { L("file.keepAlive.header") + "\n" }

extension NSRunningApplication {
    /// RedGreen から終了させる（落ちたとは見なさない）
    @discardableResult func rgTerminate() -> Bool {
        KeepAlive.shared.intended(processIdentifier)
        return terminate()
    }
}

final class KeepAlive {
    static let shared = KeepAlive()

    private var intendedAt: [pid_t: Date] = [:]   // 終了させる意図があった時刻
    private var front: pid_t = 0                   // 今前面のアプリ
    private var prevFront: pid_t = 0               // 直前に前面だったアプリ（終了の直前に前面が移ることがある）
    private var frontChangedAt = Date.distantPast
    private var dockClickAt = Date.distantPast
    private var poweringOff = false
    private var restarts: [String: [Date]] = [:]
    private(set) var recent: [String] = []

    /// 書かれた行：「アプリ」または「アプリ => 起動し直すコマンド」（2026-11-11）
    /// コマンドつきは、裏で動くサービス（例：Chrome リモート デスクトップ）向け。アプリ本体を開くのではなく、
    /// そのコマンド（/bin/sh -c）で起動し直す。サービスは前面に出ないので、前面・Dock・強制終了の判定はしない
    private static func entries() -> [(app: String, command: String?)] {
        if !FileManager.default.fileExists(atPath: keepAliveFile.path) {
            try? defaultKeepAlive.write(to: keepAliveFile, atomically: true, encoding: .utf8)
        }
        let t = (try? String(contentsOf: keepAliveFile, encoding: .utf8)) ?? ""
        return t.split(separator: "\n").compactMap { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { return nil }
            let parts = line.components(separatedBy: "=>")
            let app = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
            let cmd = parts.count > 1 ? parts.dropFirst().joined(separator: "=>").trimmingCharacters(in: .whitespaces) : ""
            return app.isEmpty ? nil : (app, cmd.isEmpty ? nil : cmd)
        }
    }

    static func list() -> Set<String> { Set(entries().map { $0.app }) }

    /// コマンドつき（裏のサービス）は、終了の知らせ（didTerminateApplication）が届かないことがある
    /// （Chrome リモート デスクトップの本体は launchd が起動するので知らせの対象外）。30 秒ごとに動いているか確かめ、
    /// 一度でも動いているのを見たのに今は無ければ、コマンドで起動し直す（10 分に 3 回まで）
    private var seenRunning: Set<String> = []
    private func pollServices() {
        let apps = NSWorkspace.shared.runningApplications
        for e in KeepAlive.entries() {
            guard let command = e.command else { continue }
            if apps.contains(where: { Prefs.matches($0, [e.app]) }) { seenRunning.insert(e.app); continue }
            guard seenRunning.contains(e.app), !poweringOff else { continue }
            let times = (restarts[e.app] ?? []).filter { Date().timeIntervalSince($0) < 600 }
            guard times.count < 3 else { continue }
            restarts[e.app] = times + [Date()]
            log("落ちたら起動：\(e.app) が動いていない。コマンドで起動し直す" + (times.count == 2 ? "（10 分で 3 回目。これでも落ちるなら 10 分待つ）" : ""))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/bin/sh")
            p.arguments = ["-c", command]
            p.terminationHandler = { pr in
                DispatchQueue.main.async { log("落ちたら起動：\(e.app) のコマンドが終わった（終了コード \(pr.terminationStatus)）") }
            }
            do { try p.run() } catch { log("落ちたら起動：\(e.app) のコマンドを実行できない（\(error.localizedDescription)）") }
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            recent.insert("\(df.string(from: Date())) \(e.app)", at: 0)
            recent = Array(recent.prefix(5))
        }
    }

    /// このアプリに起動し直すコマンドが書かれていればそれを返す
    static func command(for a: NSRunningApplication) -> String? {
        for e in entries() where e.command != nil && Prefs.matches(a, [e.app]) { return e.command }
        return nil
    }

    func intended(_ pid: pid_t) { intendedAt[pid] = Date() }

    /// イベントタップから：⌘Q は前面のアプリを終了させる意図
    func keyDown(_ event: CGEvent) {
        if event.getIntegerValueField(.keyboardEventKeycode) == 12, event.flags.contains(.maskCommand) {
            intended(front)
        }
    }

    /// イベントタップから：Dock を押した（Dock のメニューの「終了」かもしれない）
    func clicked(pid: pid_t) {
        if NSRunningApplication(processIdentifier: pid)?.bundleIdentifier == "com.apple.dock" { dockClickAt = Date() }
    }

    func start() {
        _ = KeepAlive.list()
        pollServices()
        Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.pollServices() }
        front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let nc = NSWorkspace.shared.notificationCenter
        nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let self, let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self.prevFront = self.front; self.frontChangedAt = Date(); self.front = a.processIdentifier
        }
        nc.addObserver(forName: NSWorkspace.willPowerOffNotification, object: nil, queue: .main) { [weak self] _ in
            self?.poweringOff = true
        }
        nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            guard let a = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.terminated(a)
        }
    }

    private func terminated(_ a: NSRunningApplication) {
        let pid = a.processIdentifier
        let wasIntended = intendedAt.removeValue(forKey: pid).map { Date().timeIntervalSince($0) < 30 } ?? false
        intendedAt = intendedAt.filter { Date().timeIntervalSince($0.value) < 60 }
        guard !poweringOff, let url = a.bundleURL, Prefs.matches(a, KeepAlive.list()) else { return }
        let name = a.localizedName ?? "?"
        let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? ""
        let command = KeepAlive.command(for: a)
        let why: String? =
            wasIntended ? "終了の操作があった" :
            command != nil ? nil :   // 裏のサービス：画面がロック中（前面が loginwindow）でも起動し直す
            front == pid || (prevFront == pid && Date().timeIntervalSince(frontChangedAt) < 2) ? "前面で終了した（⌘Q・メニュー）" :
            Date().timeIntervalSince(dockClickAt) < 10 ? "Dock から終了した" :
            ["com.apple.ActivityMonitor", "com.apple.loginwindow"].contains(frontID) ? "強制終了" : nil
        if let why { log("落ちたら起動：\(name) は起動し直さない（\(why)）"); return }
        let key = a.bundleIdentifier ?? name
        let times = (restarts[key] ?? []).filter { Date().timeIntervalSince($0) < 600 }
        guard times.count < 3 else { log("落ちたら起動：\(name) は 10 分に 3 回落ちたので、起動し直すのをやめる"); return }
        restarts[key] = times + [Date()]
        log("落ちたら起動：\(name) が終了した。3 秒後に起動し直す")
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            guard NSRunningApplication.runningApplications(withBundleIdentifier: a.bundleIdentifier ?? "").isEmpty else { return }
            if let command {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", command]
                p.terminationHandler = { pr in
                    DispatchQueue.main.async { log("落ちたら起動：\(name) をコマンドで起動し直した（終了コード \(pr.terminationStatus)）") }
                }
                do { try p.run() } catch { log("落ちたら起動：\(name) のコマンドを実行できない（\(error.localizedDescription)）") }
                let df = DateFormatter(); df.dateFormat = "HH:mm"
                self?.recent.insert("\(df.string(from: Date())) \(name)", at: 0)
                self?.recent = Array(self?.recent.prefix(5) ?? [])
                return
            }
            let conf = NSWorkspace.OpenConfiguration()
            conf.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: conf) { _, err in
                log("落ちたら起動：\(name) を起動し直した\(err.map { "（失敗：\($0.localizedDescription)）" } ?? "")")
            }
            let df = DateFormatter(); df.dateFormat = "HH:mm"
            self?.recent.insert("\(df.string(from: Date())) \(name)", at: 0)
            self?.recent = Array(self?.recent.prefix(5) ?? [])
        }
    }
}
