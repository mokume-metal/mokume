// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 自分と交わる 1 本の周を、SVG の `fill-rule` で塗る ([#2880])。GPU を要する。
///
/// 一筆書きの五芒星は、中央の五角形の回り数が 2 なので、`evenodd` では抜け、`nonzero` では
/// 塗られる。以前は `evenodd` でも `nonzero` と同じに塗り、中央が埋まっていた。
///
/// [#2880]: https://github.com/mokume-metal/mokume/issues/2880
@Suite(
    "SVG の自己交差した周の塗り",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SVGEvenOddSelfCrossingTests {
    /// #2880 の最小の再現と同じ五芒星。`rule` が `nil` なら属性を書かない (既定は `nonzero`)。
    static func star(rule: String?) -> String {
        let value = rule.map { " fill-rule='\($0)'" } ?? ""
        return """
            <svg xmlns='http://www.w3.org/2000/svg' width='240' height='160'>\
            <path d='M120 15 L160 140 L55 65 L185 65 L80 140 Z' fill='white'\(value)/></svg>
            """
    }

    final class Loaded: Sketch {
        var settings = SketchSettings(width: 240, height: 160)
        var path = ""
        var mark: Shape?
        init() {}
        func setup() { mark = try? loadShape(path) }
        func draw() {
            background(0)
            if let mark { shape(mark) }
        }
    }

    /// SVG を読んで描き、(中央 (120, 85) の赤, 上の腕の中 (120, 30) の赤) を返す。
    private func probe(_ text: String) throws -> (center: Double, arm: Double) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-svg-star-\(UUID().uuidString).svg")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        let sketch = Loaded()
        sketch.path = url.path
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        try runtime.advance()
        _ = try #require(sketch.mark, "SVG を読めていない")
        let pixels = try runtime.target.readPixels()
        func red(_ x: Int, _ y: Int) -> Double { Double(pixels.components[(y * pixels.width + x) * 4]) }
        return (red(120, 85), red(120, 30))
    }

    @Test("evenodd の五芒星は、中央が抜けて 5 つの先端は塗られる (#2880)")
    func evenOddStarLeavesTheCenterOut() throws {
        let result = try probe(Self.star(rule: "evenodd"))
        #expect(result.arm > 0.5, "先端が塗られていない: \(result)")
        #expect(result.center < 0.1, "中央が塗られている: \(result)")
    }

    @Test("nonzero と既定の五芒星は、中央も塗られる (#2880)", arguments: ["nonzero", nil] as [String?])
    func nonzeroStarFillsTheCenter(_ rule: String?) throws {
        let result = try probe(Self.star(rule: rule))
        #expect(result.arm > 0.5, "先端が塗られていない: \(result)")
        #expect(result.center > 0.5, "中央が塗られていない: \(result)")
    }

    @Test("style 属性と CSS の evenodd も、自分と交わる周に届く (#2880)")
    func styleFillRuleReachesTheStar() throws {
        let style = """
            <svg xmlns='http://www.w3.org/2000/svg' width='240' height='160'>\
            <path d='M120 15 L160 140 L55 65 L185 65 L80 140 Z' style='fill:white;fill-rule:evenodd'/></svg>
            """
        let result = try probe(style)
        #expect(result.arm > 0.5)
        #expect(result.center < 0.1, "中央が塗られている: \(result)")
    }
}
