// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeCore

/// `text` の枠・`clip`・`arc` の範囲を `Rect` で取る形 ([#3784]) と、`strokeDash(length:gap:)` ([#3786])。
/// GPU を要する。
///
/// 約束は 2 つ。**同じ値を渡すと、既定のモードの位置の形と絵が 1 ビットも違わない**こと
/// と、**`Rect` を取る形は ``Canvas/rectMode(_:)`` / ``Canvas/ellipseMode(_:)`` に従わない**こと。
/// `arc` は ``Canvas/ellipseMode(_:)`` の既定が `.center` なので、`.corner` の位置の形と比べる。
/// 中継の口 (`Sketch`) と `Canvas` の直の呼び出しの**両方**で見る。どの組も「何も描いていない絵」と違う
/// ことを先に確かめる。
///
/// [#3784]: https://github.com/mokume-metal/mokume/issues/3784
/// [#3786]: https://github.com/mokume-metal/mokume/issues/3786
@Suite(
    "text の枠・clip・arc の Rect の形と strokeDash(length:gap:)",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct LabeledTextClipArcDashTests {
    final class Stage: Sketch {
        var settings: SketchSettings { SketchSettings(width: 64, height: 48) }
        var scene: (Stage) -> Void = { _ in }
        init() {}
        func draw() { scene(self) }
    }

    /// 1 フレームだけ描いて、面の画素をビット列で返す。
    private func picture(_ gpu: RenderDevice, _ body: @escaping (Stage) -> Void) throws -> [UInt16] {
        let stage = Stage()
        stage.scene = { stage in
            stage.background(10, 12, 16)
            stage.stroke(230, 128, 64)
            stage.strokeWeight(2)
            stage.fill(64, 160, 230)
            body(stage)
        }
        let runtime = try SketchRuntime(sketch: stage, gpu: gpu, clock: nil, now: { 0 })
        try runtime.advance()
        return try runtime.target.readPixels().components.map(\.bitPattern)
    }

    private func differing(_ one: [UInt16], _ other: [UInt16]) -> Int {
        zip(one, other).count { $0.0 != $0.1 } + abs(one.count - other.count)
    }

    /// ラベル付きの形で描いた絵と、位置の形で描いた絵が同じで、何かを描いていること。
    private func agree(
        _ name: String,
        labeled: @escaping (Stage) -> Void,
        positional: @escaping (Stage) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let gpu = try RenderDevice()
        let blank = try picture(gpu) { _ in }
        let expected = try picture(gpu, positional)
        let actual = try picture(gpu, labeled)
        #expect(differing(expected, blank) > 0, "\(name): 位置の形で描いた絵が空", sourceLocation: sourceLocation)
        let count = differing(actual, expected)
        #expect(count == 0, "\(name): ラベル付きの形の絵が位置の形と \(count) 成分違う", sourceLocation: sourceLocation)
    }

    /// 2 つの描き方の絵が違うこと (比べ先が働いていること)。
    private func disagree(
        _ name: String, _ one: @escaping (Stage) -> Void, _ other: @escaping (Stage) -> Void,
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let gpu = try RenderDevice()
        #expect(differing(try picture(gpu, one), try picture(gpu, other)) > 0, "\(name)", sourceLocation: sourceLocation)
    }

    // MARK: - text(_:in:) (#3784)

    private let words = "ab cd ef gh ij kl mn op"
    // 枠の 4 つの数はどれも違う値。高さで行が切れて、残りが出る大きさにしてある
    private let frame = Rect(left: 6, top: 4, width: 41, height: 27)

    @Test("text(_:in:) は既定のモードの text(文字列, 4 つの数) と同じ字の並びで、同じ TextFlow を返す")
    func textInRectMatches() throws {
        let (words, frame) = (words, frame)
        var flows: [String: TextFlow] = [:]
        try agree(
            "Sketch",
            labeled: { stage in
                stage.textSize(9)
                flows["Sketch ラベル付き"] = stage.text(words, in: frame)
            },
            positional: { stage in
                stage.textSize(9)
                flows["Sketch 位置"] = stage.text(words, 6, 4, 41, 27)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                stage.canvas.textSize(9)
                flows["Canvas ラベル付き"] = stage.canvas.text(words, in: frame)
            },
            positional: { stage in
                stage.canvas.textSize(9)
                flows["Canvas 位置"] = stage.canvas.text(words, 6, 4, 41, 27)
            })
        let positional = try #require(flows["Sketch 位置"])
        #expect(positional.lineCount > 0 && !positional.remainder.isEmpty, "枠で行が切れていない — 比べる値が弱い")
        #expect(flows["Sketch ラベル付き"] == positional)
        #expect(flows["Canvas ラベル付き"] == flows["Canvas 位置"])
    }

    @Test("text(_:in:) は rectMode に従わない: .center の後でも、.corner の位置の形と同じ字の並び")
    func textInRectIgnoresRectMode() throws {
        let (words, frame) = (words, frame)
        try agree(
            "Sketch",
            labeled: { stage in
                stage.textSize(9)
                stage.rectMode(.center)
                stage.text(words, in: frame)
            },
            positional: { stage in
                stage.textSize(9)
                stage.text(words, 6, 4, 41, 27)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                stage.canvas.textSize(9)
                stage.canvas.rectMode(.corners)
                stage.canvas.text(words, in: frame)
            },
            positional: { stage in
                stage.canvas.textSize(9)
                stage.canvas.text(words, 6, 4, 41, 27)
            })
        try disagree(
            ".center の位置の形と Rect の形が同じ絵 — モードが効いていない",
            { stage in
                stage.textSize(9)
                stage.rectMode(.center)
                stage.text(words, 6, 4, 41, 27)
            },
            { stage in
                stage.textSize(9)
                stage.rectMode(.center)
                stage.text(words, in: frame)
            })
    }

    // MARK: - clip(_: Rect) (#3784)

    /// 切り抜きの後に、面いっぱいの矩形を描く。
    private static func fillAll(_ stage: Stage) {
        stage.rectMode(.corner)
        stage.rect(0, 0, 64, 48)
    }

    @Test("Issue の例: clip(Rect(0, 0, 50, 50)) は既定のモードの clip(0, 0, 50, 50) と同じ範囲を切る")
    func clipIssueExample() throws {
        let square = Rect(left: 0, top: 0, width: 50, height: 50)
        try agree(
            "Sketch",
            labeled: { stage in
                stage.clip(square)
                Self.fillAll(stage)
            },
            positional: { stage in
                stage.clip(0, 0, 50, 50)
                Self.fillAll(stage)
            })
    }

    @Test("Issue の例: rectMode(.center) の後の clip(Rect(0, 0, 50, 50)) も、.corner の clip(0, 0, 50, 50) と同じ範囲を切る")
    func clipIssueExampleAfterCenterMode() throws {
        let square = Rect(left: 0, top: 0, width: 50, height: 50)
        try agree(
            "Sketch",
            labeled: { stage in
                stage.rectMode(.center)
                stage.clip(square)
                Self.fillAll(stage)
            },
            positional: { stage in
                stage.rectMode(.corner)
                stage.clip(0, 0, 50, 50)
                Self.fillAll(stage)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                stage.canvas.rectMode(.center)
                stage.canvas.clip(square)
                Self.fillAll(stage)
            },
            positional: { stage in
                stage.canvas.rectMode(.corner)
                stage.canvas.clip(0, 0, 50, 50)
                Self.fillAll(stage)
            })
        try disagree(
            ".center の clip(0, 0, 50, 50) と Rect の形が同じ範囲 — モードが効いていない",
            { stage in
                stage.rectMode(.center)
                stage.clip(0, 0, 50, 50)
                Self.fillAll(stage)
            },
            { stage in
                stage.rectMode(.center)
                stage.clip(square)
                Self.fillAll(stage)
            })
    }

    @Test("clip(Rect) は既定のモードの clip(4 つの数) と同じ範囲で、rectMode に従わない")
    func clipRectMatchesAndIgnoresRectMode() throws {
        let box = Rect(left: 7, top: 5, width: 31, height: 22)
        try agree(
            "Sketch",
            labeled: { stage in
                stage.clip(box)
                Self.fillAll(stage)
            },
            positional: { stage in
                stage.clip(7, 5, 31, 22)
                Self.fillAll(stage)
            })
        try agree(
            "Canvas (rectMode(.center) の後)",
            labeled: { stage in
                stage.canvas.rectMode(.center)
                stage.canvas.clip(box)
                Self.fillAll(stage)
            },
            positional: { stage in
                stage.canvas.clip(7, 5, 31, 22)
                Self.fillAll(stage)
            })
        try agree(
            "Sketch (変換の下・rectMode(.radius) の後)",
            labeled: { stage in
                stage.translate(4, 3)
                stage.rectMode(.radius)
                stage.clip(box)
                stage.translate(-4, -3)
                Self.fillAll(stage)
            },
            positional: { stage in
                stage.translate(4, 3)
                stage.clip(7, 5, 31, 22)
                stage.translate(-4, -3)
                Self.fillAll(stage)
            })
        try disagree(
            ".center の位置の形と Rect の形が同じ範囲 — モードが効いていない",
            { stage in
                stage.rectMode(.center)
                stage.clip(7, 5, 31, 22)
                Self.fillAll(stage)
            },
            { stage in
                stage.rectMode(.center)
                stage.clip(box)
                Self.fillAll(stage)
            })
    }

    @Test("数でない値の Rect は、位置の形と同じく切り抜きを触らない")
    func notANumberClipIsIgnoredAlike() throws {
        let broken = Rect(left: Float.nan, top: 5, width: 31, height: 22)
        try agree(
            "Sketch",
            labeled: { stage in
                stage.clip(Rect(left: 7, top: 5, width: 31, height: 22))
                stage.clip(broken)
                Self.fillAll(stage)
            },
            positional: { stage in
                stage.clip(7, 5, 31, 22)
                stage.clip(Float.nan, 5, 31, 22)
                Self.fillAll(stage)
            })
    }

    // MARK: - arc(in:start:stop:)・arc(in:start:stop:mode:) (#3784)

    @Test("Issue の例: 既定の ellipseMode のままの arc(in: Rect(0, 0, 80, 40), …) は ellipseMode(.corner) の arc(0, 0, 80, 40, …) と同じ絵")
    func arcIssueExample() throws {
        // 80x40 は 64x48 の面からはみ出すので、両方に同じ縮小を積む
        try agree(
            "Sketch",
            labeled: { stage in
                stage.scale(0.7)
                stage.arc(in: Rect(left: 0, top: 0, width: 80, height: 40), start: 0, stop: Float.pi)
            },
            positional: { stage in
                stage.scale(0.7)
                stage.ellipseMode(.corner)
                stage.arc(0, 0, 80, 40, 0, Float.pi)
            })
    }

    @Test("arc(in:start:stop:) と arc(in:start:stop:mode:) は ellipseMode(.corner) の位置の形と同じ絵")
    func arcInRectMatches() throws {
        let bounds = Rect(left: 6, top: 4, width: 49, height: 35)
        try agree(
            "Sketch (閉じ方なし)",
            labeled: { $0.arc(in: bounds, start: 0.4, stop: 3.9) },
            positional: { stage in
                stage.ellipseMode(.corner)
                stage.arc(6, 4, 49, 35, 0.4, 3.9)
            })
        try agree(
            "Canvas (閉じ方なし・ellipseMode(.radius) の後)",
            labeled: { stage in
                stage.canvas.ellipseMode(.radius)
                stage.canvas.arc(in: bounds, start: 0.4, stop: 3.9)
            },
            positional: { stage in
                stage.canvas.ellipseMode(.corner)
                stage.canvas.arc(6, 4, 49, 35, 0.4, 3.9)
            })
        for mode in [ArcMode.pie, .chord, .open] {
            try agree(
                "Sketch (\(mode))",
                labeled: { $0.arc(in: bounds, start: 0.4, stop: 3.9, mode: mode) },
                positional: { stage in
                    stage.ellipseMode(.corner)
                    stage.arc(6, 4, 49, 35, 0.4, 3.9, mode)
                })
            try agree(
                "Canvas (\(mode))",
                labeled: { $0.canvas.arc(in: bounds, start: 0.4, stop: 3.9, mode: mode) },
                positional: { stage in
                    stage.canvas.ellipseMode(.corner)
                    stage.canvas.arc(6, 4, 49, 35, 0.4, 3.9, mode)
                })
        }
        // 既定の .center で同じ数を渡した位置の形とは違う絵になる (従わないことの比べ先が働いている)
        try disagree(
            "既定の .center の位置の形と Rect の形が同じ絵",
            { $0.arc(6, 4, 49, 35, 0.4, 3.9) },
            { $0.arc(in: bounds, start: 0.4, stop: 3.9) })
        // 閉じ方を渡さない形と .open は塗りが違う (mode: に既定値を置かない理由)
        try disagree(
            "閉じ方を渡さない形と .open が同じ絵",
            { $0.arc(in: bounds, start: 0.4, stop: 3.9) },
            { $0.arc(in: bounds, start: 0.4, stop: 3.9, mode: .open) })
    }

    @Test("終わりが始まりより前の arc(in:…) は、位置の形と同じく何も描かない")
    func reversedArcDrawsNothingAlike() throws {
        let bounds = Rect(left: 6, top: 4, width: 49, height: 35)
        try agree(
            "Sketch",
            labeled: { stage in
                stage.arc(in: bounds, start: 3.9, stop: 0.4)
                stage.rect(1, 1, 5, 5)
            },
            positional: { stage in
                stage.ellipseMode(.corner)
                stage.arc(6, 4, 49, 35, 3.9, 0.4)
                stage.rect(1, 1, 5, 5)
            })
    }

    // MARK: - strokeDash(length:gap:) (#3786)

    /// 破線にした線を何本か引く。
    private static func lines(_ stage: Stage) {
        stage.noFill()
        stage.line(3, 6, 61, 9)
        stage.line(5, 40, 58, 22)
        stage.rect(10, 14, 30, 18)
    }

    @Test("strokeDash(length:gap:) は strokeDash(長さ, 隙間) と同じ破線")
    func strokeDashMatches() throws {
        // 長さと隙間は違う値にして、取り違えが破線の刻みに出るようにする
        try agree(
            "Sketch",
            labeled: { stage in
                stage.strokeDash(length: 7, gap: 3)
                Self.lines(stage)
            },
            positional: { stage in
                stage.strokeDash(7, 3)
                Self.lines(stage)
            })
        try agree(
            "Canvas",
            labeled: { stage in
                stage.canvas.strokeDash(length: 7, gap: 3)
                Self.lines(stage)
            },
            positional: { stage in
                stage.canvas.strokeDash(7, 3)
                Self.lines(stage)
            })
        try disagree(
            "長さと隙間を入れ替えても同じ絵 — 値の選び方が効いていない",
            { stage in
                stage.strokeDash(7, 3)
                Self.lines(stage)
            },
            { stage in
                stage.strokeDash(3, 7)
                Self.lines(stage)
            })
    }

    @Test("Issue の例: strokeDash(length: 8, gap: 4) は strokeDash(8, 4) と同じ破線")
    func strokeDashIssueExample() throws {
        try agree(
            "Sketch",
            labeled: { stage in
                stage.strokeDash(length: 8, gap: 4)
                Self.lines(stage)
            },
            positional: { stage in
                stage.strokeDash(8, 4)
                Self.lines(stage)
            })
        try disagree(
            "strokeDash(8, 4) が実線と同じ絵 — 破線が効いていない",
            { stage in
                stage.strokeDash(8, 4)
                Self.lines(stage)
            },
            { stage in Self.lines(stage) })
    }

    @Test("負の長さの strokeDash(length:gap:) は、位置の形と同じく実線に戻す")
    func badStrokeDashFallsBackAlike() throws {
        try agree(
            "Sketch",
            labeled: { stage in
                stage.strokeDash(length: 7, gap: 3)
                stage.strokeDash(length: -2, gap: 3)
                Self.lines(stage)
            },
            positional: { stage in
                stage.strokeDash(7, 3)
                stage.strokeDash(-2, 3)
                Self.lines(stage)
            })
    }
}
