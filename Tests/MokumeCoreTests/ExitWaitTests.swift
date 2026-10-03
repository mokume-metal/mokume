// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 子の終わりを、実行ループを回さずに待つ口 ([#1937])。
///
/// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
@Suite("子の終わりを待つ")
struct ExitWaitTests {
    /// 糸をまたいで印を受け渡す箱。**呼び手の知らせは別の糸で鳴る**ので鍵を持つ。
    nonisolated final class Mark: @unchecked Sendable {
        private let lock = NSLock()
        private var calls = 0
        var count: Int { lock.withLock { calls } }
        func hit() { lock.withLock { calls += 1 } }
    }

    /// **呼び手が置いた知らせを消さない。** 待つ口は任意の子を受けるので、呼び手が先に
    /// `terminationHandler` を置いていることがある。上書きすると、その知らせが黙って来なくなる。
    @Test("呼び手が置いた終わりの知らせも、待ちが戻るまでに 1 度だけ呼ばれる")
    func keepsTheCallersHandler() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "exit 3"]
        let mark = Mark()
        process.terminationHandler = { _ in mark.hit() }

        let exited = ExitWait(for: process)
        try process.run()
        exited.wait()

        #expect(process.terminationStatus == 3)
        #expect(mark.count == 1, "呼び手の終わりの知らせが呼ばれていない (上書きした)")
    }
}
