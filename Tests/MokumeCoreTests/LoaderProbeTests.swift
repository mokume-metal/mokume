// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeProbe
import MokumeTestSupport
import Testing

@testable import MokumeCore
@testable import mokume

/// **読み込みの口に、壊した入力と性質の述語を当てる** ([#3220]・#3207 の提案 5)。GPU を使わない。
///
/// 読み込みの口は、人が書いた (壊れうる) 文字を受ける最初の関所で、Bug の多くは「落ちる」のではなく
/// 「黙って別のものを返す」形で見つかってきた (#3022・STL の 16 件)。ここは 2 本立てで見る。
///
/// - **壊した入力** (``broken(_:samples:body:)``): 正しい見本から 1 バイト反転・切り詰め・NUL 挿入・
///   桁の巨大化をした入力 (``ProbeBytes``) を口へ渡し、「落ちない・止まらない・成功か名乗りつきの失敗の
///   どちらかで答える」を見る。名乗りつきとは、失敗が渡した名前を含み、理由か行を持つこと。口の数は 8 つ
///   (SVG・OBJ・STL・JSON・CSV・XML・params、MCP の JSON-RPC は `JSONRPCProbeTests`)
/// - **性質の述語**: 落ちない入力でも壊れる約束を、生成した 2 つの入力の関係で書く。値の前後の空白だけが
///   違う SVG は読みも名乗りも同じ (#3022)・大きさだけが違う文字の STL は同じ答えを返す (#2494)
///
/// seed は PR・queue では固定で、件数は少ない (``cases``)。定期の検査が `MOKUME_PROBE_FRESH`・
/// `MOKUME_PROBE_SCALE` で新しい seed と多い件数を足す (``Probe``)。赤の文面は `[parse seed=…]` で始まり、
/// `MOKUME_PROBE_SEED` に渡すと同じ入力を再現する。落ちる入力は、プロセスが落ちる前に標準エラーへ
/// `[probe] 落ちる直前に渡していた …` と名乗る (``Guarded``)。
///
/// 失敗は `\(error as Any)` で文面に載せる。失敗の型の `description` は main actor に隔離された適合なので、
/// nonisolated のこの suite からは静的に使えない (下限の Xcode が `[#IsolatedConformances]` で拒む・#3199)。
///
/// [#3220]: https://github.com/mokume-metal/mokume/issues/3220
@Suite("読み込みの口は、壊した入力にも落ちず止まらず名乗って答え、空白や大きさだけの違いで答えを変えない")
nonisolated struct LoaderProbeTests {
    /// 口ごとに回す件数 (PR・queue の経路)。
    static let cases = 64

    /// 1 件が返るまでの期限 (秒)。読み込みの口は ms で返るので、越えたら止まっている。止まった本体は
    /// 殺せず CPU を使い続けるので、縮めるときの呼び直し (``shrinkSteps``) も少なくする。
    static let limit: TimeInterval = 5
    static let shrinkSteps = 12

    // MARK: - 壊した入力の道具

    /// 失敗が「名乗りつき」か。名乗りが無ければその理由、あれば `nil`。
    static func answers(_ failure: DataFailure, path: String) -> String? {
        switch failure {
        case .malformed(let named, let line, let reason):
            if named != path { return "失敗が渡した名前を名乗らない (\(named))" }
            if line < 1 { return "失敗が行を名乗らない (line \(line))" }
            if reason.isEmpty { return "失敗が理由を名乗らない" }
            return nil
        case .unreadable(let named):
            return named == path ? nil : "失敗が渡した名前を名乗らない (\(named))"
        default:
            return "想定していない失敗 \(failure as Any)"
        }
    }

    /// 口 `loader` に、`samples` を壊した入力を `cases` 件渡す。`body` は入力を口へ渡し、約束が破れれば
    /// その文を返す (`nil` は約束どおり)。
    static func broken(
        _ loader: String, samples: [[UInt8]], cases: Int = LoaderProbeTests.cases,
        body: @escaping @Sendable ([UInt8]) -> String?
    ) -> Probe.Report {
        Probe.run(
            "parse", suite: "LoaderProbeTests", key: loader, axes: ProbeBytes.axes(samples: samples.count),
            cases: cases, shrinkSteps: shrinkSteps
        ) { input in
            let bytes = ProbeBytes.mutate(samples, input)
            let named = "\(loader) \(ProbeBytes.describe(bytes))"
            // 落ちる入力は縮められないので、落ちる前に seed と入力を長めに名乗る
            let crashLabel = "[parse \(input.seedText)] \(loader) \(ProbeBytes.describe(bytes, limit: 400))"
            guard let verdict = Guarded.run(crashLabel, limit: limit, { body(bytes) }) else {
                return .fail("\(named) が \(Int(limit)) 秒で返らない")
            }
            return verdict.map { .fail("\(named): \($0)") } ?? .pass
        }
    }

    static func expectGreen(_ report: Probe.Report, _ loader: String) {
        #expect(report.failure == nil, "\(report.failure ?? "")")
        #expect(report.failure != nil || report.ran >= cases, "\(loader): 見たのは \(report.ran) 件・約束の外 \(report.skipped) 件")
    }

    static func bytes(_ text: String) -> [UInt8] { Array(text.utf8) }

    // MARK: - 8 つの口のうちの 6 つ (文字を読む口)

    static let svgSamples: [[UInt8]] = [
        bytes(
            """
            <svg xmlns="http://www.w3.org/2000/svg" width="100" height="80" viewBox="0 0 100 80">
              <rect x="10" y="10" width="30" height="20" fill="#ff0000" rx="3"/>
              <circle cx="60" cy="40" r="15" stroke="blue" stroke-width="2" fill="none"/>
              <path d="M10 70 C 20 50, 40 50, 50 70 Z" transform="translate(5 5) rotate(10)"/>
            </svg>
            """),
        bytes(
            """
            <svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 50 50" preserveAspectRatio="xMidYMid slice">
              <style>.a { fill: red; opacity: .5 }</style>
              <g transform="scale(2)" opacity="0.5">
                <ellipse class="a" cx="10" cy="10" rx="5" ry="3"/>
                <line x1="0" y1="0" x2="10" y2="10" stroke="#000"/>
                <polygon points="0,0 10,0 5,8" fill-rule="evenodd"/>
              </g>
              <text x="1" y="2">hi</text>
            </svg>
            """),
    ]

    @Test("SVGFile.parse は、壊れた入力にも落ちず止まらず、成功か名乗りつきの失敗で答える")
    func svg() {
        let report = Self.broken("SVGFile.parse", samples: Self.svgSamples) { bytes in
            do throws(DataFailure) {
                _ = try SVGFile.parse(ProbeBytes.text(bytes), path: "probe.svg")
                return nil
            } catch { return Self.answers(error, path: "probe.svg") }
        }
        Self.expectGreen(report, "SVGFile.parse")
    }

    static let objSamples: [[UInt8]] = [
        bytes(
            """
            # pyramid
            mtllib pyramid.mtl
            o pyramid
            v -1.0 0.0 -1.0
            v 1.0 0.0 -1.0
            v 1.0 0.0 1.0
            v -1.0 0.0 1.0
            v 0.0 1.6 0.0
            s off
            usemtl stone
            f 1 2 5
            f 2 3 5
            f 3 4 5
            f 4 1 5
            f 4 3 2 1
            """),
        bytes(
            """
            v -1 0 0
            v 1 0 0
            v 1 2 0
            v -1 2 0
            vt 0.25 0.8
            vt 0.75 0.8
            vt 0.75 0.1
            vn 0 0 1
            f 1/1/1 2/2/1 3/3/1
            f 1//1 3//1 4//1
            f 1/-3/1 3/-2/1 4/-1/1
            """),
    ]

    @Test("ModelFile.parse (OBJ) は、壊れた入力にも落ちず止まらず、答える")
    func obj() {
        let report = Self.broken("ModelFile.parse", samples: Self.objSamples) { bytes in
            _ = ModelFile.parse(ProbeBytes.text(bytes))
            return nil
        }
        Self.expectGreen(report, "ModelFile.parse")
    }

    static let jsonSamples: [[UInt8]] = [
        bytes(#"{"name":"mokume","count":12,"ratio":-0.25e2,"tags":["a","b\n","é"],"nested":{"ok":true,"none":null}}"#),
        bytes(#"[1, 2.5, -3, 1e3, {"a": [true, false, null]}, "text"]"#),
    ]

    @Test("JSONFile.parse は、壊れた入力にも落ちず止まらず、成功か名乗りつきの失敗で答える")
    func json() {
        let report = Self.broken("JSONFile.parse", samples: Self.jsonSamples) { bytes in
            do throws(DataFailure) {
                _ = try JSONFile.parse(ProbeBytes.text(bytes), path: "probe.json")
                return nil
            } catch { return Self.answers(error, path: "probe.json") }
        }
        Self.expectGreen(report, "JSONFile.parse")
    }

    static let tableSamples: [[UInt8]] = [
        bytes("name,x,y\nalpha,1,2\nbeta,3,4\n\"gamma, with comma\",5,6\n"),
        bytes("id,note\n1,\"quoted \"\"inner\"\"\nline\"\n2,plain\r\n3,\n"),
    ]

    @Test("TableFile.parse は、壊れた入力にも落ちず止まらず、成功か名乗りつきの失敗で答える")
    func table() {
        let report = Self.broken("TableFile.parse", samples: Self.tableSamples) { bytes in
            do throws(DataFailure) {
                _ = try TableFile.parse(ProbeBytes.text(bytes), header: true, path: "probe.csv")
                return nil
            } catch { return Self.answers(error, path: "probe.csv") }
        }
        Self.expectGreen(report, "TableFile.parse")
    }

    static let xmlSamples: [[UInt8]] = [
        bytes(
            """
            <?xml version="1.0" encoding="UTF-8"?>
            <!-- comment -->
            <root id="1"><item name="a">text &amp; more</item><item name="b"/><![CDATA[raw <data>]]></root>
            """),
        bytes("<a><b x='1'><c>deep</c></b><b x='2'>&#x41;&lt;</b></a>"),
    ]

    @Test("XMLFile.parse は、壊れた入力にも落ちず止まらず、成功か名乗りつきの失敗で答える")
    func xml() {
        let report = Self.broken("XMLFile.parse", samples: Self.xmlSamples) { bytes in
            do throws(DataFailure) {
                _ = try XMLFile.parse(ProbeBytes.text(bytes), path: "probe.xml")
                return nil
            } catch { return Self.answers(error, path: "probe.xml") }
        }
        Self.expectGreen(report, "XMLFile.parse")
    }

    // MARK: - 文字の STL・保存した値 (ファイルを読む口)

    /// 面が `count` 枚の STL (字下げも小数の桁も付けない。1 面で 105 バイト)。
    static func stlText(facets count: Int, name: String = "t") -> String {
        let face = "facet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\n"
        return "solid \(name)\n" + String(repeating: face, count: count) + "endsolid \(name)\n"
    }

    /// 面が `count` 枚のバイナリの STL (80 バイトの見出し・面の数・面ごとに 50 バイト)。
    static func stlBinary(facets count: Int) -> [UInt8] {
        var data = Data("probe".utf8)
        data.append(Data(count: 80 - data.count))
        func append<T>(_ value: T) { withUnsafeBytes(of: value) { data.append(contentsOf: $0) } }
        append(UInt32(count).littleEndian)
        for index in 0..<count {
            for value in [0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, Float(index)] as [Float] { append(value) }
            append(UInt16(0))
        }
        return Array(data)
    }

    static let stlSamples: [[UInt8]] = [
        bytes(stlText(facets: 1)), bytes(stlText(facets: 3)), stlBinary(facets: 3),
    ]

    /// `bytes` を `directory` の `name` へ書き、`loadSTL` で読む。
    static func loadSTL(_ bytes: [UInt8], in directory: URL, name: String = "probe.stl") throws(ModelFailure)
        -> ModelFile.Parsed
    {
        let url = directory.appendingPathComponent(name)
        guard (try? Data(bytes).write(to: url)) != nil else { throw .unreadable(path: url.path) }
        return try ModelFile.loadSTL(url, path: url.path, scratch: directory)
    }

    @Test("ModelFile.loadSTL は、壊れた入力にも落ちず止まらず、成功か名乗りつきの失敗で答える")
    func stl() throws {
        let directory = try TestScratch.directory("mokume-loader-probe-stl")
        let report = Self.broken("ModelFile.loadSTL", samples: Self.stlSamples) { bytes in
            do throws(ModelFailure) {
                _ = try Self.loadSTL(bytes, in: directory)
                return nil
            } catch {
                guard case .unreadable(let named) = error else { return "想定していない失敗 \(error as Any)" }
                return named.hasSuffix("probe.stl") ? nil : "失敗が渡した名前を名乗らない (\(named))"
            }
        }
        Self.expectGreen(report, "ModelFile.loadSTL")
    }

    /// 保存の値を戻す先。範囲と候補が決まっているので、戻した値が範囲の外に出ないことを見られる。
    final class Knobbed: Sketch {
        @Param(0...200) var radius: Double = 80
        @Param(1...8) var count: Int = 3
        @Param var spinning: Bool = true
        @Param(choices: ["circle", "square"]) var shape: String = "circle"
    }

    /// 本物の `ParamStore` が書いた保存 (既定のままと、全部動かしたもの)。
    @MainActor
    static func savedParams(in directory: URL) throws -> [[UInt8]] {
        var samples: [[UInt8]] = []
        for index in 0..<2 {
            let url = directory.appendingPathComponent("sample-\(index).json")
            let sketch = Knobbed()
            if index == 1 {
                sketch.radius = 123.5
                sketch.count = 7
                sketch.spinning = false
                sketch.shape = "square"
            }
            ParamStore(registry: ParamRegistry(of: sketch), at: url, warn: { _ in }).flushNow()
            samples.append(Array(try Data(contentsOf: url)))
        }
        return samples
    }

    /// 主の actor の上で走る口なので、期限は掛けられない (落ちる入力の名乗りだけが効く)。
    @MainActor
    @Test("ParamStore.restore は、壊れた保存にも落ちず、戻した値が宣言の範囲と候補に収まる")
    func params() throws {
        let directory = try TestScratch.directory("mokume-loader-probe-params")
        let samples = try Self.savedParams(in: directory)
        let url = directory.appendingPathComponent("params.json")
        let report = Probe.run(
            "parse", suite: "LoaderProbeTests", key: "ParamStore.restore",
            axes: ProbeBytes.axes(samples: samples.count), cases: Self.cases
        ) { input in
            let bytes = ProbeBytes.mutate(samples, input)
            let named = "ParamStore.restore \(ProbeBytes.describe(bytes))"
            Guarded.mark("[parse \(input.seedText)] ParamStore.restore \(ProbeBytes.describe(bytes, limit: 400))")
            defer { Guarded.unmark() }
            guard (try? Data(bytes).write(to: url)) != nil else { return .fail("\(named): 保存を書けない") }
            let sketch = Knobbed()
            let store = ParamStore(registry: ParamRegistry(of: sketch), at: url, warn: { _ in })
            _ = store.restore()
            if !(0...200).contains(sketch.radius) { return .fail("\(named): radius が範囲の外 (\(sketch.radius))") }
            if !(1...8).contains(sketch.count) { return .fail("\(named): count が範囲の外 (\(sketch.count))") }
            if !["circle", "square"].contains(sketch.shape) { return .fail("\(named): shape が候補の外 (\(sketch.shape))") }
            return .pass
        }
        Self.expectGreen(report, "ParamStore.restore")
    }

    // MARK: - 性質: 値の前後の空白だけが違う SVG は、読みも名乗りも同じ (#3022)

    /// 値を `V` に差す SVG の見本 (名乗りの口を要素・属性ごとに 1 つ以上通る)。
    static let spacedTemplates: [String] = [
        #"<svg xmlns="http://www.w3.org/2000/svg" width="V" height="10"><rect width="5" height="5"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="V"><rect width="5" height="5"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 10 10" preserveAspectRatio="V"><rect width="5" height="5"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="V" height="5"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><rect width="5" height="V"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><rect x="V" y="1" width="5" height="5"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><rect rx="V" width="5" height="5"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><circle cx="5" cy="5" r="V"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><ellipse cx="5" cy="5" rx="V" ry="2"/></svg>"#,
        #"<svg xmlns="http://www.w3.org/2000/svg"><line x1="V" y1="0" x2="5" y2="5" stroke="black"/></svg>"#,
    ]

    /// 差す値。読める数・負の数・0・単位つき・読めない語・桁あふれ。
    static let spacedValues = ["5", "-5", "0", "5.5", "10px", "50%", "x", "bogus", "1e999", "-", "0 0 10 10", "none"]

    /// 値の前後に足す空白 (XML が属性の値で空白へ畳むものを含む)。
    static let paddings = ["", " ", "  ", "\t", "\n", " \t "]

    @Test("値の前後の空白だけが違う 2 つの SVG は、読みも描かずに捨てた名乗りも同じ")
    func whitespaceAroundAValueDoesNotChangeTheReading() {
        let axes = [
            ProbeAxis("template", 0..<Double(Self.spacedTemplates.count), simplest: 0, step: 1),
            ProbeAxis("value", 0..<Double(Self.spacedValues.count), simplest: 0, step: 1),
            ProbeAxis("before", 0..<Double(Self.paddings.count), simplest: 0, step: 1),
            ProbeAxis("after", 0..<Double(Self.paddings.count), simplest: 0, step: 1),
        ]
        let report = Probe.run(
            "parse", suite: "LoaderProbeTests", key: "SVGFile.parse whitespace", axes: axes, cases: Self.cases
        ) { input in
            Guarded.mark("[parse \(input.seedText)] SVGFile.parse whitespace \(input)")
            defer { Guarded.unmark() }
            let template = Self.spacedTemplates[Int(input["template"])]
            let value = Self.spacedValues[Int(input["value"])]
            let padded = Self.paddings[Int(input["before"])] + value + Self.paddings[Int(input["after"])]
            let plain = template.replacingOccurrences(of: "\"V\"", with: "\"\(value)\"")
            let spaced = template.replacingOccurrences(of: "\"V\"", with: "\"\(padded)\"")
            // 行は比べない — 値の中の改行は、後ろの要素の行を本当にずらす
            func read(_ text: String) -> String {
                do throws(DataFailure) {
                    let drawing = try SVGFile.parse(text, path: "probe.svg")
                    let skipped = drawing.skipped.map { "\($0.what) ×\($0.count)" }
                    let approximated = drawing.approximated.map { "\($0.what) ×\($0.count)" }
                    return "描くもの \(drawing.items)・捨てた \(skipped)・近似 \(approximated)"
                } catch { return "投げた \(error as Any)" }
            }
            let (left, right) = (read(plain), read(spaced))
            guard left != right else { return .pass }
            return .fail("\(plain) と \(spaced) で読みが違う: \(left) / \(right)")
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        if report.failure == nil { #expect(report.ran >= Self.cases) }
    }

    // MARK: - 性質: 大きさだけが違う文字の STL は、同じ答えを返す (#2494)

    /// 名前の後ろ・先頭に足す文字。空白・タブ・VT・FF・NUL・DEL・ESC。
    static let controls: [UInt8] = [0x20, 0x09, 0x0B, 0x0C, 0x00, 0x7F, 0x1B]

    /// `loadSTL` の答えの種類。面の数 (三角形の数) か、読めない。
    enum Answer: Equatable, CustomStringConvertible {
        case triangles(Int)
        case unreadable
        case other(String)

        var description: String {
            switch self {
            case .triangles(let count): return "\(count) 枚"
            case .unreadable: return "読めない"
            case .other(let text): return text
            }
        }
    }

    static func answer(_ bytes: [UInt8], in directory: URL) -> Answer {
        do throws(ModelFailure) { return .triangles(try loadSTL(bytes, in: directory).positions.count / 3) } catch {
            if case .unreadable = error { return .unreadable }
            return .other("\(error as Any)")
        }
    }

    @Test("面を N 枚書いた文字の STL は、頭や名前の後ろに制御文字があっても、大きさによらず N 枚を返すか読めないと名乗る")
    func textSTLAnswersTheSameAtAnySize() throws {
        let directory = try TestScratch.directory("mokume-loader-probe-size")
        let axes = [
            ProbeAxis("facets", 1..<3, simplest: 1, step: 1),
            ProbeAxis("control", 0..<Double(Self.controls.count), simplest: 0, step: 1),
            ProbeAxis("place", 0..<2, simplest: 0, step: 1),
            // 1 面の文字の STL は 105 バイト。末尾の空白を足して、128 バイト (Model I/O が読み始める大きさ) の
            // 前後 (106〜155) へ大きさを動かす。2 面は 128 バイトを越えるので、大きい側の見本になる
            ProbeAxis("padding", 0..<50, simplest: 0, step: 1),
        ]
        let report = Probe.run(
            "parse", suite: "LoaderProbeTests", key: "ModelFile.loadSTL size", axes: axes, cases: 2 * Self.cases
        ) { input in
            Guarded.mark("[parse \(input.seedText)] ModelFile.loadSTL size \(input)")
            defer { Guarded.unmark() }
            let count = Int(input["facets"])
            let control = Self.controls[Int(input["control"])]
            let text = Self.bytes(Self.stlText(facets: count))
            // place 0: 名前の後ろ (`solid t<c>`)。place 1: 先頭 (`<c>solid t`)
            let head = Self.bytes("solid t")
            let body = Array(text.dropFirst(head.count))
            let file = input["place"] == 0 ? head + [control] + body : [control] + head + body
            // 末尾の空白は最後の改行の前へ入れる
            let small = Self.pad(file, by: Int(input["padding"]))
            let large = Self.pad(file, by: 400)
            let (smallAnswer, largeAnswer) = (Self.answer(small, in: directory), Self.answer(large, in: directory))
            let plausible: [Answer] = [.triangles(count), .unreadable]
            let label = "\(small.count) バイト (\(ProbeBytes.describe(small, limit: 40)))"
            if !plausible.contains(largeAnswer) {
                return .fail("\(label) を大きくした写しの答えが \(largeAnswer) (\(count) 枚でも読めないでもない)")
            }
            if smallAnswer != largeAnswer { return .fail("\(label) は \(smallAnswer)、同じ中身を大きくすると \(largeAnswer)") }
            return .pass
        }
        #expect(report.failure == nil, "\(report.failure ?? "")")
        if report.failure == nil { #expect(report.ran >= Self.cases) }
    }

    /// 最後の `endsolid` の行の後ろへ、空白を `count` 個足す (大きさだけを動かす)。
    static func pad(_ file: [UInt8], by count: Int) -> [UInt8] {
        var out = file
        let at = out.lastIndex(of: 0x0A).map { $0 } ?? out.count
        out.insert(contentsOf: [UInt8](repeating: 0x20, count: count), at: at)
        return out
    }
}
