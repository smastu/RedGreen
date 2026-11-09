import Cocoa

/// 歯止め：メモリが上限を超え、しばらく操作が無いときに自分を起動し直す（起動直後の約 15MB に戻す）。
/// ⌘Tab の一覧・Finder のアドレス欄の編集・切り取り待ちの最中には起動し直さない。
/// 調査用に環境変数 RG_NO_RECYCLE=1 で止められる。
final class Recycler {
    static let shared = Recycler()
    let limitMB = 25.0
    let idleSec = 60.0
    private var timer: Timer?
    private var lastMB = 0.0

    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var n = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &n)
            }
        }
        return kr == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : 0
    }

    func start() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            autoreleasepool { self?.check() }
        }
    }

    private func check() {
        let mb = Recycler.footprintMB()
        // どの操作のあとに増えたかを後で突き止めるため、30 秒で 2MB 以上増えたら記録する
        if lastMB > 0, mb - lastMB >= 2 { log(String(format: "メモリが増えた：%.1f → %.1f MB", lastMB, mb)) }
        lastMB = mb
        guard mb > limitMB, ProcessInfo.processInfo.environment["RG_NO_RECYCLE"] == nil else { return }
        let anyInput = CGEventType(rawValue: ~0)!
        let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: anyInput)
        guard idle >= idleSec, !Switcher.shared.active, !FinderBar.shared.isEditing, CutPaste.shared.isIdle,
              NSApp.modalWindow == nil else { return }
        log(L("log.recycle", String(format: "%.0f", mb), String(format: "%.0f", limitMB)))
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n -a \"$0\"", Bundle.main.bundlePath]
        do { try p.run() } catch { return }
        Switcher.shared.restoreSystemHotKeys()
        exit(0)
    }
}

/// 調査用：操作の前のメモリを覚え、2 秒後に 1MB 以上増えていたら操作名を添えて記録する
private var memMarkBusy: Set<String> = []
func memMark(_ label: String) {
    guard !memMarkBusy.contains(label) else { return }
    memMarkBusy.insert(label)
    let before = Recycler.footprintMB()
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        memMarkBusy.remove(label)
        let after = Recycler.footprintMB()
        if after - before >= 1 { log(String(format: "メモリ +%.1f MB：%@ のあと", after - before, label)) }
    }
}
