import Cocoa

/// アドレス欄のパス補完（Windows のエクスプローラーのアドレス欄風）
/// 入力中のフォルダの中身から、名前が前方一致するものを欄の上に一覧で出す
final class PathCompleter: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private let panel: NSPanel
    private let table = NSTableView()
    private let scroll = NSScrollView()
    private(set) var items: [(name: String, path: String, isDir: Bool)] = []
    /// 一覧から選んだときに欄へ入れる（選んだ項目のフルパス、フォルダなら末尾に /）
    var onPick: ((String) -> Void)?
    private let rowH: CGFloat = 20
    private let maxRows = 12

    var isShown: Bool { panel.isVisible }
    var selected: Int { table.selectedRow }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 100),
                        styleMask: [.nonactivatingPanel, .borderless], backing: .buffered, defer: true)
        super.init()
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient, .ignoresCycle]

        let bg = NSVisualEffectView()
        bg.material = .menu
        bg.state = .active
        bg.wantsLayer = true
        bg.layer?.cornerRadius = 7
        bg.layer?.borderWidth = 1
        bg.layer?.borderColor = NSColor.separatorColor.cgColor
        panel.contentView = bg

        let col = NSTableColumn(identifier: .init("c"))
        table.addTableColumn(col)
        table.headerView = nil
        table.rowHeight = rowH
        table.intercellSpacing = .zero
        table.backgroundColor = .clear
        table.style = .plain
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)
        table.refusesFirstResponder = true

        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        bg.addSubview(scroll)
        NSLayoutConstraint.activate([
            scroll.leadingAnchor.constraint(equalTo: bg.leadingAnchor, constant: 4),
            scroll.trailingAnchor.constraint(equalTo: bg.trailingAnchor, constant: -4),
            scroll.topAnchor.constraint(equalTo: bg.topAnchor, constant: 4),
            scroll.bottomAnchor.constraint(equalTo: bg.bottomAnchor, constant: -4),
        ])
    }

    /// 入力中の文字列から候補を作る。返すのは候補の一覧
    static func candidates(for text: String, limit: Int = 200) -> [(name: String, path: String, isDir: Bool)] {
        guard !text.isEmpty else { return [] }
        let expanded = (text as NSString).expandingTildeInPath
        let dir: String, prefix: String
        if expanded.hasSuffix("/") {
            dir = expanded; prefix = ""
        } else {
            dir = (expanded as NSString).deletingLastPathComponent
            prefix = (expanded as NSString).lastPathComponent
        }
        guard !dir.isEmpty,
              let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
        let key = norm(prefix)
        let showHidden = prefix.hasPrefix(".")
        var out: [(name: String, path: String, isDir: Bool)] = []
        for n in names {
            if !showHidden && n.hasPrefix(".") { continue }
            if !key.isEmpty && !norm(n).hasPrefix(key) { continue }
            let full = (dir as NSString).appendingPathComponent(n)
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: full, isDirectory: &isDir)
            // パッケージ（.app など）はファイル扱い
            let dirLike = isDir.boolValue && !NSWorkspace.shared.isFilePackage(atPath: full)
            out.append((n.precomposedStringWithCanonicalMapping, full, dirLike))
            if out.count >= limit { break }
        }
        out.sort { a, b in
            if a.isDir != b.isDir { return a.isDir }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
        return out
    }

    /// 日本語の濁点などの表記ゆれ（NFD／NFC）と大文字・小文字をそろえる
    static func norm(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.lowercased()
    }

    /// 候補をそろえて、欄（anchor：画面座標）の上に出す
    func show(_ list: [(name: String, path: String, isDir: Bool)], above anchor: NSRect, parent: NSWindow) {
        items = list
        guard !items.isEmpty else { hide(); return }
        table.reloadData()
        table.deselectAll(nil)
        let h = CGFloat(min(items.count, maxRows)) * rowH + 8
        var y = anchor.maxY + 2
        // 上に入らなければ下に出す
        if let scr = parent.screen ?? NSScreen.main, y + h > scr.visibleFrame.maxY { y = anchor.minY - h - 2 }
        panel.setFrame(NSRect(x: anchor.minX, y: y, width: min(anchor.width, 560), height: h), display: true)
        table.tableColumns.first?.width = panel.frame.width - 8
        table.scrollRowToVisible(0)
        if panel.parent == nil { parent.addChildWindow(panel, ordered: .above) }
        panel.orderFront(nil)
    }

    func hide() {
        if let p = panel.parent { p.removeChildWindow(panel) }
        panel.orderOut(nil)
        items = []
    }

    /// ↑↓で選ぶ。選んだ項目のパスを返す
    func move(_ d: Int) -> String? {
        guard !items.isEmpty else { return nil }
        var i = table.selectedRow + d
        if table.selectedRow < 0 { i = d > 0 ? 0 : items.count - 1 }
        i = max(0, min(items.count - 1, i))
        table.selectRowIndexes([i], byExtendingSelection: false)
        table.scrollRowToVisible(i)
        return display(i)
    }

    /// 欄に入れる文字列（フォルダなら末尾に /）
    func display(_ i: Int) -> String {
        let it = items[i]
        return it.isDir ? it.path + "/" : it.path
    }

    @objc private func clicked() {
        let r = table.clickedRow
        guard r >= 0, r < items.count else { return }
        onPick?(display(r))
    }

    // MARK: 表

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("cell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView ?? {
            let c = NSTableCellView()
            c.identifier = id
            let iv = NSImageView()
            let tf = NSTextField(labelWithString: "")
            tf.font = .systemFont(ofSize: 12)
            tf.lineBreakMode = .byTruncatingMiddle
            iv.translatesAutoresizingMaskIntoConstraints = false
            tf.translatesAutoresizingMaskIntoConstraints = false
            c.addSubview(iv); c.addSubview(tf)
            c.imageView = iv; c.textField = tf
            NSLayoutConstraint.activate([
                iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
                iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                iv.widthAnchor.constraint(equalToConstant: 16), iv.heightAnchor.constraint(equalToConstant: 16),
                tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 6),
                tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
                tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
            ])
            return c
        }()
        let it = items[row]
        cell.textField?.stringValue = it.isDir ? it.name + "/" : it.name
        cell.imageView?.image = NSWorkspace.shared.icon(forFile: it.path)
        return cell
    }
}

extension String {
    /// 文字列の配列に共通する先頭部分（大文字・小文字は区別しない比較で、表記は最初のものを使う）
    static func commonPrefix(_ list: [String]) -> String {
        guard var p = list.first else { return "" }
        for s in list.dropFirst() {
            var n = 0
            for (a, b) in zip(p, s) {
                if String(a).lowercased() != String(b).lowercased() { break }
                n += 1
            }
            p = String(p.prefix(n))
        }
        return p
    }
}
