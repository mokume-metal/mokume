// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import Foundation
import Testing

@testable import MokumeCore

/// 1 プロセスで 2 つ目の ``SketchApplication/run()`` を呼ぶ ([#2027])。
///
/// **2 つ目は、プロセス全体の状態に触れずに戻る。** delegate・活動の方針・終わりの合図は
/// プロセスに 1 つで、2 つ目が差し替えると、1 つ目の後始末 (書き切りを待つ経路・[#1219]) が
/// 2 つ目へ行き、1 つ目が撮っていた動画が開けないまま残った。
///
/// **終わり方で判定する** (exit test)。1 つ目の ``SketchApplication/run()`` は戻らず、終わりは
/// プロセスの終わりなので、検査は子のプロセスで走らせ、終了コードを読む。子は自分で期限を持つ
/// — 固まっても、期限を越えたら自分で終わる (``SecondRunChild/deadlineSeconds``)。
///
/// [#1219]: https://github.com/mokume-metal/mokume/issues/1219
/// [#2027]: https://github.com/mokume-metal/mokume/issues/2027
@Suite(
    "2 つ目の run()",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする"),
    .enabled(
        if: MovieFile.isAvailable,
        "この機械には ProRes 4444 の符号化器が無い")
)
struct SecondRunTests {
    /// 終了コードの読み方。**終わり方が期待と違うと、子の標準エラーは返らない** (`#expect` が
    /// 結果を `nil` で返す) ので、何が起きたかは終了コードから引く。
    static let exitCodes: Comment = """
        終了コードの意味は SecondRunChild.Failure \
        (1: 動画に目次が無い・2: 1 つ目を組めない・3: 期限切れ・4: プロセス全体の状態が変わった・\
        5: 2 つ目が戻らない・6: 止めて戻った後の run() が断った)
        """

