// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// 部品の型 (`SketchPart`) の中から描いた絵は、スケッチの中に直に書いた絵と同じ (#2616)。
///
/// 語彙は呼んだ時点で走っているスケッチへ描く。置き場を `Sketch` から `SketchPart` へ
/// 移しても描く先が変わらないことを、同じ手順を 2 通りに書いて画素で突き合わせる。
@Suite(
    "部品の型から描く",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SketchPartDrawingTests {
    struct Badge: SketchPart {
        var x: Float
        var y: Float

        func display() {
            fill(255)
            circle(x, y, 20)
            fill(240, 120, 60)
            rect(x - 4, y + 14, 8, 6)
            text("HP", x - 20, y + 4)
        }
    }

    /// 部品に描かせる。
    final class WithPart: Sketch {
        var settings = SketchSettings(width: 48, height: 40)
        let badge = Badge(x: 24, y: 16)
        init() {}
        func draw() {
            background(20)
            badge.display()
        }
    }

    /// 同じ手順を直に書く。
    final class Inline: Sketch {
        var settings = SketchSettings(width: 48, height: 40)
        init() {}
        func draw() {
            background(20)
            fill(255)
            circle(24, 16, 20)
            fill(240, 120, 60)
            rect(24 - 4, 16 + 14, 8, 6)
            text("HP", 24 - 20, 16 + 4)
        }
    }

    private func firstFrame(of sketch: some Sketch) throws -> DisplayImage {
        let runtime = try SketchRuntime(sketch: sketch, gpu: try RenderDevice())
        try runtime.advance()
        return try runtime.canvas.target.encodeForDisplay()
    }

    @Test("部品から描いた絵は、直に書いた絵と画素まで同じ")
    func partDrawsTheSameAsInline() throws {
        let part = try firstFrame(of: WithPart())
        let inline = try firstFrame(of: Inline())
        #expect(part == inline)
        // 何も描かれていない 2 枚どうしでも一致するので、円の中心が塗られたことも見る
        #expect(part[24, 16] == (255, 255, 255, 255))
    }
}
