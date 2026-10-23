// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 保存を持たない組み方 (`SketchRuntime(sketch:gpu:clock:persistsParams: false)`) は、合わせたつまみの値を
/// 読みも書きもしない ([#1832](https://github.com/mokume-metal/mokume/issues/1832))。
///
/// 参照スケッチの `--render` と説明文の例の撮影 (`example-shots`) は「撮り直せば同じ絵になる」と名乗る。
/// 撮った人の手元にだけ在る `.mokume/state/params.json` で絵が変わる・先に撮ったスケッチの書いた値を
/// 後のスケッチが戻すことが無いようにする。**保存は本番と同じ場所 (`WorkDirectory.savedParams`) に置く**
/// (既定引数が見る場所そのもの。差し替えると、本番の場所を見る口が検査では開かない)。
/// 保存はプロセスで 1 つなので、**1 本ずつ走らせる**。
@Suite(
    "保存を持たない組み方は、つまみの保存を読みも書きもしない",
    .serialized,
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
@MainActor
struct RenderWithoutPersistenceTests {
    /// `setup()` で見えた値と、`draw()` のたびに値を動かす。**値が絵の色になる** — 絵の差で確かめる。
    private final class Tuned: Sketch {
        @Param(0...1) var gain: Double = 0.5
        var gainAtSetup: Double?
        var settings: SketchSettings { SketchSettings(width: 8, height: 8, frameRate: 60) }
        func setup() { gainAtSetup = gain }
        func draw() {
            background(Float(gain))
            // 動かした値は、保存を持つ組み方なら静かになった後に書かれる
            gain = gain == 0.5 ? 0.75 : 0.5
        }
    }

    private static let saved = #"{"values":[{"name":"gain","type":"float","value":0.9}]}"#
    /// 保存が静かになるまでのフレーム数を越える枚数。
    private static let frames = ParamStore.quietFrames + 10

    /// 本番と同じ場所の保存を (`contents` があれば) 置いて本体を走らせ、終わったら元へ戻す。
    private func withSavedFile<T>(_ contents: String?, _ body: (URL) throws -> T) throws -> T {
        let manager = FileManager.default
        let file = WorkDirectory.savedParams
        let state = file.deletingLastPathComponent()
        let root = state.deletingLastPathComponent()
        let hadRoot = WorkDirectory.directoryExists(at: root)
        let aside = root.appendingPathComponent("state-aside-\(UUID().uuidString)", isDirectory: true)
        let hadState = WorkDirectory.directoryExists(at: state)
        if hadState { try manager.moveItem(at: state, to: aside) }
        defer {
            try? manager.removeItem(at: state)
            if hadState { try? manager.moveItem(at: aside, to: state) }
            if !hadRoot, (try? manager.contentsOfDirectory(atPath: root.path))?.isEmpty == true {
                try? manager.removeItem(at: root)
            }
        }
        if let contents {
            try manager.createDirectory(at: state, withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: file)
        }
        return try body(file)
    }

    /// 組んで `frames` 枚進め、最後の絵の PNG を返す。
    private func render(_ sketch: Tuned, persistsParams: Bool?) throws -> Data {
        let runtime: SketchRuntime
        if let persistsParams {
            runtime = try SketchRuntime(
                sketch: sketch, gpu: RenderDevice(), persistsParams: persistsParams)
        } else {
            // 既定の組み方 (引数を足す前と同じ呼び方)
            runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        }
        for _ in 0..<Self.frames { try runtime.advance() }
        let png = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-persist-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: png) }
        try runtime.target.writePNG(to: png)
        runtime.closePlugins()
        return try Data(contentsOf: png)
    }

    @Test("保存が在っても、保存を持たない組み方の絵は、保存が無いときと同じ")
    func theImageIsTheSameWithAndWithoutASavedFile() throws {
        let without = try withSavedFile(nil) { _ in
            try render(Tuned(), persistsParams: false)
        }
        let sketch = Tuned()
        let with = try withSavedFile(Self.saved) { _ in
            try render(sketch, persistsParams: false)
        }
        #expect(sketch.gainAtSetup == 0.5, "保存の値を戻した: \(String(describing: sketch.gainAtSetup))")
        #expect(with == without, "保存の有無で絵が変わった")
    }

    @Test("保存が在っても、保存を持たない組み方は保存のバイトを書き換えない")
    func theSavedFileIsNotRewritten() throws {
        try withSavedFile(Self.saved) { file in
            _ = try render(Tuned(), persistsParams: false)
            #expect(try String(contentsOf: file, encoding: .utf8) == Self.saved, "保存を書き換えた")
        }
    }

    @Test("保存が無ければ、保存を持たない組み方は保存を作らない")
    func noSavedFileIsCreated() throws {
        try withSavedFile(nil) { file in
            _ = try render(Tuned(), persistsParams: false)
            #expect(!FileManager.default.fileExists(atPath: file.path), "保存を作った")
        }
    }

    /// 既定の組み方と窓 (`SketchApplication`) は、これまでどおり保存を持つ。上の検査が、保存に届く置き方で
    /// 組まれていることの証拠も兼ねる (届かない置き方なら、読まないことを見ても何も言えない)。
    @Test(
        "既定の組み方・persistsParams: true は、これまでどおり保存から戻し、動かした値を書く",
        arguments: [nil, true] as [Bool?])
    func theDefaultStillPersists(_ persistsParams: Bool?) throws {
        try withSavedFile(Self.saved) { file in
            let sketch = Tuned()
            _ = try render(sketch, persistsParams: persistsParams)
            #expect(sketch.gainAtSetup == 0.9, "保存の値を戻さなかった")
            #expect(try String(contentsOf: file, encoding: .utf8) != Self.saved, "動かした値を書かなかった")
        }
    }
}
