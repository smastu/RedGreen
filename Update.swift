import AppKit

/// リモート（origin/master）に新しいコミットがあれば「アップデートあり」をメニューに出す。
/// ビルド時に埋め込んだコミット（RGBuiltCommit）と、git fetch で取った origin/master を比べる。
final class Updater {
    static let shared = Updater()

    /// 組み込み時のコミット（build.sh が Info.plist に書く）
    let built = Bundle.main.object(forInfoDictionaryKey: "RGBuiltCommit") as? String ?? "unknown"
    /// リポジトリの場所（build.sh が Info.plist に書く）
    let repo  = Bundle.main.object(forInfoDictionaryKey: "RGRepoDir") as? String ?? ""

    /// 画面に出す用（メインスレッドでのみ読み書き）
    private(set) var updateAvailable = false
    private(set) var latest = ""
    private var lastCheck = Date.distantPast
    private var checking = false

    /// 起動時に呼ぶ。少し待ってから最初の確認、その後 3 時間ごと。
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.check() }
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { [weak self] _ in self?.check() }
    }

    /// メニューを開いたときに呼ぶ。前回から 30 分以上たっていれば裏で再確認（この回の表示には間に合わないが次に反映）。
    func checkIfStale() {
        if Date().timeIntervalSince(lastCheck) > 1800 { check() }
    }

    func check() {
        guard !checking, !repo.isEmpty,
              FileManager.default.fileExists(atPath: repo + "/.git") else { return }
        checking = true
        lastCheck = Date()
        let repo = self.repo, built = self.built
        DispatchQueue.global(qos: .utility).async { [weak self] in
            // origin/master を取り直して先頭コミットを短縮形で読む
            _ = Updater.git(["-C", repo, "fetch", "-q", "--no-tags", "origin", "master"], repo: repo)
            let remote = Updater.git(["-C", repo, "rev-parse", "--short", "origin/master"], repo: repo)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self?.checking = false
                guard let self, !remote.isEmpty, built != "unknown" else { return }
                self.latest = remote
                let avail = (remote != built)
                self.updateAvailable = avail
                log("アップデート確認: 組込=\(built) 最新=\(remote) → \(avail ? "あり" : "最新")")
            }
        }
    }

    /// クリックされたら build.sh でビルドし直し、終わったら起動し直す。
    func runUpdate() {
        let repo = self.repo
        guard !repo.isEmpty else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let out = Updater.git(["-C", repo, "pull", "-q", "--ff-only", "origin", "master"], repo: repo)
            log("アップデート: pull \(out ?? "")")
            let build = Updater.run("/bin/zsh", [repo + "/build.sh"], repo: repo)
            log("アップデート: build \(build ?? "")")
            DispatchQueue.main.async {
                // 終了を待ってから自分を開き直す（新しい実行ファイルで立ち上がる。-n なしなので 2 つにならない）
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", "while kill -0 \"$1\" 2>/dev/null; do sleep 0.2; done; sleep 0.3; /usr/bin/open -g -a \"$0\"",
                               Bundle.main.bundlePath, "\(ProcessInfo.processInfo.processIdentifier)"]
                try? p.run()
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - プロセス実行
    private static func git(_ args: [String], repo: String) -> String? {
        run("/usr/bin/git", args, repo: repo)
    }
    private static func run(_ tool: String, _ args: [String], repo: String) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe; p.standardError = pipe
        // GUI から起動しても git/ssh が使えるよう PATH を補う
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/local/bin:/opt/homebrew/bin:" + (env["PATH"] ?? "")
        p.environment = env
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