    /// 起票時の再現 (probes の `secondApplication`) と同じ形。**道具と同じ合図 (SIGTERM) で終わらせ、
    /// 残った `.mov` に目次 (`moov`) が在るかを見る。** 2 つ目は 2 回呼び、断りの 1 行が 1 度だけ
    /// 出ることも見る。
    @Test("2 つ目の run() は、1 つ目が撮っている動画を、合図で終わっても開けるまま残す")
    func firstRecordingSurvivesASecondRun() async throws {
        let result = await #expect(
            processExitsWith: .success, observing: [\.standardErrorContent], Self.exitCodes
        ) {
            await SecondRunChild.recordThenStop()
        }
        // 終わり方が違えば、赤は上の `#expect` が記録済みである
        guard let result else { return }
        let errors = String(decoding: result.standardErrorContent, as: UTF8.self)
        let refusals = errors.split(separator: "\n").filter {
            $0.contains(SketchApplication.secondRunRefusal)
        }
        #expect(refusals.count == 1, "断りの 1 行が 1 度だけ出ていない。標準エラー:\n\(errors)")
    }

    /// **`Sketch.main()` で 2 つ目を起こす** (Processing の `PApplet.main` に最も近い書き方)。2 つ目は
    /// 組み立てが投げる (`frameRate: 0`) — 投げると `main()` は `exit(1)` で落ちるので、組み立てより
    /// 前に断らないと、1 つ目の後始末を飛ばして `.mov` が開けないまま残る。
    @Test("Sketch.main() で起こした 2 つ目も、組み立てる前に断り、1 つ目の動画を開けるまま残す")
    func secondMainIsRefusedBeforeBuilding() async throws {
        let result = await #expect(
            processExitsWith: .success, observing: [\.standardErrorContent], Self.exitCodes
        ) {
            await SecondRunChild.recordThenStopCallingMain()
        }
        guard let result else { return }
        let errors = String(decoding: result.standardErrorContent, as: UTF8.self)
        let refusals = errors.split(separator: "\n").filter {
            $0.contains(SketchApplication.secondRunRefusal)
        }
        #expect(refusals.count == 1, "断りの 1 行が 1 度だけ出ていない。標準エラー:\n\(errors)")
        #expect(
            !errors.contains("The sketch could not start"),
            "2 つ目を組み立てた (組み立ての失敗を言った)。標準エラー:\n\(errors)")
    }

    /// **`run()` が戻ったら、もう走っていない。** 1 つ目を `NSApp.stop` で止めて `run()` から
    /// 戻した後の `run()` は、断らずに走る。
    @Test("止めて戻った後の run() は、既に走っていると言って断らない")
    func runAfterStopIsNotRefused() async {
        await #expect(processExitsWith: .success, Self.exitCodes) {
            await SecondRunChild.runAgainAfterStop()
        }
    }

    /// **1 つ目を窓を持たない経路 (`.accessory`) で走らせる。** 2 つ目は窓を開く経路
    /// (`.regular`) なので、活動の方針を決め直せば変わったことが見える — 両方が窓を開く経路だと、
    /// 決め直しても同じ値で、検査が見逃す。
    @Test("2 つ目の run() は、delegate と活動の方針を 1 つ目のまま残して戻る")
    func secondRunKeepsTheProcessState() async {
        await #expect(processExitsWith: .success, Self.exitCodes) {
            await SecondRunChild.checkProcessStateKept()
        }
    }

    /// exit test の子で走らせる中身。**子のプロセスで呼ぶものだけを置く** — 戻らず、プロセスを終える。
    ///
    /// 終了コードが判定である。0 は期待どおり。ほかは ``Failure`` の値で、何が起きたかを標準エラーへ
    /// 1 行で言う。
    nonisolated enum SecondRunChild {
        /// 何が起きたか。終了コードとして返す。
        enum Failure: Int32 {
            /// 1 つ目の `.mov` に目次 (`moov`) が無く、開けない
            case movieUnreadable = 1
            /// 1 つ目を組めなかった (検査の前提が崩れている)
            case cannotStart = 2
            /// 期限までに終わらなかった
            case deadline = 3
            /// 2 つ目の `run()` の後で、プロセス全体の状態が変わっていた
            case processStateChanged = 4
            /// 2 つ目の `run()` が戻らなかった (入れ子で回った)
            case secondRunDidNotReturn = 5
            /// 1 つ目が止まって `run()` から戻った後の `run()` が、既に走っていると断った
            case refusedAfterStop = 6
        }

        /// 子が自分に掛ける期限 (秒)。描くのは数秒ぶんなので、越えたら固まっている。
        static let deadlineSeconds = 60.0

        /// 1 つ目が撮っている先。子のプロセスごとに決める。
        nonisolated(unsafe) static var movie = URL(fileURLWithPath: "/")
        /// 2 つ目の `run()` が戻ったか。
        nonisolated(unsafe) static var secondRunReturned = false
        /// 2 つ目を `run()` ではなく `Sketch.main()` で起こすか。
        nonisolated(unsafe) static var secondViaMain = false

        /// 言って、その終了コードで終わる。**後始末を走らせない** — 期限を越えた・状態が変わった、の
        /// どちらでも、続けて走らせると判定が別の理由で上書きされうる。
        static func fail(_ failure: Failure, _ message: String) -> Never {
            FileHandle.standardError.write(Data("second-run: \(message)\n".utf8))
            _exit(failure.rawValue)
        }

        /// 子の側の期限。**main の実行ループが固まっても鳴る**よう、別の糸で数える。
        static func armDeadline() {
            DispatchQueue.global().asyncAfter(deadline: .now() + deadlineSeconds) {
                fail(.deadline, "\(Int(deadlineSeconds)) 秒で終わらなかった")
            }
        }

        // MARK: - 条件 1・3: 撮っている動画が開けるまま残る

        /// 1 つ目が `beginRecord` し、10 枚目で 2 つ目の `run()` を 2 回呼び、40 枚目に SIGTERM で
        /// 終わる。プロセスの終わりに `.mov` の目次を探す。**戻らない。**
        static func recordThenStop() async {
            secondViaMain = false
            await recordThenStopCallingSecond()
        }

        /// ``recordThenStop()`` の 2 つ目を、組み立てが投げるスケッチの `main()` で起こす。**戻らない。**
        static func recordThenStopCallingMain() async {
            secondViaMain = true
            await recordThenStopCallingSecond()
        }

        private static func recordThenStopCallingSecond() async {
            armDeadline()
            movie = FileManager.default.temporaryDirectory
                .appendingPathComponent("second-run-\(getpid()).mov")
            atexit {
                let movie = SecondRunChild.movie
                defer { try? FileManager.default.removeItem(at: movie) }
                guard SecondRunChild.hasIndex(movie) else {
                    SecondRunChild.fail(.movieUnreadable, "1 つ目の録画に目次 (moov) が無い: \(movie.path)")
                }
                guard SecondRunChild.secondRunReturned else {
                    SecondRunChild.fail(.secondRunDidNotReturn, "2 つ目の run() が戻らなかった")
                }
            }
            await MainActor.run {
                do {
                    try SketchApplication(sketch: Recording(), gpu: RenderDevice()).run()
                } catch {
                    fail(.cannotStart, "1 つ目を組めなかった: \(error)")
                }
            }
        }

        /// 撮りながら描き、途中で 2 つ目を呼ぶ 1 つ目。
        @MainActor final class Recording: Sketch {
            var settings = SketchSettings(width: 64, height: 48, frameRate: 60, title: "second-run A")

            func setup() { beginRecord(SecondRunChild.movie.path) }

            func draw() {
                background(200, 0, 0)
                circle(Float(frameCount % 64), 24, 8)
                if frameCount == 10 {
                    // 2 回呼ぶ。断りの 1 行は 1 度だけ出る
                    for _ in 0..<2 {
                        if SecondRunChild.secondViaMain {
                            Unbuildable.main()
                        } else {
                            try? SketchApplication(sketch: Second(), gpu: RenderDevice()).run()
                        }
                    }
                    SecondRunChild.secondRunReturned = true
                }
                // 道具が止めるときと同じ合図で終わらせる
                if frameCount == 40 { kill(getpid(), SIGTERM) }
            }
        }

        // MARK: - 条件 2: delegate と活動の方針が 1 つ目のまま

        /// 1 つ目を書き出す経路 (窓を持たない・`.accessory`) で走らせ、5 枚目で 2 つ目の `run()` を
        /// 呼ぶ。前後で `NSApp.delegate` と活動の方針を比べる。書き出しが決めた枚数を描き終えると
        /// 1 つ目が自分で終わる。**戻らない。**
        static func checkProcessStateKept() async {
            armDeadline()
            movie = FileManager.default.temporaryDirectory
                .appendingPathComponent("second-run-state-\(getpid()).mov")
            atexit {
                try? FileManager.default.removeItem(at: SecondRunChild.movie)
                guard SecondRunChild.secondRunReturned else {
                    SecondRunChild.fail(.secondRunDidNotReturn, "2 つ目の run() が戻らなかった")
                }
            }
            await MainActor.run {
                guard
                    let request = RenderRequest(
                        frameRate: 30, frameCount: 20, destination: SecondRunChild.movie.path)
                else { fail(.cannotStart, "書き出しの頼みを組めなかった") }
                do {
                    try SketchApplication(sketch: Watching(), gpu: RenderDevice(), render: request).run()
                } catch {
                    fail(.cannotStart, "1 つ目を組めなかった: \(error)")
                }
            }
        }

        /// 途中で 2 つ目を呼び、前後のプロセス全体の状態を比べる 1 つ目。
        @MainActor final class Watching: Sketch {
            var settings = SketchSettings(width: 64, height: 48, frameRate: 30, title: "second-run A")

            func draw() {
                background(0, 120, 0)
                guard frameCount == 5 else { return }
                let app = NSApplication.shared
                let delegate = app.delegate
                let policy = app.activationPolicy()
                // 2 つ目は窓を開く経路 (`.regular`) で組む — 1 つ目の `.accessory` と違う値を据えうる
                try? SketchApplication(sketch: Second(), gpu: RenderDevice()).run()
                SecondRunChild.secondRunReturned = true
                if app.delegate !== delegate {
                    SecondRunChild.fail(.processStateChanged, "NSApp.delegate が 2 つ目に差し替わった")
                }
                if app.activationPolicy() != policy {
                    SecondRunChild.fail(
                        .processStateChanged,
                        "活動の方針が \(policy.rawValue) から \(app.activationPolicy().rawValue) に変わった")
                }
            }
        }

        /// 2 つ目。何も描かない (描かれないことを期待する)。
        @MainActor final class Second: Sketch {
            var settings = SketchSettings(width: 64, height: 48, frameRate: 60, title: "second-run B")

            func draw() { background(0, 0, 200) }
        }

        /// 組み立てが投げる 2 つ目 (速さ 0 は組み立てが断る・#1694)。
        @MainActor final class Unbuildable: Sketch {
            var settings = SketchSettings(width: 64, height: 48, frameRate: 0, title: "second-run B")
        }

        // MARK: - 止めて戻った後の run()

        /// 1 つ目を 3 枚目で `NSApp.stop` して `run()` から戻し、もう 1 つの `run()` を呼ぶ。断らずに
        /// 実行ループへ入れば、先に積んだ仕事が 0.5 秒後に 0 で終わらせる。断って戻れば 6。**戻らない。**
        static func runAgainAfterStop() async {
            armDeadline()
            movie = FileManager.default.temporaryDirectory
                .appendingPathComponent("second-run-stop-\(getpid()).mov")
            await MainActor.run {
                guard
                    let request = RenderRequest(
                        frameRate: 30, frameCount: 10_000, destination: SecondRunChild.movie.path)
                else { fail(.cannotStart, "書き出しの頼みを組めなかった") }
                do {
                    // 窓を開かない経路で走らせる (止めるまでの数枚のために窓を出さない)
                    try SketchApplication(sketch: Stopping(), gpu: RenderDevice(), render: request).run()
                } catch {
                    fail(.cannotStart, "1 つ目を組めなかった: \(error)")
                }
                // 実行ループへ入れば鳴る。断って戻れば、鳴る前に下で 6 で終わる。**main の
                // 待ち行列には積まない** — ここ自体が main の待ち行列の仕事の中なので、入れ子の
                // 実行ループからは掃けない。実行ループの時計に掛ける
                Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { _ in
                    try? FileManager.default.removeItem(at: SecondRunChild.movie)
                    _exit(0)
                }
                do {
                    // 1 つ目の書き出し先と取り合わないよう、書き出さない経路で組む
                    try SketchApplication(sketch: Second(), gpu: RenderDevice()).run()
                } catch {
                    fail(.cannotStart, "もう 1 つを組めなかった: \(error)")
                }
                try? FileManager.default.removeItem(at: SecondRunChild.movie)
                fail(.refusedAfterStop, "止めて戻った後の run() が、既に走っていると断った")
            }
        }

        /// 3 枚目で実行ループを止める 1 つ目。
        @MainActor final class Stopping: Sketch {
            var settings = SketchSettings(width: 64, height: 48, frameRate: 30, title: "second-run A")
            private var stopped = false

            func draw() {
                background(0, 0, 120)
                guard frameCount >= 3, !stopped else { return }
                stopped = true
                let app = NSApplication.shared
                app.stop(nil)
                // `stop` は次の出来事を処理した後に効く。駆動源の呼び出しは出来事ではないので、1 つ積む
                if let wake = NSEvent.otherEvent(
                    with: .applicationDefined, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0)
                {
                    app.postEvent(wake, atStart: true)
                }
            }
        }

        // MARK: - 目次を探す

        /// 最上位の箱を辿り、`moov` があるか。AVFoundation を使わずに済ませる (起票時の再現と同じ)。
        static func hasIndex(_ url: URL) -> Bool {
            guard let data = try? Data(contentsOf: url) else { return false }
            var offset = 0
            while offset + 8 <= data.count {
                var size = data[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) }
                let kind = String(decoding: data[offset + 4..<offset + 8], as: UTF8.self)
                if kind == "moov" { return true }
                if size == 1, offset + 16 <= data.count {
                    size = data[offset + 8..<offset + 16].reduce(0) { $0 << 8 | Int($1) }
                }
                guard size >= 8 else { return false }
                offset += size
            }
            return false
        }
    }
}
