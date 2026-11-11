// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import MokumeTestSupport
import Testing

@testable import MokumeCore

// 名前の拡張子と中身が食い違うファイルを黙って書かない ([#3723])。
//
// 書けるのは PNG だけである。スケッチの `save()` と連番の `beginRecord()` は PNG で書いたうえで 1 度だけ
// 知らせ (`draw()` の中で毎フレーム止めない)、`Image.save` は書かずに投げる (呼んだその場で書く口)。
//
// [#3723]: https://github.com/mokume-metal/mokume/issues/3723

/// PNG のシグネチャ (先頭 8 バイト)。
private let pngSignature: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

/// ファイルの先頭 8 バイト。
private func leadingBytes(of path: String) throws -> [UInt8] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    return Array(data.prefix(8))
}

/// `body` を走らせ、その間に言った警告の行を返す。
private func saying<T>(_ body: () throws -> T) rethrows -> (value: T, lines: [String]) {
    try Diagnostics.$digest.withValue(WarningDigest()) {
        let value = try body()
        return (value, Diagnostics.takeUnreported())
    }
}

/// PNG でない名前を知らせた行。
private func notPNGLines(_ lines: [String]) -> [String] {
    lines.filter { $0.contains("written as PNG") }
}

/// 撮る係が知らせる約束 (GPU を要さない)。
@Suite("PNG でない名前の知らせ")
struct SaveFormatNoticeTests {
    @Test("拡張子が .png かは、大文字小文字を区別せずに見る")
    func theExtensionIsReadWithoutCase() {
        #expect(FrameRecorder.isPNG("a.png") && FrameRecorder.isPNG("out/A.PNG") && FrameRecorder.isPNG("x.Png"))
        #expect(!FrameRecorder.isPNG("a.jpg") && !FrameRecorder.isPNG("a") && !FrameRecorder.isPNG("png"))
        #expect(!FrameRecorder.isPNG("a.png.jpg") && !FrameRecorder.isPNG("a.png/b"))
    }

    @Test("save(\"x.jpg\") は積んだうえで 1 度だけ知らせ、同じ名前で 2 回呼んでも 1 度")
    func aShotWithAnotherExtensionIsNamedOnce() {
        let recorder = FrameRecorder()
        let (_, lines) = saying {
            recorder.save("out/x.jpg", at: 1)
            recorder.save("out/x.jpg", at: 2)
        }
        #expect(recorder.hasUnwrittenShots(upTo: 2), "知らせたうえで、書くために積む")
        #expect(notPNGLines(lines).count == 1, "\(lines)")
        let said = recorder.warnings.message(for: .shotNotPNG) ?? ""
        #expect(said.contains("save(\"out/x.jpg\")") && said.contains("PNG"), "\(said)")
        _ = saying { recorder.close() }
    }

    @Test("save(\"x.png\")・save(\"x.PNG\") は知らせない")
    func aPNGShotIsNotNamed() {
        let recorder = FrameRecorder()
        let (_, lines) = saying {
            recorder.save("out/x.png", at: 1)
            recorder.save("out/y.PNG", at: 1)
        }
        #expect(notPNGLines(lines).isEmpty, "\(lines)")
        #expect(!recorder.warnings.hasWarned(.shotNotPNG))
        _ = saying { recorder.close() }
    }

    @Test("beginRecord(\"f-####.jpg\") は撮り始め、1 度だけ知らせる")
    func aSeriesWithAnotherExtensionIsStartedAndNamed() {
        let recorder = FrameRecorder()
        let (_, lines) = saying { recorder.beginRecord("out/f-####.jpg", at: 1) }
        #expect(recorder.isRecording, "PNG で書くので撮り始める")
        #expect(notPNGLines(lines).count == 1, "\(lines)")
        let said = recorder.warnings.message(for: .seriesNotPNG) ?? ""
        #expect(said.contains("beginRecord(\"out/f-####.jpg\")") && said.contains("PNG"), "\(said)")
        _ = saying { recorder.close() }
    }

    @Test("beginRecord(\"f-####.PNG\") と .mov は知らせない")
    func aPNGSeriesIsNotNamed() {
        for pattern in ["out/f-####.PNG", "out/f-####.png", "out/motion.mov"] {
            let recorder = FrameRecorder()
            let (_, lines) = saying { recorder.beginRecord(pattern, at: 1) }
            #expect(recorder.isRecording, "\(pattern)")
            #expect(notPNGLines(lines).isEmpty, "\(pattern): \(lines)")
            _ = saying { recorder.close() }
        }
    }
}

