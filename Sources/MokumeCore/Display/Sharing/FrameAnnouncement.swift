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
    ///   - directory: 目録の置き場。
    ///   - warn: 名乗れなかったことを言う口。
    ///   - checkIn: 名前を登録する口。**検査から差し替える** (断られる環境を作るため)。
    package static func announce(
        sketch: String, identity: String, title: String,
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
            startedAt: ProcessRecord.startTime(of: pid) ?? 0, serviceName: serviceName)
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

    /// 下ろす。目録の項目を消し、名前を手放す。2 度目は何もしない。
    package func withdraw() {
        guard receivePort != 0 else { return }
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
