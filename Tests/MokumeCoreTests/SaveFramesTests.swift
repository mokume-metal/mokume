// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import MokumeCore

/// 連番の名前の組み立て。GPU を要さない。
@Suite("連番の名前")
struct FrameSequenceTests {
    @Test("# の並びが番号の桁になる")
    func hashRunBecomesTheDigits() {
        var sequence = FrameSequence(pattern: "out/frame-####.png")
        #expect(sequence?.prefix == "out/frame-")
        #expect(sequence?.digits == 4)
        #expect(sequence?.suffix == ".png")
        #expect(sequence?.next() == "out/frame-0000.png")
        #expect(sequence?.next() == "out/frame-0001.png")
    }

    @Test("桁が揃うので、名前順が撮った順になる")
    func namesSortInCaptureOrder() {
        var sequence = FrameSequence(pattern: "f-###.png")!
        let names = (0..<12).map { _ in sequence.next() }
        #expect(names == names.sorted())
        #expect(names.first == "f-000.png")
        #expect(names.last == "f-011.png")
    }

    @Test("桁に収まらなくなったら、切り詰めずに伸びる")
    func numbersGrowRatherThanTruncate() {
        var sequence = FrameSequence(pattern: "f-#.png")!
        for _ in 0..<10 { _ = sequence.next() }
        // 9 の次は 10。切り詰めると 0 に戻り、撮った絵を黙って失う
        #expect(sequence.next() == "f-10.png")
    }

    @Test("番号の入る場所が無い名前は組み立てない")
    func aPatternWithoutAPlaceForTheNumberIsRefused() {
        #expect(FrameSequence(pattern: "out/frame.png") == nil)
    }
}

