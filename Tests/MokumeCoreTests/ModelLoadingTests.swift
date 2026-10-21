// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import Testing
import simd

@testable import MokumeCore

/// 面の口 ``Canvas/loadModel(_:normalize:)`` で読んだモデル ([#1385] 条件 11)。
///
/// 整え方の規則は ``ModelTests`` が ``Model/make(name:parsed:fitting:)`` を直に
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
        #expect(abs(simd_reduce_max(model.size.simd) - 60) < 1e-3)
    }

    @Test("整えずに読むと、ファイルの大きさのまま")
    func loadingWithoutNormalizingKeepsTheFileSize() throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        let model = try canvas.loadModel(ModelFixture.pyramid, normalize: false)
        // 元の四角錐は幅 2・高さ 1.6・奥行き 2
        #expect(simd_length(model.size.simd - SIMD3(2, 1.6, 2)) < 1e-3)
    }

    /// 既知のモデルと、その中身から数えた値。**どちらも注釈の行 (`#`) は数えない。**
    enum Known: CaseIterable, CustomTestStringConvertible {
        /// 側面 4 枚が三角形・底面 1 枚が四角形 (三角形 2 枚) で 6 枚。読み飛ばすのは
        /// `mtllib` / `o` / `s` / `usemtl` の 4 行
        case pyramid
        /// 三角形 2 枚。読み飛ばすのは `mtllib` の 1 行 (`vt` / `vn` は読む)
        case unwrapped
        /// 四角錐を STL で書いたもの (#1966)。三角形 6 枚で、読み飛ばすものは無い
        case pyramidSTL

        var testDescription: String { "\(self)" }

        var path: String {
            switch self {
            case .pyramid: ModelFixture.pyramid
            case .unwrapped: ModelFixture.unwrapped
            case .pyramidSTL: ModelFixture.pyramidSTL
            }
        }

        var triangles: Int {
            switch self {
            case .pyramid: 6
            case .unwrapped: 2
            case .pyramidSTL: 6
            }
        }

        var skippedLines: Int {
            switch self {
            case .pyramid: 4
            case .unwrapped: 1
            case .pyramidSTL: 0
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

    // MARK: - 壊れた行は、読み込んだときに 1 度だけ知らせる (#2565)

    /// 面から読んだとき、そのファイルについて言った知らせ (言っていなければ `nil`)。
    private func notice(_ canvas: Canvas, _ path: String) -> String? {
        canvas.warnings.message(for: .modelSkipped(path: path))
    }

    @Test("意図して読まない行だけの OBJ は、知らせず、skippedLines は今までどおり数える (#2565)")
    func intendedSkipsDoNotWarn() throws {
        let path = ModelFixture.writtenUniquely(
            Data(ModelFixture.barePyramid(extra: ["mtllib a.mtl", "usemtl m", "o x", "g y", "s 1"]).utf8),
            extension: "obj")
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        let model = try canvas.loadModel(path)
        #expect(model.skippedLines == 5)
        #expect(notice(canvas, path) == nil)
        // 書き出した四角錐 (材質などを含む) も鳴らない
        let pyramid = try canvas.loadModel(ModelFixture.pyramid)
        #expect(pyramid.skippedLines == 4)
        #expect(notice(canvas, ModelFixture.pyramid) == nil)
    }

    @Test("壊れた行があれば、パスと何を・何行目かを名乗る知らせが 1 度だけ出る (loadModel・requestModel とも) (#2565)")
    func brokenLinesWarnOncePerFile() async throws {
        let path = ModelFixture.writtenUniquely(
            Data(
                ModelFixture.barePyramid(extra: [
                    "mtllib a.mtl", "v 0x10 0 0", "f 1 2 99", "vv 1 2 3", "vv 4 5 6",
                ]).utf8),
            extension: "obj")
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        let model = try canvas.loadModel(path)
        // 壊れた 4 行 (v・f・vv 2 行) に、読み飛ばした mtllib を足した数。**値は今までの数え方のまま**。
        // 読めない v を指す面はなく、`f 1 2 99` は範囲の外
        #expect(model.skippedLines == 5)
        let first = try #require(notice(canvas, path))
        #expect(first.contains(path))
        #expect(first.contains("\"v\" line that could not be read (line 12)"))
        #expect(first.contains("(line 13)"))
        #expect(first.contains("(2 times, first at line 14)"))
        #expect(!first.contains("mtllib a.mtl"))

        // 控えから返っても、同じ名前を別の整え方で読み直しても、2 度目は出ない (言った文面のまま)
        _ = try canvas.loadModel(path)
        _ = try canvas.loadModel(path, normalize: false)
        _ = try await canvas.requestModel(path)
        #expect(notice(canvas, path) == first)

        // 待たない読み方で初めて読んだ面でも、同じ知らせが出る
        let other = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        _ = try await other.requestModel(path)
        #expect(notice(other, path) == first)
    }

    @Test("バイナリの STL の座標が数でない面は、読み飛ばした面として知らせる (#2565)")
    func skippedSTLFacesWarn() throws {
        var facets = [
            ModelFixture.Facet(
                normal: SIMD3(0, 0, 1), corners: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]),
            ModelFixture.Facet(
                normal: SIMD3(0, 0, 1), corners: [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0)]),
        ]
        let clean = ModelFixture.writtenUniquely(ModelFixture.binarySTL(facets), extension: "stl")
        facets[1].corners[2] = SIMD3(0, .nan, 1)
        let broken = ModelFixture.writtenUniquely(ModelFixture.binarySTL(facets), extension: "stl")
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)

        #expect(try canvas.loadModel(clean).skippedLines == 0)
        #expect(notice(canvas, clean) == nil)
        let model = try canvas.loadModel(broken)
        #expect(model.skippedLines == 1)
        let said = try #require(notice(canvas, broken))
        #expect(said.contains(broken))
        #expect(said.contains("a face or element that could not be read"))
    }

    /// 待たない読み方は、解釈を別の仕事として回す。**STL を読む Model I/O もそこで走る**ので、
    /// 待つ読み方と同じものが届くことを見る。
    @Test("待たない読み方でも、STL を待つ読み方と同じに読む")
    func requestingAnSTLMatchesLoadingIt() async throws {
        let waited = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
            .loadModel(ModelFixture.pyramidSTL)
        // 控え (同じ名前は読み直さない) に当たらないよう、別の面で読む
        let requested = try await CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
            .requestModel(ModelFixture.pyramidSTL)
        #expect(requested.triangleCount == 6)
        #expect(requested.mesh.points.map(\.position) == waited.mesh.points.map(\.position))
        #expect(requested.mesh.points.map(\.normal) == waited.mesh.points.map(\.normal))
    }

    // MARK: - 待たない読み方は、整えるところまで main の外で済ませる (#2801)

    /// 待つ読み方と待たない読み方を比べる検体。**形式と展開の書き方が違うものを並べる** —
    /// OBJ の `vt`・`vn` の有無と、混ざったもの、STL、面の無いもの。
    enum Prepared: CaseIterable, CustomTestStringConvertible {
        case pyramid, unwrapped, mixedUnwrap, ridge, pyramidSTL, empty

        var testDescription: String { "\(self)" }

        var path: String {
            switch self {
            case .pyramid: ModelFixture.pyramid
            case .unwrapped: ModelFixture.unwrapped
            case .mixedUnwrap: ModelFixture.mixedUnwrap
            case .ridge: ModelFixture.ridge
            case .pyramidSTL: ModelFixture.pyramidSTL
            case .empty: ModelFixture.empty
            }
        }
    }

    /// 待たない読み方の整えは別の仕事で走るので、**同じ計算を同じ値で回していること**を
    /// 待つ読み方と突き合わせて見る。整える長さを面から採り損ねる (別の仕事へ渡し損ねる)
    /// と、大きさと中心がずれる。鏡映 (`normalize: true`) の巻き方の戻しは三角形の順に出る。
    @Test(
        "待たない読み方も、待つ読み方と同じ形・大きさ・読み飛ばしを返す",
        arguments: Prepared.allCases, [true, false])
    func requestingMatchesLoading(_ prepared: Prepared, normalize: Bool) async throws {
        let path = prepared.path
        // 控え (同じ名前は読み直さない) に当たらないよう、同じ大きさの別の面で読む
        let waited = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
            .loadModel(path, normalize: normalize)
        let requested = try await CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
            .requestModel(path, normalize: normalize)
        #expect(requested.mesh.points == waited.mesh.points)
        #expect(requested.size == waited.size)
        #expect(requested.center == waited.center)
        #expect(requested.skippedLines == waited.skippedLines)
        #expect(requested.name == waited.name)
        // 別々に読んだものは別のもの (#1846)
        #expect(requested != waited)
    }

    /// **main を塞いだまま、整え終わるのを待つ。** 整えが main に載っていれば、塞いでいる
    /// 間は走れないので期限まで待って落ちる。時間の長さではなく「main 無しで終わるか」を
    /// 見るので、機械の速さにも検体の大きさにもよらない。
    @Test("待たない読み方は、main を塞いでいても整え終わる")
    func requestingPreparesOffTheMainActor() async throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        let prepared = Mutex<Model?>(nil)
        let request = Task {
            try await canvas.requestModel(ModelFixture.pyramid, normalize: true) { model in
                prepared.withLock { $0 = model }
            }
        }
        // 読み込みを別の仕事へ渡すところまで進める (main の仕事は順に回る)
        await Task.yield()
        let settled = pollUntilSettled(within: 30) { prepared.withLock { $0 != nil } }
        #expect(settled, "main を塞いでいる間に整え終わらなかった — 整えが main に載っている")
        let model = try await request.value
        #expect(prepared.withLock { $0 } == model)
    }

    /// 控えに当たったら、読み込みも整えも起こさない (いまの約束を保つ)。
    @Test("待たない読み方は、控えに当たれば整え直さない")
    func requestingFromTheCacheDoesNotPrepareAgain() async throws {
        let canvas = try CanvasFixture.make(gpu: RenderDevice(), width: 200, height: 120)
        let first = try await canvas.requestModel(ModelFixture.ridge)
        let preparedAgain = Mutex(false)
        let second = try await canvas.requestModel(ModelFixture.ridge, normalize: true) { _ in
            preparedAgain.withLock { $0 = true }
        }
        #expect(second == first)
        #expect(!preparedAgain.withLock { $0 })
    }
}
