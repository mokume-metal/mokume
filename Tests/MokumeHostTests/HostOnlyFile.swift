// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 道具・外のパッケージが書くファイルそのもの (#3870)。**import は Foundation と MokumeHost だけにする** —
// ここに `import mokume` や `import MokumeCore` を足すと、確かめたいこと (`import MokumeHost` だけで
// 窓なしの実行を使い切れる) を確かめなくなる。スケッチ (`HostProbeSketch`) は別のファイルで `import mokume`
// して書く。
//
// `MokumeHost` の名指しの一覧 (`Sources/MokumeHost/Exports.swift`) が `HeadlessRun` の署名に要る型を
// 出し漏らすと、このファイルが組めなくなる。

import Foundation
import MokumeHost

/// 1 回の実行で読んだもの。
struct HostReading {
    let frameCount: Int
    let time: Float
    let deltaTime: Float
    let before: PixelBuffer
    let after: DisplayImage
    let pngBytes: Int
}

/// 窓なしで 2 枚進め、スペースを押してもう 1 枚進め、押す前と後の絵を読む。
func readAroundSpace(_ sketch: some Sketch, gpu: RenderDevice? = nil) throws -> HostReading {
    try HeadlessRun.with(sketch, gpu: gpu) { run in
        try run.advance(frames: 2)
        let before = try run.readPixels()
        run.send(.keyDown(code: .space, characters: " ", isRepeat: false))
        run.send(.keyUp(code: .space))
        try run.advance()
        let after = try run.displayImage()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-host-\(ProcessInfo.processInfo.processIdentifier).png")
        defer { try? FileManager.default.removeItem(at: url) }
        try run.writePNG(to: url)
        let pngBytes = try Data(contentsOf: url).count
        return HostReading(
            frameCount: run.frameCount, time: run.time, deltaTime: run.deltaTime,
            before: before, after: after, pngBytes: pngBytes)
    }
}

/// `with` を通さずに組み、持ち続ける形 (スケッチのプロパティに実行を持つビューア)。
final class HostViewer {
    var run: HeadlessRun?

    init(_ sketch: some Sketch) throws {
        run = try HeadlessRun(sketch)
    }
}

/// `body` の中で投げる。`with` が投げて抜けても閉じることを確かめるため。
struct DeliberateFailure: Error {}

func throwInside(_ sketch: some Sketch) throws {
    try HeadlessRun.with(sketch) { run in
        try run.advance()
        throw DeliberateFailure()
    }
}

/// `with` の中の実行を外へ持ち出す。持ち出した参照が残っていても、`with` を抜けたときに閉じることを
/// 確かめるため (閉じるのが参照の寿命任せなら、ここでは閉じない)。
func escapeFromWith(_ sketch: some Sketch) throws -> HeadlessRun {
    var escaped: HeadlessRun?
    try HeadlessRun.with(sketch) { run in
        try run.advance()
        escaped = run
    }
    return escaped!
}
