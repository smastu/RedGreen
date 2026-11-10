//  FinderAE.swift
//  Finder への問い合わせ・命令を、AppleScript の文を使わず Apple Event で直接送る。
//  NSAppleScript は文を解釈するたびに macOS が安全検査（YARA の規則一式、約 14MB）を読み込み、
//  それが RedGreen のメモリに居座るため使わない。

import AppKit

struct AEError: Error { let code: Int }

enum FinderAE {
    private static func code(_ s: String) -> FourCharCode {
        s.utf8.reduce(0) { ($0 << 8) | FourCharCode($1) }
    }

    /// 対象の指定（「Finder window 1 の target」など）を作る
    private static func spec(want: String, from: NSAppleEventDescriptor?, form: String, seld: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let r = NSAppleEventDescriptor.record()
        r.setDescriptor(NSAppleEventDescriptor(typeCode: code(want)), forKeyword: code("want"))
        r.setDescriptor(from ?? NSAppleEventDescriptor.null(), forKeyword: code("from"))
        r.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        r.setDescriptor(seld, forKeyword: code("seld"))
        return r.coerce(toDescriptorType: code("obj ")) ?? r
    }
    private static func prop(_ p: String, of from: NSAppleEventDescriptor?) -> NSAppleEventDescriptor {
        spec(want: "prop", from: from, form: "prop", seld: NSAppleEventDescriptor(typeCode: code(p)))
    }
    private static var window1: NSAppleEventDescriptor {
        spec(want: "brow", from: nil, form: "indx", seld: NSAppleEventDescriptor(int32: 1))
    }

    /// 送って返事を待つ。失敗したら OSStatus（-1743 は自動操作の許可がない）
    private static func send(_ cls: String, _ id: String, direct: NSAppleEventDescriptor?,
                             params: [(String, NSAppleEventDescriptor)] = []) -> Result<NSAppleEventDescriptor, AEError> {
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        let ev = NSAppleEventDescriptor(eventClass: code(cls), eventID: code(id), targetDescriptor: target,
                                        returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
        if let direct { ev.setParam(direct, forKeyword: code("----")) }
        for (k, v) in params { ev.setParam(v, forKeyword: code(k)) }
        do {
            let r = try ev.sendEvent(options: [.waitForReply], timeout: 3)
            if let e = r.paramDescriptor(forKeyword: code("errn")), e.int32Value != 0 { return .failure(AEError(code: Int(e.int32Value))) }
            return .success(r.paramDescriptor(forKeyword: code("----")) ?? NSAppleEventDescriptor.null())
        } catch {
            return .failure(AEError(code: (error as NSError).code))
        }
    }

    /// 前面の Finder 窓のフォルダ（場所のない窓は nil）
    static func frontTarget() -> Result<String?, AEError> {
        send("core", "getd", direct: prop("fvtg", of: window1),
             params: [("rtyp", NSAppleEventDescriptor(typeCode: code("furl")))])
            .map { $0.fileURLValue?.path }
    }

    /// 前面の Finder 窓をこのフォルダへ移動する
    static func setFrontTarget(_ path: String) -> Bool {
        guard let d = NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path)) as NSAppleEventDescriptor? else { return false }
        if case .success = send("core", "setd", direct: prop("fvtg", of: window1), params: [("data", d)]) { return true }
        return false
    }

    /// 新しい Finder 窓を開く（path があればそのフォルダ）。Apple Event で頼むと Finder は前に出てこない
    /// （Dock や NSWorkspace で開くと Finder の窓がすべて前に出てしまう）
    static func newWindow(_ path: String?) -> Bool {
        var params: [(String, NSAppleEventDescriptor)] = [("kocl", NSAppleEventDescriptor(typeCode: code("brow")))]
        if let path, let d = NSAppleEventDescriptor(fileURL: URL(fileURLWithPath: path)) as NSAppleEventDescriptor? {
            params.append(("to  ", d))
        }
        if case .success = send("core", "crel", direct: nil, params: params) { return true }
        return false
    }

    /// Finder で選んでいる項目の名前（何も選んでいなければ空）
    static func selectionNames() -> Result<[String], AEError> {
        send("core", "getd", direct: prop("sele", of: nil)).flatMap { d in
            let items: [NSAppleEventDescriptor] = d.descriptorType == code("list")
                ? (d.numberOfItems > 0 ? (1...d.numberOfItems).compactMap { d.atIndex($0) } : [])
                : (d.descriptorType == code("null") ? [] : [d])
            var names: [String] = []
            for it in items {
                switch send("core", "getd", direct: prop("pnam", of: it)) {
                case .success(let n): if let s = n.stringValue { names.append(s) }
                case .failure(let e): return .failure(e)
                }
            }
            return .success(names)
        }
    }
}
