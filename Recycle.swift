import Cocoa

/// 歯止め：メモリが上限を超え、しばらく操作が無いときに自分を起動し直す（起動直後の約 15MB に戻す）。
/// ⌘Tab の一覧・Finder のアドレス欄の編集・切り取り待ちの最中には起動し直さない。
/// 調査用に環境変数 RG_NO_RECYCLE=1 で止められる。
final class Recycler {
    static let shared = Recycler()
    let limitMB = 25.0
    let idleSec = 60.0
    private var timer: Timer?

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
        guard ProcessInfo.processInfo.environment["RG_NO_RECYCLE"] == nil, timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            autoreleasepool { self?.check() }
        }
    }

    private func check() {
        let mb = Recycler.footprintMB()
        guard mb > limitMB else { return }
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
