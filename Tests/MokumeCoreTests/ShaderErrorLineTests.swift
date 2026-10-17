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
        of body: String, via route: Route, on canvas: Canvas
    ) throws -> String? {
        let directory = try makeTemporaryDirectory()
        let file = directory.appendingPathComponent("probe.metal")
        try body.write(to: file, atomically: true, encoding: .utf8)
        do {
            switch route {
            case .makeShader: _ = try canvas.makeShader(body)
            case .loadShader: _ = try canvas.loadShader(file.path)
            case .makeEffect: _ = try canvas.makeEffect(body)
            case .loadEffect: _ = try canvas.loadEffect(file.path)
            case .makeComputation: _ = try canvas.makeComputation(body, name: "probe")
            case .loadComputation: _ = try canvas.loadComputation(file.path)
            }
        } catch {
            return "\(error)"
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

    /// `name:` は利用者が何でも書ける。名乗りの中で逃がしても、誤りは書いた名前のまま出る。
    @Test("引用符を含む名前の断片も組めて、誤りはその名前で出る")
    func anOddNameIsReportedAsWritten() throws {
        let canvas = try makeCanvas()
        let name = "my \"odd\" shader"
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
        #expect(text.contains("\(name):2:12: error"), "\(text)")
    }

    @Test("保存して差し替えに失敗したときの理由も、ファイル名と書いた行を名乗る")
    func aFailedReloadPointsAtTheLineYouWrote() throws {
        let canvas = try makeCanvas()
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("waves.metal")
        try "float4 paint(Fragment in, Values values) { return in.color; }"
            .write(to: url, atomically: true, encoding: .utf8)
        let shader = try canvas.loadShader(url.path)

        let body = Self.brokenBody(for: .loadShader)
        try body.write(to: url, atomically: true, encoding: .utf8)
        shader.reload()
        let failure = try #require(shader.failure)
        #expect(failure.contains("waves.metal:\(try Self.location(of: "foo", in: body)): error"), "\(failure)")
        #expect(!failure.contains("program_source"), "\(failure)")
    }
}
