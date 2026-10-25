// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Network
import Testing

@testable import MokumeNetwork

/// 受け口 (TCP・WebSocket・OSC・UDP) が開けなかった事情の読み替え。
@Suite("受け口の失敗の読み替え")
nonisolated struct PortListenerEventTests {
    /// POSIX の失敗は、言語の設定に左右されない C の文面で名乗る (#2839)。
    @Test("POSIX の失敗は C の文面、ポートの使用中は portInUse のまま")
    func posixFailuresUseTheOSWords() {
        #expect(
            PortListener.event(for: NWError.posix(.ECONNREFUSED))
                == .failed(String(cString: strerror(ECONNREFUSED))))
        #expect(PortListener.event(for: NWError.posix(.EACCES)) == .failed(String(cString: strerror(EACCES))))
        #expect(PortListener.event(for: NWError.posix(.EADDRINUSE)) == .portInUse)
    }
}