/// 書き出す係。GPU を要さない。
@Suite("書き出しの背圧")
struct FrameWriterTests {
    @Test("抱える枚数が上限を超えず、上限までは抱える")
    func theQueueFillsUpToTheLimitAndNoFurther() throws {
        try withTemporaryDirectory("mokume-frame-writer") { directory in
            let writer = FrameWriter(limit: 2)
            // 1 枚あたり 256 KB。書き込みが即座には終わらない大きさにして、
            // 頼む側が上限に当たる状況を作る
            let image = DisplayImage(
                width: 256, height: 256, bytes: [UInt8](repeating: 128, count: 256 * 256 * 4))

            for index in 0..<24 {
                writer.write(image, to: directory.appendingPathComponent("f-\(index).png").path)
                // 上限を超えて抱えたら、長い連番でメモリが伸び続けることになる
                #expect(writer.outstanding <= writer.limit)
            }
            #expect(writer.peakOutstanding == writer.limit)

            writer.drain()
            for index in 0..<24 {
                let url = directory.appendingPathComponent("f-\(index).png")
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    @Test("drain から返った時点で、頼んだ全部がファイルになっている")
    func drainReturnsOnlyAfterEveryFileExists() throws {
        try withTemporaryDirectory("mokume-frame-writer-drain") { directory in
            let writer = FrameWriter()
            let image = DisplayImage(
                width: 8, height: 8, bytes: [UInt8](repeating: 200, count: 8 * 8 * 4))
            for index in 0..<10 {
                writer.write(image, to: directory.appendingPathComponent("f-\(index).png").path)
            }
            writer.drain()

            // 「書き始めた」だけで返る形だと、ここが偽になる
            let written = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            #expect(written.count == 10)
            #expect(writer.outstanding == 0)
        }
    }

    @Test("途中のディレクトリは頼まれた側が作る")
    func missingDirectoriesAreCreated() throws {
        try withTemporaryDirectory("mokume-frame-writer-mkdir") { directory in
            let writer = FrameWriter()
            let url = directory.appendingPathComponent("a/b/c/f.png")
            writer.write(
                DisplayImage(
                    width: 2, height: 2, bytes: [UInt8](repeating: 255, count: 2 * 2 * 4)),
                to: url.path)
            writer.drain()
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}

/// スケッチから絵をファイルにする経路。GPU を要する。
@Suite(
    "絵をファイルにする",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SaveFramesTests {

    // MARK: - 検査用のスケッチ

    final class SavingSketch: Sketch {
        /// 走らせる前に差し込む。`Sketch` は引数なしで作れる必要があるため。
        nonisolated(unsafe) static var body: (SavingSketch) -> Void = { _ in }

        var settings: SketchSettings { SketchSettings(width: 32, height: 24) }
        func draw() { Self.body(self) }
    }

    private func makeRuntime(
        _ body: @escaping (SavingSketch) -> Void
    ) throws -> SketchRuntime {
        SavingSketch.body = body
        return try SketchRuntime(sketch: SavingSketch(), gpu: try RenderDevice())
    }

    // MARK: - 出る絵

    @Test("書いたファイルの画素が、出口が受け取る絵と一致する")
    func theFileHoldsExactlyWhatTheOutletReceives() throws {
        try withTemporaryDirectory("mokume-save-matches") { directory in
            let url = directory.appendingPathComponent("still.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0.1, green: 0.1, blue: 0.12))
                sketch.fill(.display(red: 1, green: 0.4, blue: 0.2))
                sketch.circle(16, 12, 16)
                if sketch.frameCount == 1 { sketch.save(url.path) }
            }

            try runtime.advance()
            runtime.closePlugins()

            // 画面へ差し出す絵も出口が受け取る絵も、出どころは同じ 1 本の道である
            let fromTheRoad = try runtime.target.encodeToImage().read()
            let written = try readBack(url)
            #expect(written.width == fromTheRoad.width)
            #expect(written.height == fromTheRoad.height)
            #expect(written.bytes == fromTheRoad.bytes)
        }
    }

    @Test("背景を透けさせると、ファイルにも透けたまま残る")
    func transparencySurvivesTheTripToTheFile() throws {
        try withTemporaryDirectory("mokume-save-alpha") { directory in
            let url = directory.appendingPathComponent("clear.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.transparent)
                sketch.noStroke()
                sketch.fill(.display(red: 1, green: 1, blue: 1))
                sketch.circle(16, 12, 12)
                if sketch.frameCount == 1 { sketch.save(url.path) }
            }

            try runtime.advance()
            runtime.closePlugins()

            let written = try readBack(url)
            // 画面用の面を読み戻す経路なら、ここで背景が黒く潰れている
            #expect(written[0, 0].alpha == 0)
            #expect(written[31, 23].alpha == 0)
            #expect(written[16, 12].alpha == 255)
        }
    }

    // MARK: - 終わりを待てる

    @Test("endRecord から返った時点で、要求した全部がファイルになっている")
    func endRecordReturnsOnlyAfterEveryFrameIsOnDisk() throws {
        try withTemporaryDirectory("mokume-record-drain") { directory in
            let pattern = directory.appendingPathComponent("f-####.png").path
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0, green: 0, blue: 0))
                sketch.circle(Float(sketch.frameCount), 12, 8)
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
                if sketch.frameCount == 6 { sketch.endRecord() }
            }

            for _ in 0..<6 { try runtime.advance() }

            // **後片付けをしていない。** ここで揃っていなければ、止めた直後に
            // プロセスを終えた人は最後の 1 枚を失う
            for index in 0..<5 {
                let url = directory.appendingPathComponent(String(format: "f-%04d.png", index))
                #expect(FileManager.default.fileExists(atPath: url.path))
            }
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).count == 5)
        }
    }

    @Test("番号の入る場所が無い名前は、撮り始めずに済ませる")
    func aPatternWithoutANumberNeverStarts() throws {
        try withTemporaryDirectory("mokume-record-refuse") { directory in
            let pattern = directory.appendingPathComponent("frame.png").path
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0, green: 0, blue: 0))
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
            }

            for _ in 0..<5 { try runtime.advance() }
            runtime.closePlugins()

