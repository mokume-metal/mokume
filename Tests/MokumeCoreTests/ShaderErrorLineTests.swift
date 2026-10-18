// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 断片の組み立ての誤りが、利用者の書いた行を指すこと (#2457)。GPU を要する (Metal に組ませる)。
///
/// 失敗の説明は「上の理由が指す所を、あなたが書いた断片の中で直せ」と言う。理由の行が前置きを
/// 足した原文の行 (`program_source:1053:12`) だと、書いた断片のどこにも無い行を指す。
/// **期待の行と桁は、断片の文字列から独立に数える** (`foo` の在処)。
@Suite(
    "断片の誤りの行",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ShaderErrorLineTests {
    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 16, height: 16)
    }

    /// 断片を作る経路。
    enum Route: String, CaseIterable, Sendable {
        case makeShader, loadShader, makeEffect, loadEffect, makeComputation, loadComputation
    }

    /// 経路ごとの、`foo` (宣言していない名前) を読む断片。計算の入口の名前は、ファイルから読む
    /// ときはファイル名になるので、両方で `probe` に揃える。
    private static func brokenBody(for route: Route) -> String {
        switch route {
        case .makeShader, .loadShader:
            "float4 paint(Fragment in, Values values) {\n    return foo;\n}"
        case .makeEffect, .loadEffect:
            "float4 effect(Pixel in, Values values) {\n    return foo;\n}"
        case .makeComputation, .loadComputation:
            """
            kernel void probe(device float *out [[buffer(0)]],
                              uint id [[thread_position_in_grid]])
            {
                out[id] = foo;
            }
            """
        }
    }

    /// 誤りが名乗るはずの名前。文字列から作った断片は `name:` (既定の名前)、ファイルから読んだ
    /// 断片はファイル名。
    private static func expectedName(for route: Route) -> String {
        switch route {
        case .makeShader: "shader"
        case .makeEffect: "effect"
        case .makeComputation: "probe"
        case .loadShader, .loadEffect, .loadComputation: "probe.metal"
        }
    }

    /// `needle` の最初の在処を、1 から数えた行と桁で。
    private static func location(of needle: String, in body: String) throws -> String {
        let lines = body.components(separatedBy: "\n")
        let row = try #require(lines.firstIndex { $0.contains(needle) })
        let column = try #require(lines[row].range(of: needle))
        return "\(row + 1):\(lines[row].distance(from: lines[row].startIndex, to: column.lowerBound) + 1)"
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-shader-line-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 経路で断片を作り、投げた失敗の文面を返す。組めてしまえば記録して `nil`。
    private func failure(
        of body: String, via route: Route, on canvas: Canvas,
        values: [String: ShaderValue] = [:], surfaces: [String: ShaderSurface] = [:]
    ) throws -> String? {
        try caught(of: body, via: route, on: canvas, values: values, surfaces: surfaces)
            .map { "\($0)" }
    }

    /// 経路で断片を作り、投げた失敗を返す。組めてしまえば記録して `nil`。ファイルから読む経路は
    /// `probe.metal` に書いて読む。`surfaces:` は塗りの経路でだけ渡す。
    private func caught(
        of body: String, via route: Route, on canvas: Canvas,
        values: [String: ShaderValue] = [:], surfaces: [String: ShaderSurface] = [:],
        file: URL? = nil
    ) throws -> ShaderFailure? {
        let file = try file ?? makeTemporaryDirectory().appendingPathComponent("probe.metal")
        try body.write(to: file, atomically: true, encoding: .utf8)
        do {
            switch route {
            case .makeShader: _ = try canvas.makeShader(body, values: values, surfaces: surfaces)
            case .loadShader: _ = try canvas.loadShader(file.path, values: values, surfaces: surfaces)
            case .makeEffect: _ = try canvas.makeEffect(body, values: values)
            case .loadEffect: _ = try canvas.loadEffect(file.path, values: values)
            case .makeComputation: _ = try canvas.makeComputation(body, name: "probe", values: values)
            case .loadComputation: _ = try canvas.loadComputation(file.path, values: values)
            }
        } catch {
            return error
        }
        Issue.record("\(route) で、壊れた断片が組めてしまった")
        return nil
    }

    @Test("組み立ての誤りは、利用者の名前と、書いた断片の中の行と桁を名乗る", arguments: Route.allCases)
    func theReasonPointsAtTheLineYouWrote(_ route: Route) throws {
        let body = Self.brokenBody(for: route)
        let text = try #require(try failure(of: body, via: route, on: makeCanvas()))
        let place = "\(Self.expectedName(for: route)):\(try Self.location(of: "foo", in: body))"
        #expect(text.contains("\(place): error"), "\(place) を名乗らない:\n\(text)")
        #expect(!text.contains("program_source"), "前置きを足した原文の行を指している:\n\(text)")
    }

    /// 前置きの中の行は、利用者の名前を名乗らない。前置きの定数 (`Kinds.metal` の `kAdd`) を
    /// 断片の 1 行目で定義し直すと、誤りは断片の 1 行目、前の定義の知らせは前置きの側に出る。
    @Test("前置きを指す知らせは、本体の名前で出て、利用者の名前を名乗らない", arguments: Route.allCases)
    func thePreludeIsNamedAsMokumes(_ route: Route) throws {
        let body = "constant uint kAdd = 7;\n" + Self.brokenBody(for: route).replacingOccurrences(
            of: "foo", with: route == .makeComputation || route == .loadComputation ? "0.0" : "in.color")
        let text = try #require(try failure(of: body, via: route, on: makeCanvas()))
        #expect(text.contains("\(Self.expectedName(for: route)):1:"), "断片の 1 行目を名乗らない:\n\(text)")
        #expect(text.contains("mokume/Kinds.metal:"), "前の定義が本体の名前で出ない:\n\(text)")
        #expect(!text.contains("program_source"), "\(text)")
    }

    @Test("面を宣言した断片でも、誤りは書いた断片の行を名乗る")
    func aFragmentWithSurfacesStillPointsAtItsOwnLine() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        let body = """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.grain, foo);
            }
            """
        var text = ""
        do {
            _ = try canvas.makeShader(body, values: ["level": 1], surfaces: ["grain": .image(image)])
            Issue.record("壊れた断片が組めてしまった")
        } catch {
            text = "\(error)"
        }
        let place = "shader:\(try Self.location(of: "foo", in: body))"
        #expect(text.contains("\(place): error"), "\(place) を名乗らない:\n\(text)")
    }

    /// `name:` は利用者が何でも書ける。名乗りの中で逃がしても、誤りは書いた名前 (改行と制御文字は
    /// 空白にした形) で出る。NUL は原稿をそこで切り、`??!` は三文字表記として `|` に読み替えられうる。
    @Test("引用符・NUL・疑問符を含む名前の断片も組めて、誤りはその名前で出る", arguments: [
        ("my \"odd\" shader", "my \"odd\" shader"),
        ("nul\u{0}shader", "nul shader"),
        ("what??!", "what??!"),
    ])
    func anOddNameIsReportedAsWritten(_ name: String, _ reported: String) throws {
        let canvas = try makeCanvas()
        // 組めること: 名前が名乗りを壊すと、正しい断片まで組めなくなる
        _ = try canvas.makeShader(
            "float4 paint(Fragment in, Values values) { return in.color; }", name: name)
        let body = Self.brokenBody(for: .makeShader)
        var text = ""
        do {
            _ = try canvas.makeShader(body, name: name)
            Issue.record("壊れた断片が組めてしまった")
        } catch {
            text = "\(error)"
        }
        #expect(text.contains("\(reported):2:12: error"), "\(text)")
        // 名乗りの行への知らせ (三文字表記など) が混ざらない
        #expect(!text.contains("trigraph"), "\(text)")
        #expect(!text.contains(":1:"), "名乗りの行か本文の 1 行目への知らせが出た:\n\(text)")
    }

    /// 経路ごとの、組める断片。
    private static func workingBody(for route: Route) -> String {
        switch route {
        case .makeShader, .loadShader: "float4 paint(Fragment in, Values values) { return in.color; }"
        case .makeEffect, .loadEffect: "float4 effect(Pixel in, Values values) { return in.color; }"
        case .makeComputation, .loadComputation:
            "kernel void probe(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = 0.0; }"
        }
    }

    /// 差し替えの経路は 3 者 (塗り・効果・計算) が別々に組み立ての口を呼ぶので、それぞれで見る。
    @Test(
        "保存して差し替えに失敗したときの理由も、ファイル名と書いた行を名乗る",
        arguments: [Route.loadShader, .loadEffect, .loadComputation])
    func aFailedReloadPointsAtTheLineYouWrote(_ route: Route) throws {
        let canvas = try makeCanvas()
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("probe.metal")
        try Self.workingBody(for: route).write(to: url, atomically: true, encoding: .utf8)
        let reload: () -> String?
        switch route {
        case .loadShader:
            let shader = try canvas.loadShader(url.path)
            reload = { shader.reload(); return shader.failure }
        case .loadEffect:
            let effect = try canvas.loadEffect(url.path)
            reload = { effect.reload(); return effect.failure }
        default:
            let computation = try canvas.loadComputation(url.path)
            reload = { computation.reload(); return computation.failure }
        }

        let body = Self.brokenBody(for: route)
        try body.write(to: url, atomically: true, encoding: .utf8)
        let failure = try #require(reload())
        #expect(failure.contains("probe.metal:\(try Self.location(of: "foo", in: body)): error"), "\(failure)")
        #expect(!failure.contains("program_source"), "\(failure)")
    }

    // MARK: - 入口の書き違え (#2782)

    /// 経路ごとの、入口の名前を書き違えた断片 (`paint` → `pain`・`effect` → `efect`・計算の
    /// `probe` → `prob`)。
    private static func misnamedEntryBody(for route: Route) -> String {
        switch route {
        case .makeShader, .loadShader: "float4 pain(Fragment in, Values values) {\n    return float4(1);\n}"
        case .makeEffect, .loadEffect: "float4 efect(Pixel in, Values values) {\n    return in.color;\n}"
        case .makeComputation, .loadComputation:
            "kernel void prob(device float *out [[buffer(0)]], uint id [[thread_position_in_grid]]) { out[id] = 0.0; }"
        }
    }

    /// 経路ごとの、言い直しが言うはずの入口の形。
    private static func expectedEntry(for route: Route) -> String {
        switch route {
        case .makeShader, .loadShader: "float4 paint(Fragment in, Values values)"
        case .makeEffect, .loadEffect: "float4 effect(Pixel in, Values values)"
        case .makeComputation, .loadComputation: "kernel void probe("
        }
    }

    /// 理由の 1 行目 (`Cannot build the shader: <名前>`) の次の行。言い直しはここに入る。
    private static func lineAfterHeadline(in text: String) throws -> String {
        let lines = text.components(separatedBy: "\n")
        let headline = try #require(lines.firstIndex { $0.hasPrefix("Cannot build the shader: ") }, "\(text)")
        return try #require(lines.indices.contains(headline + 1) ? lines[headline + 1] : nil, "\(text)")
    }

    /// 変更前は、塗りと効果がリンクの段の `Undefined symbol(s)` と内部の記号の名前だけで、計算は
    /// パイプラインの作成でプロセスごと落ちた (`computeFunction must not be nil`・#2782 の実測)。
    @Test("入口を書き違えた断片は、理由の 1 行目の次で、期待する入口の形を断片の名前で言う", arguments: Route.allCases)
    func aMisnamedEntryIsRestated(_ route: Route) throws {
        let text = try #require(try failure(of: Self.misnamedEntryBody(for: route), via: route, on: makeCanvas()))
        let line = try Self.lineAfterHeadline(in: text)
        #expect(line.hasPrefix("\(Self.expectedName(for: route)): error: "), "\(text)")
        #expect(line.contains(Self.expectedEntry(for: route)), "\(text)")
        switch route {
        case .makeComputation, .loadComputation: break
        default:
            // Metal の元の文面は下に残る
            #expect(text.contains("Undefined symbol"), "\(text)")
        }
    }

    /// `surfaces:` の有無で入口の引数の数が変わる (前置きの `#ifdef MOKUME_SURFACES`)。取り違えは
    /// 面を渡したときはリンクの段、渡さないときは `Surfaces` の型が無いので組み立ての段で落ちる。
    @Test(
        "面の有無と入口の引数を取り違えた塗りは、要る形を言う",
        arguments: [Route.makeShader, .loadShader], [true, false])
    func aPaintWithTheWrongSurfacesIsRestated(_ route: Route, _ passSurfaces: Bool) throws {
        let canvas = try makeCanvas()
        let surfaces: [String: ShaderSurface] =
            passSurfaces ? ["grain": .image(try canvas.createImage(2, 2))] : [:]
        let body = passSurfaces
            ? "float4 paint(Fragment in, Values values) {\n    return float4(1);\n}"
            : "float4 paint(Fragment in, Values values, Surfaces surfaces) {\n    return float4(1);\n}"
        let text = try #require(try failure(of: body, via: route, on: canvas, surfaces: surfaces))
        let line = try Self.lineAfterHeadline(in: text)
        let expected = passSurfaces
            ? "float4 paint(Fragment in, Values values, Surfaces surfaces)"
            : "float4 paint(Fragment in, Values values)"
        #expect(line.hasPrefix("\(Self.expectedName(for: route)): error: "), "\(text)")
        #expect(line.contains(expected), "\(text)")
        #expect(line.contains("surfaces:"), "\(text)")
    }

    @Test("引数の型を書き違えた塗り (Values が抜けた paint) も、期待する形を言う")
    func aPaintWithMissingValuesIsRestated() throws {
        let text = try #require(try failure(
            of: "float4 paint(Fragment in) {\n    return float4(1);\n}", via: .makeShader, on: makeCanvas()))
        let line = try Self.lineAfterHeadline(in: text)
        #expect(line.hasPrefix("shader: error: "), "\(text)")
        #expect(line.contains("float4 paint(Fragment in, Values values)"), "\(text)")
    }

    /// 前置きに無い関数を呼んだリンクの失敗は、入口の書き違えではない。
    @Test("入口以外の記号が未定義なら、言い直さずに今の文面のまま出る")
    func anotherUndefinedSymbolIsNotRestated() throws {
        let body = "float helper(float x);\nfloat4 paint(Fragment in, Values values) {\n    return float4(helper(1));\n}"
        let text = try #require(try failure(of: body, via: .makeShader, on: makeCanvas()))
        #expect(text.contains("'_Z6helperf'"), "\(text)")
        #expect(!text.contains("shader: error:"), "入口の書き違えとして言い直した:\n\(text)")
    }

    /// 保存して入口を書き違えたときも、差し替えの失敗として同じ言い直しが出る。計算は変更前、
    /// 差し替えの組み立てでプロセスごと落ちた。
    @Test(
        "保存して入口を書き違えても、差し替えの失敗が期待する入口の形を言う",
        arguments: [Route.loadShader, .loadEffect, .loadComputation])
    func aFailedReloadWithAMisnamedEntryIsRestated(_ route: Route) throws {
        let canvas = try makeCanvas()
        let url = try makeTemporaryDirectory().appendingPathComponent("probe.metal")
        try Self.workingBody(for: route).write(to: url, atomically: true, encoding: .utf8)
        let reload: () -> String?
        switch route {
        case .loadShader:
            let shader = try canvas.loadShader(url.path)
            reload = { shader.reload(); return shader.failure }
        case .loadEffect:
            let effect = try canvas.loadEffect(url.path)
            reload = { effect.reload(); return effect.failure }
        default:
            let computation = try canvas.loadComputation(url.path)
            reload = { computation.reload(); return computation.failure }
        }
        try Self.misnamedEntryBody(for: route).write(to: url, atomically: true, encoding: .utf8)
        let failure = try #require(reload())
        #expect(failure.contains("probe.metal: error: "), "\(failure)")
        #expect(failure.contains(Self.expectedEntry(for: route)), "\(failure)")
    }

    @Test("入口が正しい断片は、今までどおり組める", arguments: Route.allCases)
    func aCorrectEntryStillBuilds(_ route: Route) throws {
        try build(Self.workingBody(for: route), via: route, on: makeCanvas())
    }

    /// 経路で断片を作る。組めなければ投げる。
    private func build(
        _ body: String, via route: Route, on canvas: Canvas,
        values: [String: ShaderValue] = [:], surfaces: [String: ShaderSurface] = [:]
    ) throws {
        let url = try makeTemporaryDirectory().appendingPathComponent("probe.metal")
        try body.write(to: url, atomically: true, encoding: .utf8)
        switch route {
        case .makeShader: _ = try canvas.makeShader(body, values: values, surfaces: surfaces)
        case .loadShader: _ = try canvas.loadShader(url.path, values: values, surfaces: surfaces)
        case .makeEffect: _ = try canvas.makeEffect(body, values: values)
        case .loadEffect: _ = try canvas.loadEffect(url.path, values: values)
        case .makeComputation: _ = try canvas.makeComputation(body, name: "probe", values: values)
        case .loadComputation: _ = try canvas.loadComputation(url.path, values: values)
        }
    }

    // MARK: - 値と面の名前 (#2783)

    /// 失敗の `path` が名乗るはずのもの。文字列から作れば `name:`、ファイルから読めば読んだ在処。
    private static func expectedPath(for route: Route, file: URL) -> String {
        switch route {
        case .makeShader: "shader"
        case .makeEffect: "effect"
        case .makeComputation: "probe"
        case .loadShader, .loadEffect, .loadComputation: file.path
        }
    }

    /// 変更前は、`["tint color": 1]` が `mokume/Values:2:15: error: expected ';'` と本体の前置きの名で
    /// 出て、`""`・`"a; float b"` は組み上がったまま宣言の欄と詰める値がずれた (#2783 の実測)。
    @Test(
        "識別子でない値の名前は、組み立ての前に values: の名前として名指しで断る",
        arguments: Route.allCases, ["tint color", "", "a; float b", "1x"])
    func anUnusableValueNameIsRefused(_ route: Route, _ name: String) throws {
        let file = try makeTemporaryDirectory().appendingPathComponent("probe.metal")
        let failure = try caught(
            of: Self.workingBody(for: route), via: route, on: makeCanvas(), values: [name: 1], file: file)
        guard case .notCompilable(let path, let reason) = try #require(failure) else {
            Issue.record("notCompilable で断らない: \(String(describing: failure))")
            return
        }
        #expect(path == Self.expectedPath(for: route, file: file))
        #expect(reason.contains(name.debugDescription), "\(reason)")
        #expect(reason.contains("values:"), "\(reason)")
        #expect(!reason.contains("mokume/"), "本体の前置きの名で出た:\n\(reason)")
    }

    @Test(
        "識別子でない面の名前は、組み立ての前に surfaces: の名前として名指しで断る",
        arguments: [Route.makeShader, .loadShader], ["my grain", "", "a;b"])
    func anUnusableSurfaceNameIsRefused(_ route: Route, _ name: String) throws {
        let canvas = try makeCanvas()
        let file = try makeTemporaryDirectory().appendingPathComponent("probe.metal")
        let failure = try caught(
            of: "float4 paint(Fragment in, Values values, Surfaces surfaces) { return in.color; }",
            via: route, on: canvas, surfaces: [name: .image(try canvas.createImage(2, 2))], file: file)
        guard case .notCompilable(let path, let reason) = try #require(failure) else {
            Issue.record("notCompilable で断らない: \(String(describing: failure))")
            return
        }
        #expect(path == Self.expectedPath(for: route, file: file))
        #expect(reason.contains(name.debugDescription), "\(reason)")
        #expect(reason.contains("surfaces:"), "\(reason)")
        #expect(!reason.contains("mokume/"), "本体の前置きの名で出た:\n\(reason)")
    }

    @Test("識別子の値の名前 (ASCII の外も) は、今までどおり 6 つの口で組める", arguments: Route.allCases)
    func usableValueNamesStillBuild(_ route: Route) throws {
        let body: String
        switch route {
        case .makeShader, .loadShader:
            body = "float4 paint(Fragment in, Values values) { return in.color * (values.tint + values._k1 + values.波); }"
        case .makeEffect, .loadEffect:
            body = "float4 effect(Pixel in, Values values) { return in.color * (values.tint + values._k1 + values.波); }"
        case .makeComputation, .loadComputation:
            body = """
                kernel void probe(device float *out [[buffer(0)]],
                                  constant Values &values [[buffer(MOKUME_VALUES)]],
                                  uint id [[thread_position_in_grid]]) {
                    out[id] = values.tint + values._k1 + values.波;
                }
                """
        }
        try build(body, via: route, on: makeCanvas(), values: ["tint": 1, "_k1": 2, "波": 3])
    }

    @Test("識別子の面の名前 (ASCII の外も) は、今までどおり組める", arguments: [Route.makeShader, .loadShader])
    func usableSurfaceNamesStillBuild(_ route: Route) throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        let body = """
            float4 paint(Fragment in, Values values, Surfaces surfaces) {
                return mokume_sample(surfaces.波, in.uv) + mokume_sample(surfaces._k1, in.uv);
            }
            """
        try build(body, via: route, on: canvas, surfaces: ["波": .image(image), "_k1": .image(image)])
    }

    // MARK: - Metal で使えない名前 (#2783 の反証)

    /// 名指しの行の頭。
    private static func namedLine(_ fragment: String, _ name: String, _ argument: String) -> String {
        "\(fragment): error: the name \"\(name)\" in \(argument) cannot be used in Metal"
    }

    /// 予約語・組み込みの型と同じ値の名前は字の並びを通り、`float half;` で組み立てが落ちる。変更前は
    /// 誤りが `mokume/Values:2:11` を名乗るだけで、直す先が Swift の引数だと言わなかった。
    @Test(
        "予約語・組み込みの型と同じ値の名前は、組み立ての誤りに values: の名前としての名指しが先に立つ",
        arguments: Route.allCases, ["half", "float", "return"])
    func aKeywordValueNameIsNamed(_ route: Route, _ name: String) throws {
        let text = try #require(
            try failure(of: Self.workingBody(for: route), via: route, on: makeCanvas(), values: [name: 1]))
        let line = try Self.lineAfterHeadline(in: text)
        #expect(line.hasPrefix(Self.namedLine(Self.expectedName(for: route), name, "values:")), "\(text)")
        #expect(text.contains("mokume/Values:"), "Metal の文面が下に残らない:\n\(text)")
    }

    @Test("予約語・組み込みの型と同じ面の名前は、surfaces: の名前として名指す", arguments: [Route.makeShader, .loadShader])
    func aKeywordSurfaceNameIsNamed(_ route: Route) throws {
        let canvas = try makeCanvas()
        let text = try #require(try failure(
            of: "float4 paint(Fragment in, Values values, Surfaces surfaces) { return in.color; }",
            via: route, on: canvas, surfaces: ["half": .image(try canvas.createImage(2, 2))]))
        let line = try Self.lineAfterHeadline(in: text)
        #expect(line.hasPrefix(Self.namedLine(Self.expectedName(for: route), "half", "surfaces:")), "\(text)")
    }

    /// 前置きのマクロと同じ名前。面の名前なら宣言の行で落ち、値の名前なら断片で読んだ行で落ちて
    /// マクロの知らせが添う (計算の `MOKUME_VALUES` は `mokume/Compute.metal` のマクロ)。
    @Test("前置きのマクロと同じ名前は、渡した口の名前として名指す")
    func aMacroNameIsNamed() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        let surfaceText = try #require(try failure(
            of: "float4 paint(Fragment in, Values values, Surfaces surfaces) { return in.color; }",
            via: .makeShader, on: canvas, surfaces: ["MOKUME_SURFACES": .image(image)]))
        #expect(
            try Self.lineAfterHeadline(in: surfaceText)
                .hasPrefix(Self.namedLine("shader", "MOKUME_SURFACES", "surfaces:")), "\(surfaceText)")

        let valueText = try #require(try failure(
            of: "float4 paint(Fragment in, Values values, Surfaces surfaces) { return in.color * values.MOKUME_SURFACES; }",
            via: .makeShader, on: canvas, values: ["MOKUME_SURFACES": 1], surfaces: ["grain": .image(image)]))
        #expect(
            try Self.lineAfterHeadline(in: valueText)
                .hasPrefix(Self.namedLine("shader", "MOKUME_SURFACES", "values:")), "\(valueText)")

        let computeText = try #require(try failure(
            of: """
                kernel void probe(device float *out [[buffer(0)]],
                                  constant Values &values [[buffer(MOKUME_VALUES)]],
                                  uint id [[thread_position_in_grid]]) {
                    out[id] = values.MOKUME_VALUES;
                }
                """,
            via: .makeComputation, on: canvas, values: ["MOKUME_VALUES": 1]))
        #expect(
            try Self.lineAfterHeadline(in: computeText)
                .hasPrefix(Self.namedLine("probe", "MOKUME_VALUES", "values:")), "\(computeText)")
    }

    /// 構造体と同じ名前の欄 (`struct Values { float Values; }`) は Metal が通し、断片から読める
    /// (2026-10-18 に実測)。断る必要が無いので、組めることを守る。
    @Test("構造体と同じ名前 (Values・Surfaces) は、組めて断片から読める")
    func structNamesBuild() throws {
        let canvas = try makeCanvas()
        let image = try canvas.createImage(2, 2)
        try build(
            "float4 paint(Fragment in, Values values) { return in.color * values.Values; }",
            via: .makeShader, on: canvas, values: ["Values": 1])
        try build(
            "float4 paint(Fragment in, Values values, Surfaces surfaces) { return mokume_sample(surfaces.Surfaces, in.uv); }",
            via: .makeShader, on: canvas, surfaces: ["Surfaces": .image(image)])
    }
}