/// 書いたファイルの中身と、`Image.save` の断り (GPU を要する)。
@Suite(
    "PNG でない名前で書く",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SaveFormatWriteTests {
    final class Saving: Sketch {
        var onDraw: ((Saving) -> Void)?
        init() {}
        var settings: SketchSettings { SketchSettings(width: 16, height: 12) }
        func draw() {
            background(200, 80, 40)
            onDraw?(self)
        }
    }

    private func withTemporaryDirectory(_ name: String, _ body: (URL) throws -> Void) throws {
        let directory = try TestScratch.directory(name)
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }

    @Test("スケッチの save(\"x.jpg\") は PNG の中身を書き、2 回呼んでも 1 度だけ知らせる")
    func aSketchShotWithAnotherExtensionHoldsAPNG() throws {
        try withTemporaryDirectory("mokume-save-jpg") { directory in
            let path = directory.appendingPathComponent("x.jpg").path
            let sketch = Saving()
            sketch.onDraw = { if $0.frameCount <= 2 { $0.save(path) } }
            let (_, lines) = try saying {
                let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
                for _ in 0..<3 { try runtime.advance() }
                runtime.closePlugins()
            }
            #expect(try leadingBytes(of: path) == pngSignature)
            let named = notPNGLines(lines)
            #expect(named.count == 1, "\(lines)")
            #expect(named.first?.contains("save(\"\(path)\")") == true, "\(named)")
        }
    }

    @Test("スケッチの save(\"x.PNG\") は知らせない")
    func aSketchShotWithAnUppercasePNGIsNotNamed() throws {
        try withTemporaryDirectory("mokume-save-upper-png") { directory in
            let path = directory.appendingPathComponent("x.PNG").path
            let sketch = Saving()
            sketch.onDraw = { if $0.frameCount == 1 { $0.save(path) } }
            let (_, lines) = try saying {
                let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
                for _ in 0..<2 { try runtime.advance() }
                runtime.closePlugins()
            }
            #expect(try leadingBytes(of: path) == pngSignature)
            #expect(notPNGLines(lines).isEmpty, "\(lines)")
        }
    }

    @Test("beginRecord(\"f-##.jpg\") の連番は PNG の中身を書き、1 度だけ知らせる")
    func aSeriesWithAnotherExtensionHoldsPNGs() throws {
        try withTemporaryDirectory("mokume-series-jpg") { directory in
            let pattern = directory.appendingPathComponent("f-##.jpg").path
            let sketch = Saving()
            sketch.onDraw = { sketch in
                if sketch.frameCount == 1 { sketch.beginRecord(pattern) }
                if sketch.frameCount == 3 { sketch.endRecord() }
            }
            let (_, lines) = try saying {
                let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
                for _ in 0..<4 { try runtime.advance() }
                runtime.closePlugins()
            }
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
            #expect(names == ["f-00.jpg", "f-01.jpg"])
            for name in names {
                #expect(try leadingBytes(of: directory.appendingPathComponent(name).path) == pngSignature, "\(name)")
            }
            let named = notPNGLines(lines)
            #expect(named.count == 1, "\(lines)")
            #expect(named.first?.contains("beginRecord(\"\(pattern)\")") == true, "\(named)")
        }
    }

    @Test("Image.save(\"x.jpg\") は書かずに投げ、理由に PNG だけを書くことが載る")
    func anImageWithAnotherExtensionIsRefused() throws {
        try withTemporaryDirectory("mokume-image-save-jpg") { directory in
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            let image = try canvas.createImage(4, 4)
            image.fill(.linear(red: 1, green: 0.4, blue: 0.1))
            for name in ["x.jpg", "x.JPEG", "x.tif", "x", "x.png.jpg"] {
                let path = directory.appendingPathComponent(name).path
                do {
                    try image.save(path)
                    Issue.record("\(name) へ書けてしまった")
                } catch let failure as ImageFailure {
                    guard case .unwritable(let thrownPath, let reason) = failure else {
                        Issue.record("別の失敗: \(failure)")
                        continue
                    }
                    #expect(thrownPath == path)
                    #expect(reason.contains("PNG only"), "\(reason)")
                } catch {
                    Issue.record("ImageFailure ではない失敗: \(error)")
                }
                #expect(!FileManager.default.fileExists(atPath: path), "\(name) が作られた")
            }
        }
    }

    @Test("Image.save(\"x.png\")・(\"x.PNG\") は今のとおり書く")
    func anImageWithAPNGNameIsWritten() throws {
        try withTemporaryDirectory("mokume-image-save-png") { directory in
            let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 8, height: 8)
            let image = try canvas.createImage(4, 4)
            image.fill(.linear(red: 1, green: 0.4, blue: 0.1))
            for name in ["x.png", "y.PNG"] {
                let path = directory.appendingPathComponent(name).path
                try image.save(path)
                #expect(try leadingBytes(of: path) == pngSignature, "\(name)")
            }
        }
    }
}