            // 黙って受けると、全部が同じ名前になって 1 枚だけが残る
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
            #expect(runtime.target.encodePassCount == 0)
        }
    }

    // MARK: - 使わないスケッチは払わない

    @Test("撮らないスケッチは、道を 1 回も通らない")
    func aSketchThatNeverSavesPaysNothing() throws {
        let runtime = try makeRuntime { sketch in
            sketch.background(.display(red: 0.2, green: 0.2, blue: 0.2))
            sketch.circle(16, 12, 10)
        }
        for _ in 0..<10 { try runtime.advance() }
        #expect(runtime.target.encodePassCount == 0)
    }

    @Test("1 枚だけ撮ると、道を通るのはそのフレームだけ")
    func oneStillCostsExactlyOnePass() throws {
        try withTemporaryDirectory("mokume-save-once") { directory in
            let url = directory.appendingPathComponent("one.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0.2, green: 0.2, blue: 0.2))
                if sketch.frameCount == 1 { sketch.save(url.path) }
            }

            for _ in 0..<10 { try runtime.advance() }
            runtime.closePlugins()

            // 付けっぱなしにすると、ここが 10 になる
            #expect(runtime.target.encodePassCount == 1)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test("同じフレームに 2 枚頼んでも、読み戻しは 1 回")
    func twoRequestsInOneFrameShareOneReadback() throws {
        try withTemporaryDirectory("mokume-save-twice") { directory in
            let first = directory.appendingPathComponent("a.png")
            let second = directory.appendingPathComponent("b.png")
            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0.3, green: 0.1, blue: 0.5))
                if sketch.frameCount == 1 {
                    sketch.save(first.path)
                    sketch.save(second.path)
                }
            }

            try runtime.advance()
            runtime.closePlugins()

            #expect(runtime.target.encodePassCount == 1)
            #expect(runtime.target.encodedStorage?.readCount == 1)
            #expect(try Data(contentsOf: first) == (try Data(contentsOf: second)))
        }
    }

    // MARK: - 転んだとき

    @Test("書き損じが続くと、その差込口が外れる")
    func aRecorderThatKeepsFailingIsDetached() throws {
        try withTemporaryDirectory("mokume-record-failing") { directory in
            // 書き先の親をファイルにしておく。ディレクトリを作ることも書くこともできない
            let blocker = directory.appendingPathComponent("blocker")
            try Data("not a directory".utf8).write(to: blocker)
            let pattern = blocker.appendingPathComponent("f-####.png").path

            let runtime = try makeRuntime { sketch in
                sketch.background(.display(red: 0, green: 0, blue: 0))
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
            }

            for _ in 0..<30 { try runtime.advance() }
            let passesWhileFailing = runtime.target.encodePassCount
            for _ in 0..<10 { try runtime.advance() }
            runtime.closePlugins()

            // 転び続ける出口が毎フレーム費用を払い続けないこと (ADR-0024 決定 7)
            #expect(runtime.target.encodePassCount == passesWhileFailing)
            #expect(passesWhileFailing < 30)
        }
    }
}

// MARK: - 共通の道具

/// 検査のあいだだけ使う一時ディレクトリ。
@MainActor
private func withTemporaryDirectory(_ name: String, _ body: (URL) throws -> Void) throws {
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("\(name)-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.removeItem(at: directory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    try body(directory)
}

/// 書いた PNG を、変換を挟まずにバイト列として読み戻す。
///
/// **描き直さない。** 面へ描いて読み直すとアルファが乗算され、透けたところの色が
/// 失われる — 透過が残っていることを見る検査が、道具の側の都合で通らなくなる。
@MainActor
private func readBack(_ url: URL) throws -> DisplayImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
        let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
        let data = image.dataProvider?.data as Data?
    else {
        throw ImageWriteFailure.destinationUnavailable(path: url.path)
    }
    return DisplayImage(width: image.width, height: image.height, bytes: [UInt8](data))
}
