// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeTestSupport
import Synchronization
import Testing

@testable import MokumeCore

/// 待つ読み込みの口を、**取り消した `Task` から呼んだとき**の今の振る舞いを固定する ([#2920])。
///
/// 口の説明文は、ここで確かめた結果をそのまま書く (仮説で書かない)。**この検査は「止まるべき」を
/// 決めない** — 取消の扱いを変えるのは #2760 と合わせて決める案 B で、ここで見るのは今の事実だけ
/// である。事実が変わったら、この検査が赤くなり、口の説明文も同じ PR で直すことになる。
///
/// - ファイルの名前: 取り消した `Task` から呼んでも、読み終えて値を返す (取消を見ない)
/// - URL の名前: 受け取りが呼んだ `Task` の中で待たれるので、取消が受け口まで届き、
///   ``DataFailure/unreachable(url:reason:)`` で投げる
///
/// 応答は ``CannedResponses`` が予約済みの `.test` の名前で返す。**外のネットワークへ出ない。**
///
/// [#2920]: https://github.com/mokume-metal/mokume/issues/2920
@Suite("取り消した Task から待つ読み込みを呼ぶ")
struct RequestCancellationTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    /// 呼んだ時点で取り消されている `Task` の中で `work` を走らせ、結果と、`work` が終わった
    /// 後も取り消されたままだったかを返す。
    ///
    /// **`Task` は起こした直後に取り消す。** 本体は main actor に載るので、この関数が待つまで
    /// 走り出さない — 入った時点で取り消されていることを、本体の先頭で確かめる。
    private func runCancelled<Value: Sendable>(
        _ work: @escaping () async -> Value
    ) async -> (value: Value, enteredCancelled: Bool) {
        let task = Task { () -> (Value, Bool) in
            let entered = Task.isCancelled
            return (await work(), entered)
        }
        task.cancel()
        let (value, entered) = await task.value
        return (value, entered)
    }

    private func writeFile(_ name: String, _ text: String) throws -> String {
        let folder = TestScratch.path("mokume-cancel")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try Data(text.utf8).write(to: url)
        return url.path
    }

    // MARK: - ファイルの名前

    @Test("ファイルは、取り消した Task から呼んでも読み終えて値を返す (文字・表・JSON・XML)")
    func filesAreReadDespiteCancellation() async throws {
        let text = try writeFile("poem.txt", "one\ntwo\n")
        let csv = try writeFile("t.csv", "a,b\n1,2\n")
        let object = try writeFile("o.json", #"{"n": 3}"#)
        let array = try writeFile("a.json", "[1, 2, 3]")
        let xml = try writeFile("x.xml", #"<sky><star size="2"/></sky>"#)
        let sketch = Bare()

        let strings = await runCancelled { try? await sketch.requestStrings(text) }
        #expect(strings.enteredCancelled, "取り消した Task から呼べていない")
        #expect(strings.value == ["one", "two"])

        let table = await runCancelled { try? await sketch.requestTable(csv, header: true) }
        #expect(table.enteredCancelled)
        #expect(table.value?.rows.count == 1)

        let obj = await runCancelled { try? await sketch.requestJSONObject(object) }
        #expect(obj.enteredCancelled)
        #expect(obj.value?.getInt("n") == 3)

        let arr = await runCancelled { try? await sketch.requestJSONArray(array) }
        #expect(arr.enteredCancelled)
        #expect(arr.value?.count == 3)

        let tree = await runCancelled { try? await sketch.requestXML(xml) }
        #expect(tree.enteredCancelled)
        #expect(tree.value?.getChildren("star").count == 1)
    }

    @Test("ファイルの失敗も、取り消しの有無によらず同じ (見つからない)")
    func fileFailuresAreTheSameWhenCancelled() async {
        let name = "no-such-\(UUID().uuidString).txt"
        let sketch = Bare()
        let plain = await Self.outcome(of: name, sketch: sketch)
        let cancelled = await runCancelled { await Self.outcome(of: name, sketch: sketch) }
        #expect(plain != nil)
        #expect(cancelled.value == plain, "取り消すと失敗の姿が変わっている")
        if case .notFound? = cancelled.value {} else {
            Issue.record("notFound ではない: \(String(describing: cancelled.value))")
        }
    }

    // MARK: - URL の名前

    /// 受け取りの結果を、値か失敗の 1 文にする。
    private static func outcome(of url: String, sketch: Sketch) async -> DataFailure? {
        do {
            _ = try await sketch.requestStrings(url)
            return nil
        } catch {
            return error
        }
    }

    @Test("URL は、取り消した Task から呼ぶと、受け取らずに unreachable で投げる")
    func urlRequestFromACancelledTaskThrowsUnreachable() async throws {
        // 応答は返す側が用意してある。取消が効かなければ値が返る
        let url = CannedResponses.serve("one\ntwo\n")
        let sketch = Bare()
        let result = await runCancelled { await Self.outcome(of: url, sketch: sketch) }
        #expect(result.enteredCancelled)
        let failure = try #require(result.value, "取り消した Task からでも受け取れている")
        guard case .unreachable(let named, let reason) = failure else {
            Issue.record("unreachable ではない: \(failure)")
            return
        }
        #expect(named == url)
        #expect(reason == "cancelled", "理由が受け口の「取り消した」になっていない: \(reason)")
    }

    @Test("URL は、待っている最中に Task を取り消すと、受け口まで届いて unreachable で投げる")
    func cancellingWhileWaitingReachesTheSession() async throws {
        // 何も返さない応答。取消が届かなければ、見張りが切るまで返らない
        let url = CannedResponses.serve(.silent)
        let cutByWatchdog = Mutex(false)
        let watchdog = Task.detached {
            try? await Task.sleep(for: .seconds(20))
            if Task.isCancelled { return }
            cutByWatchdog.withLock { $0 = true }
            CannedResponses.cut(url)
        }
        defer { watchdog.cancel() }

        let sketch = Bare()
        let task = Task { await Self.outcome(of: url, sketch: sketch) }
        // 受け取りが始まるのを待つ (受け口が口を開いたかは外から見えないので、短く待つ)
        try await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let failure = await task.value

        #expect(!cutByWatchdog.withLock { $0 }, "取消が届かず、見張りが切るまで待っていた")
        guard case .unreachable(let named, let reason)? = failure else {
            Issue.record("unreachable ではない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        #expect(reason == "cancelled", "理由が受け口の「取り消した」になっていない: \(reason)")
        // 受け口が応答を止めた (取り消した受け取りは、続きを待たない)
        let deadline = ContinuousClock.now + .seconds(5)
        while !CannedResponses.stopped(url), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(CannedResponses.stopped(url))
    }
}
