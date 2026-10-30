// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeProbe
import MokumeTestSupport
import Testing
import simd

@testable import MokumeCore

/// **SVG の描画は、CoreSVG が CPU で描いた絵と、50% の白黒と重心で一致する** ([#3494]・#3207 の提案 2)。GPU を要する。
///
/// `FillCoverageTests` は図形 (rect・円) を解析的な参照と画素ごとに比べる。SVG は塗り規則 (`evenodd`)・群の
/// `opacity`・入れ子の変換が絡み、解析的に書くと mokume の読み解きの写しになる。そこで、**外の描画器**
/// (CoreSVG・`NSImage(contentsOf:)`・``CoreSVGReference``) が CPU で描いた絵を参照にする。CoreGraphics の AA は
/// 円で画素ごとに最大 0.064 外れ (#3217 の実測)、mokume の許容より粗いので、**中間値は比べず**、
///
/// - **50% の被覆で白黒にした形** (一致しない画素の数を、縁の画素の数で割った割合)
/// - **線形の被覆で重みを付けた重心** (ずれの画素数)
///
/// だけを比べる (``CoverageTable`` の「50% の白黒と重心」の行)。許容と根拠は表が持つ。
///
/// ## 見る SVG
///
/// 見本 (``templates``) を、位置・拡大・回転を**生成した変換**の下に置いて描く。変換は SVG 自身の
/// `transform` 属性に書くので、mokume と CoreSVG が同じ文を読む。見本は塗り規則 (evenodd・nonzero・穴)・曲線・
/// 矩形と円・群の `opacity` (子が離れているときと重なるとき)。
///
/// ## 比べない入力
///
/// **CSS の優先順位を含む入力は生成しない** (`<style>`・`class`・`!important`・`style` 属性)。CoreSVG が優先順位を
/// 誤り (#2348・#2334・#2410 の型)、比べると mokume の誤りと見分けられない。表が対象外として名乗る
/// (``CoverageTable/svgOutOfScope``)。
///
/// ## 既知の食い違い
///
/// 群の `opacity` が、重なった子へ**子ごとに掛かる**近似は ([#2878]、open)、SVG と違う絵になる (重心が 0.6 画素
/// ずれる)。重なる見本は `withKnownIssue` で包み、#2878 が直ったら「記録されるはずの赤が無い」で赤になって、
/// 包みごと外させる。
///
/// ## 赤の読み方
///
/// `[coverage seed=0x…] template=… tx=… ty=… scale=… degrees=…: <見本> 一致しない画素 … (縁 …・許容 …) 重心のずれ …`。
/// 同じ赤は `MOKUME_PROBE_SEED=<その seed>` と `--filter` で、その 1 件だけを走らせて再現する。
///
/// [#3494]: https://github.com/mokume-metal/mokume/issues/3494
/// [#2878]: https://github.com/mokume-metal/mokume/issues/2878
@Suite(
    "SVG の描画は CoreSVG の参照と 50% の白黒と重心で一致する",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SVGCoverageTests {
    static let size = 128

    /// 生成する置き方の件数。PR・queue の経路に足す所要を 20 秒以内に収める (#3207 の K4)。
    static let cases = 100

    /// 面へ SVG を置くだけの作品。`path` が変わったら読み直す。
    final class Loaded: Sketch {
        var settings = SketchSettings(width: 128, height: 128)
        var path = ""
        private var loaded = ""
        private var mark: Shape?
        init() {}
        func draw() {
            background(0)
            if path != loaded {
                loaded = path
                mark = try? loadShape(path)
            }
            if let mark { shape(mark) }
        }
    }

    /// 見本 1 つ。原点を中心に ±40 の内へ収める。
    struct Template: Sendable {
        let name: String
        let svg: String
        /// 参照の側の重みの付け方。三角形の経路は AA なしで、参照の AA の重みを写せない (表の根拠)。
        let weightsReferenceByHalfTone: Bool
    }

    /// 一筆書きの五芒星 (中央の五角形は回り数 2)。`rule` は `evenodd` か `nonzero`。
    static func star(_ rule: String) -> String {
        let points = (0..<5).map { k -> String in
            let angle = (-90.0 + 144.0 * Double(k)) * .pi / 180
            return "\(34 * cos(angle)) \(34 * sin(angle))"
        }
        return "<path d='M\(points[0]) L\(points[1]) L\(points[2]) L\(points[3]) L\(points[4]) Z' "
            + "fill='white' fill-rule='\(rule)'/>"
    }

    /// 三角形の経路 (パス)。
    static let pathTemplates: [Template] = [
        Template(name: "star-evenodd", svg: star("evenodd"), weightsReferenceByHalfTone: true),
        Template(name: "star-nonzero", svg: star("nonzero"), weightsReferenceByHalfTone: true),
        Template(
            name: "square-hole-evenodd",
            svg: "<path d='M-25 -25 H25 V25 H-25 Z M-10 -10 H10 V10 H-10 Z' fill='white' fill-rule='evenodd'/>",
            weightsReferenceByHalfTone: true),
        Template(
            name: "square-hole-nonzero",
            svg: "<path d='M-25 -25 H25 V25 H-25 Z M-10 -10 V10 H10 V-10 Z' fill='white' fill-rule='nonzero'/>",
            weightsReferenceByHalfTone: true),
        Template(
            name: "blob",
            svg: "<path d='M-30 0 C-30 -40 30 -40 30 0 C30 40 -30 40 -30 0 Z' fill='white'/>",
            weightsReferenceByHalfTone: true),
    ]

    /// 距離関数の経路 (矩形・円) と、群の `opacity` が子ごとに掛かっても同じ絵になる見本 (子が離れている)。
    static let primitiveTemplates: [Template] = [
        Template(
            name: "rect-and-circle",
            svg: "<rect x='-30' y='-20' width='40' height='30' fill='white'/>"
                + "<circle cx='15' cy='10' r='18' fill='white'/>",
            weightsReferenceByHalfTone: false),
        Template(
            name: "group-opacity-apart",
            svg: "<g opacity='0.6'><circle cx='-24' cy='0' r='14' fill='white'/>"
                + "<circle cx='24' cy='4' r='10' fill='white'/></g>",
            weightsReferenceByHalfTone: false),
    ]

    /// 群の `opacity` が重なる子の間で変わる見本 (#2878)。大きさの違う円が深く重なり、重なった所が偏るので、
    /// 子ごとに掛けると重なりの重みが 0.6 から 0.84 に増えて重心が動く。
    static let overlappingGroup = Template(
        name: "group-opacity-overlap",
        svg: "<g opacity='0.6'><circle cx='-8' cy='0' r='26' fill='white'/>"
            + "<circle cx='14' cy='8' r='20' fill='white'/></g>",
        weightsReferenceByHalfTone: false)

    static func axes(_ count: Int) -> [ProbeAxis] {
        [
            ProbeAxis("template", 0..<Double(count), simplest: 0, step: 1),
            // 見本は ±40 の内で、拡大は最大 1.4 倍・回転しても ±57 の内に収まる
            ProbeAxis("tx", 62..<70, simplest: 64),
            ProbeAxis("ty", 62..<70, simplest: 64),
            ProbeAxis("scale", 0.8..<1.2, simplest: 1),
            ProbeAxis("degrees", 0..<360, simplest: 0),
        ]
    }

    static func document(_ template: Template, tx: Double, ty: Double, scale: Double, degrees: Double) -> String {
        "<svg xmlns='http://www.w3.org/2000/svg' width='\(size)' height='\(size)'>"
            + "<g transform='translate(\(tx) \(ty)) rotate(\(degrees)) scale(\(scale))'>\(template.svg)</g></svg>"
    }

    private static func short(_ value: Double) -> String { String(format: "%.3g", value) }

    /// 1 件を描いて、参照と比べる。
    static func outcome(
        _ template: Template, _ input: ProbeInput, row: CoverageTable.Row, sketch: Loaded, runtime: SketchRuntime
    ) throws -> Probe.Outcome {
        let text = document(
            template, tx: input["tx"], ty: input["ty"], scale: input["scale"], degrees: input["degrees"])
        for marker in CoverageTable.svgOutOfScopeMarkers where text.contains(marker) {
            return .fail("約束の外 (\(marker)) を生成している: \(template.name)")
        }
        let url = TestScratch.path("mokume-svg-coverage", pathExtension: "svg")
        try text.write(to: url, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: url) }
        sketch.path = url.path
        try runtime.advance()
        let pixels = try runtime.target.readPixels()
        let measured = (0..<(size * size)).map { Double(pixels[$0 % size, $0 / size].red) }
        let reference = try CoreSVGReference.render(svg: text, width: size, height: size).coverage

        let measuredShape = CoreSVGReference.halfTone(measured)
        let referenceShape = CoreSVGReference.halfTone(reference)
        let mismatches = CoreSVGReference.mismatches(measuredShape, referenceShape)
        let edge = max(1, CoreSVGReference.edgePixels(referenceShape, width: size))
        let rate = Double(mismatches) / Double(edge)

        let measuredCentroid = CoreSVGReference.centroid(measured, width: size)
        let referenceWeights = template.weightsReferenceByHalfTone ? referenceShape.map { $0 ? 1.0 : 0.0 } : reference
        let referenceCentroid = CoreSVGReference.centroid(referenceWeights, width: size)
        let shift: Double
        switch (measuredCentroid, referenceCentroid) {
        case (let a?, let b?): shift = simd_distance(a, b)
        case (nil, nil): shift = 0
        default: shift = .infinity
        }
        let tolerance = row.centroidTolerance ?? 0
        if rate <= row.tolerance, shift <= tolerance { return .pass }
        return .fail(
            "\(template.name) 一致しない画素 \(mismatches) (縁 \(edge)・割合 \(short(rate))・許容 \(short(row.tolerance)))"
                + " 重心のずれ \(short(shift)) 画素 (許容 \(short(tolerance)))")
    }

    /// 見本を生成した置き方で描き、全部が参照と一致するかを見る。
    private static func run(
        _ key: String, templates: [Template], row: CoverageTable.Row
    ) throws -> Probe.Report {
        let sketch = Loaded()
        let runtime = try SketchRuntime(sketch: sketch, gpu: RenderDevice())
        return try Probe.run(
            "coverage", suite: "SVGCoverageTests", key: key, axes: axes(templates.count), cases: cases
        ) { input in
            try outcome(templates[Int(input["template"])], input, row: row, sketch: sketch, runtime: runtime)
        }
    }

    @Test("SVG のパス (evenodd・nonzero・穴・曲線) は、置き方によらず、参照と 50% の白黒と重心で一致する")
    func pathsMatchTheReference() throws {
        let row = try CoverageTable.row(.svgPath, on: .triangles, comparing: .halfToneAndCentroid)
        let report = try Self.run("svg-path", templates: Self.pathTemplates, row: row)
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.skipped == 0, "約束の外は無いはず: \(report.skipped) 件")
    }

    @Test("SVG の矩形・円と、離れた子の群の opacity は、置き方によらず、参照と 50% の白黒と重心で一致する")
    func primitivesMatchTheReference() throws {
        let row = try CoverageTable.row(.svgPrimitives, on: .distanceField, comparing: .halfToneAndCentroid)
        let report = try Self.run("svg-primitives", templates: Self.primitiveTemplates, row: row)
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.skipped == 0, "約束の外は無いはず: \(report.skipped) 件")
    }

    @Test("重なる子の群の opacity は、子ごとに掛かる近似 (#2878) のあいだ、参照と重心が外れる (既知)")
    func overlappingGroupOpacityIsAKnownMismatch() throws {
        let row = try CoverageTable.row(.svgPrimitives, on: .distanceField, comparing: .halfToneAndCentroid)
        let report = try Self.run("svg-group-overlap", templates: [Self.overlappingGroup], row: row)
        // #2878 が直ったら、ここは赤が記録されず「既知の問題が起きなかった」で赤になる。包みを外して、
        // 重なる群を primitivesMatchTheReference の見本へ移す
        withKnownIssue("#2878: 群の opacity を子ごとに掛けるので、重なった所が参照より濃く、重心がずれる") {
            #expect(report.failure == nil, "\(report.failure ?? "")")
        }
    }

    @Test("生成する SVG は、対象外の入力 (CSS の優先順位) を含まない")
    func templatesAvoidTheOutOfScopeInputs() {
        let all = Self.pathTemplates + Self.primitiveTemplates + [Self.overlappingGroup]
        for template in all {
            let text = Self.document(template, tx: 64, ty: 64, scale: 1, degrees: 0)
            for marker in CoverageTable.svgOutOfScopeMarkers {
                #expect(!text.contains(marker), "\(template.name) が \(marker) を含む")
            }
        }
    }
}
