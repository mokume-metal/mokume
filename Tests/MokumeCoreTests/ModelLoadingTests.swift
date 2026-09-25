// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing
import simd

@testable import MokumeCore

/// 面の口 ``Canvas/loadModel(_:normalize:)`` で読んだモデル ([#1385] 条件 11)。
///
/// 整え方の規則は ``ModelTests`` が ``Model/make(name:parsed:fitting:identity:)`` を直に
/// 呼んで見ている。ただしそこでは合わせる長さを検査が渡しているので、**面が渡す長さ**
/// (短いほうの辺の半分) は通っていない。ここは面から読んで確かめる。
///
/// [#1385]: https://github.com/mokume-metal/mokume/issues/1385
@Suite(
    "面から読むモデル",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct ModelLoadingTests {
    /// 面の大きさ。**横長と縦長の両方**を見る — 片方だけだと、幅だけ・高さだけから
    /// 決める取り違えが緑のまま通る。
    nonisolated static var surfaces: [(width: Int, height: Int)] { [(200, 120), (120, 200)] }

    @Test("面から読むと、いちばん長い辺が面の短いほうの半分になる", arguments: surfaces)
    func loadingFitsHalfTheShorterSide(_ surface: (width: Int, height: Int)) throws {
        let canvas = try CanvasFixture.make(
            gpu: RenderDevice(), width: surface.width, height: surface.height)
        let model = try canvas.loadModel(ModelFixture.pyramid)

        // **頂点そのものから測る。** 報告している大きさだけを見ると、頂点が潰れていても
        // 報告の側が正しければ通ってしまう
        var lowest = SIMD3<Float>(repeating: .infinity)
        var highest = SIMD3<Float>(repeating: -.infinity)
        for point in model.mesh.points {
            lowest = simd_min(lowest, point.position)
            highest = simd_max(highest, point.position)
        }
        let measured = highest - lowest
        // 200 × 120 でも 120 × 200 でも、短いほうの半分 = 60
        #expect(abs(simd_reduce_max(measured) - 60) < 1e-3)
        #expect(abs(simd_reduce_max(model.size) - 60) < 1e-3)
    }

    @Test("整えずに読むと、ファイルの大きさのまま")
    func loadingWithoutNormalizingKeepsTheFileSize() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        let model = try canvas.loadModel(ModelFixture.pyramid, normalize: false)
        // 元の四角錐は幅 2・高さ 1.6・奥行き 2
        #expect(simd_length(model.size - SIMD3(2, 1.6, 2)) < 1e-3)
    }

    /// 既知のモデルと、その中身から数えた値。**どちらも注釈の行 (`#`) は数えない。**
    enum Known: CaseIterable, CustomTestStringConvertible {
        /// 側面 4 枚が三角形・底面 1 枚が四角形 (三角形 2 枚) で 6 枚。読み飛ばすのは
        /// `mtllib` / `o` / `s` / `usemtl` の 4 行
        case pyramid
        /// 三角形 2 枚。読み飛ばすのは `mtllib` の 1 行 (`vt` / `vn` は読む)
        case unwrapped

        var testDescription: String { "\(self)" }

        var path: String {
            switch self {
            case .pyramid: ModelFixture.pyramid
            case .unwrapped: ModelFixture.unwrapped
            }
        }

        var triangles: Int {
            switch self {
            case .pyramid: 6
            case .unwrapped: 2
            }
        }

        var skippedLines: Int {
            switch self {
            case .pyramid: 4
            case .unwrapped: 1
            }
        }
    }

    @Test("既知のモデルの枚数・名前・読み飛ばした行が、ファイルの中身どおり", arguments: Known.allCases)
    func knownModelsReportTheirContents(_ known: Known) throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        let model = try canvas.loadModel(known.path)
        #expect(model.triangleCount == known.triangles)
        // 名前は読み込んだときに渡した道筋そのもの
        #expect(model.name == known.path)
        #expect(model.skippedLines == known.skippedLines)
    }
}
