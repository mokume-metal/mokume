// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeDiagnostics

/// ウィンドウの持ち主の名乗り 1 件 ([ADR-0049] 決定 2・3)。
///
/// bootstrap の名前を登録し、**登録できてから**目録 (``FrameListing``) に 1 件を置く。受け手は目録を読み、
/// 名前を引けた項目だけを生きているとみなすので、順序を逆にすると、引けない項目が一瞬並ぶ。
///
/// 繋がっていない間の費用は、受信の port 1 本と目録の 1 件だけで、フレームの仕事は増えない。
///
/// | 起こし方 | 名乗る者 |
/// | --- | --- |
/// | 直に走らせる・`run`・束ねた `.app` | ライブラリ (``SketchApplication``) |
/// | `watch` (道具がウィンドウを出せた) | 道具。子は名乗らず、共有面に「断っていない」を載せる |
/// | `watch` の子が自分のウィンドウを持つ回 | その子 (ライブラリ)。道具は名乗らない |
/// | `SketchView`・`render`・ウィンドウを持たない実行 | 名乗らない |
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
package final class FrameAnnouncement {
    /// 名乗っている項目。
    package private(set) var entry: FrameListing.Entry
    /// 置いた置き場。
    let directory: URL
    /// 登録で得た受信の権利。下ろした後は 0。
    private(set) var receivePort: mach_port_t

    private init(entry: FrameListing.Entry, directory: URL, receivePort: mach_port_t) {
        self.entry = entry
        self.directory = directory
        self.receivePort = receivePort
    }

    /// 名乗る。**名乗れなければ `nil`** で、診断に 1 行だけ出して走り続ける (投げない。ADR-0020 決定 5)。
    ///
    /// - Parameters:
    ///   - sketch: 作品名 (product の名前)。
    ///   - identity: 作品を見分ける欄。
    ///   - title: 一覧に見せる名前。
    ///   - width: 受け付ける面の幅 (描く解像度)。分かっていれば最初の 1 件から載せる (#3949)。`nil` なら送り手を起こすときに
    ///     載せる (``startSending(gpu:width:height:startsListening:)``)。
    ///   - height: 同じく高さ。
    ///   - directory: 目録の置き場。
    ///   - warn: 名乗れなかったことを言う口。
    ///   - checkIn: 名前を登録する口。**検査から差し替える** (断られる環境を作るため)。
    package static func announce(
        sketch: String, identity: String, title: String, width: Int? = nil, height: Int? = nil,
        in directory: URL = FrameListing.directory,
        warn: (String) -> Void = { Diagnostics.warn($0) },
        checkIn: (String) -> Result<mach_port_t, Bootstrap.Failure> = Bootstrap.checkIn
    ) -> FrameAnnouncement? {
        let pid = getpid()
        let serviceName = serviceName(pid: pid, window: FrameListing.mainWindow)
        let port: mach_port_t
        switch checkIn(serviceName) {
        case .success(let received): port = received
        case .failure(let failure):
            warn(
                "This sketch cannot list itself for other apps to receive its frames "
                    + "(\(failure)) — it keeps running, and no other app can pick it")
            return nil
        }
        let entry = FrameListing.Entry(
            sketch: sketch, identity: identity, title: title, pid: pid,
            startedAt: ProcessRecord.startTime(of: pid) ?? 0, serviceName: serviceName,
            // 幅と高さは揃って載せる (片方だけの項目は書かない)
            width: height == nil ? nil : width, height: width == nil ? nil : height)
        FrameListing.sweep(in: directory)
        do {
            try FrameListing.place(entry, in: directory)
        } catch {
            Bootstrap.releaseReceive(port)
            warn(
                "This sketch cannot list itself for other apps to receive its frames "
                    + "(\(FrameListing.url(for: serviceName, in: directory).path): "
                    + "\(Diagnostics.reason(error))) — it keeps running, and no other app can pick it")
            return nil
        }
        return FrameAnnouncement(entry: entry, directory: directory, receivePort: port)
    }

    /// bootstrap の名前。**実行ごとに一意**で、pid に起動ごとに変わる値を添え、ウィンドウを含む。
    static func serviceName(pid: pid_t, window: String) -> String {
        let nonce = String(UInt32.random(in: .min ... .max), radix: 16)
        return "org.mokume.frames.\(pid).\(nonce).\(window)"
    }

    /// 作品名と一覧に見せる名前を変える。**bootstrap の名前は変えない** (見張りの子が入れ替わっても、受け手は
    /// 繋ぎ直さない)。変わっていなければ書かない。
    package func update(sketch: String, title: String) {
        guard receivePort != 0, sketch != entry.sketch || title != entry.title else { return }
        entry.sketch = sketch
        entry.title = title
        try? FrameListing.place(entry, in: directory)
    }

    /// 受け付ける面の大きさを目録に載せる ([#3949])。**変わっていなければ書かない。** 下ろした後は何もしない。
    ///
    /// 送り手の大きさが変わると、送り手が `surfaceSize` で断るより前にここが呼ばれる (``FrameSender/onResize``)。だから
    /// 断られた受け手が目録を読み直せば、断った大きさではなく、送り手がいま受け付ける大きさがある。
    ///
    /// [#3949]: https://github.com/mokume-metal/mokume/issues/3949
    package func recordSize(width: Int, height: Int) {
        guard receivePort != 0, width != entry.width || height != entry.height else { return }
        entry.width = width
        entry.height = height
        try? FrameListing.place(entry, in: directory)
    }

    /// 繋いできた受け手へ絵を渡す送り手 ([#3920](https://github.com/mokume-metal/mokume/issues/3920))。起こすまで `nil`。
    package private(set) var sender: FrameSender?

    /// 受け手の頼みを受け始め、送り手を返す。2 度目は同じ送り手を返す。下ろした後は `nil`。
    ///
    /// - Parameters:
    ///   - width: いまの描く解像度 (受け手の面はこの大きさで受け入れる)。目録にも載せ、以後は送り手の大きさが変わるたびに
    ///     書き換える (``recordSize(width:height:)``・#3949)。
    ///   - startsListening: 頼みを main queue で受け始めるか。**検査は `false` にして** ``FrameSender/drain()`` を直に呼ぶ。
    @discardableResult
    package func startSending(
        gpu: RenderDevice, width: Int, height: Int, startsListening: Bool = true
    ) -> FrameSender? {
        guard receivePort != 0 else { return nil }
        if let sender { return sender }
        let sender = FrameSender(gpu: gpu, port: receivePort, width: width, height: height)
        // **頼みを受け始める前に目録の大きさを送り手にそろえる** — 受け手が目録で読む大きさと、送り手が受け付ける大きさを
        // 食い違わせない (#3949)
        recordSize(width: width, height: height)
        sender.onResize = { [weak self] width, height in self?.recordSize(width: width, height: height) }
        if startsListening { sender.start() }
        self.sender = sender
        return sender
    }

    /// 下ろす。目録の項目を消し、送り手を畳み、名前を手放す。2 度目は何もしない。
    ///
    /// **受け手の頼みを受ける口を先に畳む** — 受信の権利を手放した後に main queue の受け口が動くと、死んだ port を読む。
    package func withdraw() {
        guard receivePort != 0 else { return }
        sender?.stop()
        sender = nil
        FrameListing.remove(entry.serviceName, in: directory)
        Bootstrap.releaseReceive(receivePort)
        receivePort = 0
    }

    /// 下ろしたか。
    package var isWithdrawn: Bool { receivePort == 0 }

    deinit {
        // `withdraw()` は main actor に縛られているので、ここでは同じ後始末を直に行う
        if receivePort != 0 {
            FrameListing.remove(entry.serviceName, in: directory)
            Bootstrap.releaseReceive(receivePort)
        }
    }
}

extension FrameAnnouncement {
    /// このプロセスの作品名 (実行ファイルの名前)。
    package static var ownSketchName: String {
        (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments.first ?? "sketch"))
            .lastPathComponent
    }

    /// このプロセスの作品を見分ける欄。`.app` なら bundle identifier、他はパッケージの場所。
    package static var ownIdentity: String {
        if Bundle.main.bundleURL.pathExtension == "app", let identifier = Bundle.main.bundleIdentifier {
            return identifier
        }
        return FrameListing.identity(ofPackageAt: WorkDirectory.base)
    }
}
