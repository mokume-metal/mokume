// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// `run --remote` / `watch --remote`: スケッチの `@Param` のつまみを、同じネットワークのスマホのブラウザから
/// 動かせるようにする旗 (値を取らない)。
///
/// ローカルでの簡単なデモとプロトタイプのためのもので、`.app` (`bundle`) では使えない — 受け口を持つのは
/// 道具 (このプロセス) で、スケッチではないからである。本格的にスマホと連動させる作品は、専用の
/// アプリで連携を組む (#4126)。
enum RemoteOption {
    static let flag = "--remote"

    /// 選択肢の宣言。
    @MainActor static var options: [Arguments.Option] {
        [Arguments.Option([flag], isSwitch: true) { "\($0) takes no value" }]
    }

    /// 旗が付いているか。
    static func requested(in values: [String: String]) -> Bool { values[flag] != nil }
}

/// 開いた受け口と、案内に出した URL。`run` と `watch` が 1 つずつ持つ。
final class RemoteSession {
    let server: RemoteServer
    /// スマホに読ませる URL (QR に載せるもの)。LAN のアドレスが無ければ `localhost`。
    let url: String
    /// `url` の QR コード。作れなければ `nil`。
    let qr: QRCode?

    private init(server: RemoteServer, url: String, qr: QRCode?) {
        self.server = server
        self.url = url
        self.qr = qr
    }

    /// 受け口を開いて、端末に案内 (URL と QR) を出す。**開けなくても投げない** — スケッチはそのまま
    /// 走らせ、開けなかった理由を言う (つまみはスマホから動かせないだけで、作品は動く)。
    ///
    /// - Parameters:
    ///   - facet: つまみの面の区画 (`.mokume/params`)。在ることは呼び手が確かめる。
    ///   - say: 案内を書く口。
    static func open(facet: URL, say: (String) -> Void) -> RemoteSession? {
        let server = RemoteServer(facet: facet)
        let opened = OpeningBox()
        server.start { opened.set($0) }
        switch opened.wait(seconds: 5) {
        case .ready(let port):
            let addresses = LANAddresses.current()
            let urls = (addresses.isEmpty ? ["localhost"] : addresses).map {
                "http://\($0):\(port)/?t=\(server.token)"
            }
            let qr = QRCode(urls[0])
            for line in guidance(urls: urls, foundLAN: !addresses.isEmpty, qr: qr) { say(line) }
            return RemoteSession(server: server, url: urls[0], qr: qr)
        case .failed(let reason):
            server.stop()
            say("Remote knobs are off: the tool could not open a port for the phone (\(reason))")
            return nil
        case nil:
            server.stop()
            say("Remote knobs are off: opening a port for the phone did not finish in 5 seconds")
            return nil
        }
    }

    /// 端末に出す案内。
    static func guidance(
        urls: [String], foundLAN: Bool, qr: QRCode?, colored: Bool = isatty(STDOUT_FILENO) != 0
    ) -> [String] {
        var lines: [String] = []
        if foundLAN {
            lines.append("Remote knobs: scan the code with a phone on the same network, or open")
        } else {
            lines.append(
                "Remote knobs: no network address was found for a phone to reach (is Wi-Fi on?). "
                    + "On this Mac, open")
        }
        lines += urls.map { "  \($0)" }
        if foundLAN, let qr { lines += qr.terminalLines(colored: colored) }
        return lines
    }

    /// 閉じる。
    func stop() { server.stop() }

    /// 開いた結果を、呼んだ糸で待つための箱。
    private nonisolated final class OpeningBox: @unchecked Sendable {
        private let done = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var value: RemoteServer.Opening?

        func set(_ opening: RemoteServer.Opening) {
            lock.lock()
            value = opening
            lock.unlock()
            done.signal()
        }

        func wait(seconds: Double) -> RemoteServer.Opening? {
            guard done.wait(timeout: .now() + seconds) == .success else { return nil }
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }
}
