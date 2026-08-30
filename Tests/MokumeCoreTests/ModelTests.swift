// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing
import simd

@testable import MokumeCore

/// 外で作ったモデルを読んで置く検査。GPU を要するものと、要らないものがある —
/// **要るほうは入れ子の ``ModelTests/OnCanvas`` にまとめてある**。
///
/// いちばん見たいのは **「読み込んで、そのまま置いた絵が画面に見える」** — 既定同士が
/// 噛み合っていないと、読み込みは成功しているのに絵が出ない。しかも失敗ではないので
/// 利用者は原因に辿り着けない。だから画素で確かめる。
@Suite("読み込んだモデル")
struct ModelTests {
    // MARK: - 読み取り (GPU を要さない)

    @Test("面の向きが無いモデルでも、形から求めた向きが付く")
    func normalsAreDerivedWhenMissing() throws {
        let parsed = try ModelFile.load(ModelFixture.pyramid)
        // 四角錐は側面 4 枚 (三角形 4) + 底 1 枚 (三角形 2) = 6 枚
        #expect(parsed.positions.count == 18)
        #expect(parsed.hasWrittenNormals == false)
        #expect(parsed.normals.allSatisfy { length_squared($0) > 0.9 })
        // 読み飛ばした行 (mtllib / o / s / usemtl) を数えている
        #expect(parsed.skippedLines == 4)
    }

    @Test("面の向きが書いてあれば、それを使う")
    func writtenNormalsAreUsed() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vn 0 0 1
            f 1//1 2//1 3//1
            """)
        #expect(parsed.hasWrittenNormals)
        #expect(parsed.normals.allSatisfy { $0 == SIMD3(0, 0, 1) })
    }

    @Test("番号は 1 から数え、負の番号は末尾から数える")
    func indicesCountFromOneAndFromTheEnd() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            f -3 -2 -1
            """)
        #expect(parsed.positions.count == 3)
        #expect(parsed.positions[0] == SIMD3(0, 0, 0))
        #expect(parsed.positions[2] == SIMD3(0, 1, 0))
    }

    @Test("読めない行があっても、そこまでの形は使える")
    func brokenLinesDoNotStopTheRest() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 nan
            v 1 0 0
            v 0 1 0
            f 1 2 3
            g grouped
            """)
        // 数でない頂点は読まないので、面の番号もその分ずれる (3 点そろえば三角形になる)
        #expect(parsed.positions.count == 3)
        #expect(parsed.skippedLines == 2)
    }

    @Test("書かれた展開 (vt) を読み、読み飛ばした行に数えない")
    func textureCoordinatesAreRead() throws {
        let parsed = ModelFile.parse(ModelFixture.unwrappedText)
        // 板 2 枚 = 三角形 2 枚 = 6 点。読み取り位置は点と同じ数だけ並ぶ
        #expect(parsed.positions.count == 6)
        #expect(parsed.uvs.count == 6)
        #expect(parsed.uvs.allSatisfy { $0 != nil }, "書いた展開が届いていない")
        // 読み飛ばしたのは mtllib の 1 行だけ (vt 4 行は読めている)
        #expect(parsed.skippedLines == 1)
    }

    @Test("読み取り位置の縦は裏返って乗る (OBJ は下から・この面は上から数える)")
    func textureCoordinatesFlipVertically() throws {
        let parsed = ModelFile.parse(ModelFixture.unwrappedText)
        // 1 枚目の 3 点は vt 1・2・3。絵の下寄り (v = 0.8) を書いた角が、上寄り (0.2) に乗る
        #expect(parsed.uvs[0] == SIMD2(0.25, Float(1) - 0.8))
        #expect(parsed.uvs[1] == SIMD2(0.75, Float(1) - 0.8))
        #expect(parsed.uvs[2] == SIMD2(0.75, Float(1) - 0.1))
    }

    @Test("読み取り位置の番号も 1 から数え、負の番号は末尾から数える")
    func textureIndicesCountFromOneAndFromTheEnd() throws {
        let parsed = ModelFile.parse(ModelFixture.unwrappedText)
        // 2 枚目は負の番号で書いてある (-4 / -2 / -1 = vt 1 / 3 / 4)
        #expect(parsed.uvs[3] == parsed.uvs[0])
        #expect(parsed.uvs[4] == parsed.uvs[2])
        #expect(parsed.uvs[5] == SIMD2(0.25, Float(1) - 0.1))
    }

    @Test("真ん中が空の角 (位置//向き) は、読み取り位置を持たない")
    func cornersWithoutTextureIndexAreEmpty() throws {
        let parsed = ModelFile.parse(ModelFixture.mixedUnwrapText)
        // 1 枚目は書いてある・2 枚目は `位置//向き` なので持たない
        #expect(parsed.uvs[0...2].allSatisfy { $0 != nil })
        #expect(parsed.uvs[3...5].allSatisfy { $0 == nil })
        // 向きのほうは 2 枚目も書かれているので、形から求めていない
        #expect(parsed.hasWrittenNormals)
    }

    @Test("vt は u だけでも読め、3 つ目 (w) は無視する")
    func textureLinesToleratePartialAndExtraNumbers() throws {
        let parsed = ModelFile.parse(
            """
            v 0 0 0
            v 1 0 0
            v 0 1 0
            vt 0.5
            vt 0.25 0.5 0.75
            vt 0.75 0.5
            f 1/1 2/2 3/3
            """)
        // v が無ければ 0 と読む (裏返して 1)
        #expect(parsed.uvs[0] == SIMD2(0.5, 1))
        // 3 つ目があっても手前の 2 つは正しい展開なので使う
        #expect(parsed.uvs[1] == SIMD2(0.25, 0.5))
        #expect(parsed.skippedLines == 0)
    }

    // MARK: - 整え方

    /// 面を作らずに整える。**GPU の無いところでも契約を確かめられる**ようにする —
    /// 整え方は描画とは関わりが無いので、面が要る検査にしてしまうと、いちばん確かめ
    /// たい規則が GPU の無い実行から丸ごと落ちる。
    private func normalized(fitting: Float?) throws -> Model {
        Model.make(
            name: "pyramid", parsed: try ModelFile.load(ModelFixture.pyramid),
            fitting: fitting, identity: 1)
    }

    @Test("整えると、中心が原点に来て面に合う大きさになる")
    func normalizingCentersAndFits() throws {
        // 面が 200 x 120 なら、短いほうの半分 = 60
        let model = try normalized(fitting: 60)

        // **頂点そのものから測る。** 報告している大きさだけを見ると、頂点が潰れて
        // いても報告の側が正しければ通ってしまう
        var lowest = SIMD3<Float>(repeating: .infinity)
        var highest = SIMD3<Float>(repeating: -.infinity)
        for point in model.mesh.points {
            lowest = simd_min(lowest, point.position)
            highest = simd_max(highest, point.position)
        }
        let measured = highest - lowest

        // いちばん長い辺が、面の短いほうの半分 (120 / 2 = 60)
        #expect(abs(max(measured.x, max(measured.y, measured.z)) - 60) < 0.001)
        #expect(abs((highest.x + lowest.x) / 2) < 0.001, "中心が原点に来ていない")
        #expect(abs((highest.y + lowest.y) / 2) < 0.001)
        #expect(model.center == .zero)
        #expect(abs(model.size.x - measured.x) < 0.001, "報告した大きさが頂点と食い違う")
        // **軸の比が変わらない。** 元は 2 x 1.6 x 2 なので、縮めても同じ比のまま
        #expect(abs(measured.x / measured.y - 2 / 1.6) < 0.001)
        #expect(abs(measured.x - measured.z) < 0.001)
    }

    @Test("整えないと、ファイルの座標がそのまま残る")
    func withoutNormalizingTheFileIsKept() throws {
        let model = try normalized(fitting: nil)
        // 元の四角錐は幅 2・高さ 1.6・奥行き 2 で、底面が y = 0
        #expect(abs(model.size.x - 2) < 0.001)
        #expect(abs(model.size.y - 1.6) < 0.001)
        #expect(abs(model.center.y - 0.8) < 0.001)
        // 縦軸の読み替えも整える側の仕事なので、ここでは起きていない
        #expect(model.mesh.points.contains { abs($0.position.y - 1.6) < 0.001 })
    }

    @Test("整えると、縦軸がこの面の約束 (下向き) になる")
    func normalizingFlipsTheVerticalAxis() throws {
        let model = try normalized(fitting: 60)
        // モデルの頂点 (いちばん高いところ) は、この面では**いちばん小さい y**
        let lowest = model.mesh.points.map(\.position.y).min() ?? 0
        let highest = model.mesh.points.map(\.position.y).max() ?? 0
        let apex = model.mesh.points.filter { abs($0.position.x) < 0.001 && abs($0.position.z) < 0.001 }
        #expect(!apex.isEmpty, "尖った先が見つからない")
        #expect(apex.allSatisfy { abs($0.position.y - lowest) < 0.001 }, "先が下を向いている")
        #expect(highest > lowest)
    }

    @Test("書かれた展開があれば、それが読み取り位置になる")
    func writtenUnwrapBecomesTheReadingPosition() throws {
        let model = Model.make(
            name: "unwrapped", parsed: try ModelFile.load(ModelFixture.unwrapped),
            fitting: 60, identity: 1)
        // **囲みの箱から作る位置とは重ならない値**を書いてあるので、倒れていれば落ちる
        #expect(model.mesh.points[0].uv == SIMD2(0.25, Float(1) - 0.8))
        #expect(model.mesh.points[2].uv == SIMD2(0.75, Float(1) - 0.1))
    }

    @Test("展開を持たないモデルは、囲みの箱の位置に倒れる")
    func modelsWithoutUnwrapFallBackToTheBoundingBox() throws {
        let model = try normalized(fitting: 60)
        // 四角錐の先 (ファイルで最も高いところ) は、絵の上端 (v = 0) を読む。
        // 底面の 4 点は絵の下端 (v = 1) で、横は囲みの箱の x を 0…1 に写した値
        let apex = model.mesh.points.filter {
            abs($0.position.x) < 0.001 && abs($0.position.z) < 0.001
        }
        #expect(!apex.isEmpty, "尖った先が見つからない")
        #expect(apex.allSatisfy { abs($0.uv.x - 0.5) < 0.001 && abs($0.uv.y) < 0.001 })
        let base = model.mesh.points.filter { $0.uv.y > 0.5 }
        #expect(!base.isEmpty)
        #expect(base.allSatisfy { abs($0.uv.y - 1) < 0.001 })
        #expect(base.allSatisfy { abs($0.uv.x) < 0.001 || abs($0.uv.x - 1) < 0.001 })
    }

    @Test("角ごとに混ざっていても、書かれた角だけが展開に従う")
    func writtenCornersWinPerCorner() throws {
        let model = Model.make(
            name: "mixed", parsed: try ModelFile.load(ModelFixture.mixedUnwrap),
            fitting: 60, identity: 1)
        // 手前の 3 点は書かれた展開
        #expect(model.mesh.points[0].uv == SIMD2(0.25, Float(1) - 0.75))
        #expect(model.mesh.points[1].uv == SIMD2(0.75, Float(1) - 0.75))
        #expect(model.mesh.points[2].uv == SIMD2(0.75, Float(1) - 0.25))
        // 奥の 3 点は囲みの箱 (板は x が -1…1・y が 0…2 なので、角がそのまま四隅に来る)
        #expect(model.mesh.points[3].uv == SIMD2(0, 1))
        #expect(model.mesh.points[4].uv == SIMD2(1, 0))
        #expect(model.mesh.points[5].uv == SIMD2(0, 0))
    }

    @Test("読み取り位置は整え方に依らない")
    func readingPositionsDoNotDependOnNormalizing() throws {
        // **貼る絵の読み取り位置は形の座標ではない**ので、整えても倒れ先も含めて同じ値に
        // なる。整えたあとの座標から測っていた頃は、normalize: false でだけ絵が上下逆に
        // 乗っていた (#406)
        for path in [ModelFixture.pyramid, ModelFixture.unwrapped, ModelFixture.mixedUnwrap] {
            let parsed = try ModelFile.load(path)
            let fitted = Model.make(name: path, parsed: parsed, fitting: 60, identity: 1)
            let raw = Model.make(name: path, parsed: parsed, fitting: nil, identity: 2)
            #expect(
                fitted.mesh.points.map(\.uv) == raw.mesh.points.map(\.uv),
                "整え方で読み取り位置が動いた (\(path))")
        }
    }

    /// 面へ置いてから確かめるもの。**GPU を要する検査はこの入れ子に集める** — 条件を
    /// `@Test` ごとの注記で表すと 1 本ずつ付け忘れられる ([#336](https://github.com/mokume-metal/mokume/pull/336))
    /// ので、置き場所で表す。trait は入れ子へ継承されるので、ここに置いた検査には条件が必ず掛かる
    /// (付け忘れは `GPUGateTests` が原文から見つける)。
    @Suite(
        "面へ置く",
        .enabled(if: RenderDevice.isAvailable, "面を作るので GPU が要る")
    )
    struct OnCanvas {
        private func makeCanvas(width: Int = 96, height: Int = 96) throws -> Canvas {
            let gpu = try RenderDevice()
            let target = try RenderTarget(gpu: gpu, width: width, height: height)
            return try Canvas(target: target, gpu: gpu)
        }

        // MARK: - 読み取り

        @Test("読めたが面が 1 つも無い状態が、読めなかった状態と区別できる")
        func anEmptyModelIsNotAFailure() throws {
            let canvas = try makeCanvas()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let empty = directory.appendingPathComponent("empty.obj")
            try "# 面が 1 つも無い\nv 0 0 0\n".write(to: empty, atomically: true, encoding: .utf8)

            // 読めた (投げない)。ただし面が無いことが読み取れる
            let model = try canvas.loadModel(empty.path)
            #expect(model.isEmpty)
            #expect(model.triangleCount == 0)

            // 読めなかったほうは投げる
            #expect(throws: ModelFailure.self) {
                _ = try canvas.loadModel("assets/missing-model.obj")
            }
        }

        @Test("対応していない形式は、そう分かる形で投げる")
        func unsupportedFormatsSayWhy() throws {
            let canvas = try makeCanvas()
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("mokume-model-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let other = directory.appendingPathComponent("thing.stl")
            try "solid".write(to: other, atomically: true, encoding: .utf8)

            do {
                _ = try canvas.loadModel(other.path)
                Issue.record("対応していない形式を読めてしまった")
            } catch {
                #expect(error == .unsupported(path: other.path, extensionName: "stl"))
            }
        }

        // MARK: - 置いたら見える

        @Test("読み込んで、そのまま置いた絵が画面に見える")
        func aLoadedModelIsVisible() throws {
            // **この 1 点が最重要。** 既定同士が噛み合っていないと、読み込みは成功して
            // いるのに数画素の点になり、しかも失敗ではないので原因に辿り着けない
            let canvas = try makeCanvas(width: 128, height: 128)
            let model = try canvas.loadModel(ModelFixture.pyramid)
            try canvas.draw {
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                canvas.fill(.opaque(red: 0.9, green: 0.7, blue: 0.4))
                canvas.push()
                canvas.translate(64, 64, 0)
                canvas.model(model)
                canvas.pop()
            }
            let image = try canvas.target.encodeForDisplay()
            var lit = 0
            for y in 0..<image.height {
                for x in 0..<image.width where image[x, y].red > 20 { lit += 1 }
            }
            // 面の 1/50 より小さければ「読めているのに見えない」と同じこと
            #expect(lit > image.width * image.height / 50, "置いた絵が小さすぎる (\(lit) 画素)")
        }

        @Test("続けて置いても描く回数は増えない")
        func repeatedModelsCollapseIntoOneCall() throws {
            let canvas = try makeCanvas(width: 128, height: 128)
            let model = try canvas.loadModel(ModelFixture.pyramid)
            try canvas.draw {
                canvas.background(.opaque(red: 0, green: 0, blue: 0))
                canvas.lights()
                canvas.noStroke()
                for index in 0..<8 {
                    canvas.push()
                    canvas.translate(20 + Float(index) * 12, 64, 0)
                    canvas.model(model)
                    canvas.pop()
                }
            }
            #expect(canvas.drawCallsInLastFrame == 1)
        }

        // MARK: - 読み直さない

        @Test("同じ名前・同じ整え方なら読み直さない")
        func theSameFileIsNotReadTwice() throws {
            let canvas = try makeCanvas()
            let first = try canvas.loadModel(ModelFixture.pyramid)
            let second = try canvas.loadModel(ModelFixture.pyramid)
            #expect(first == second, "同じ読み込みが返っていない")

            // 整え方が違えば別のもの
            let raw = try canvas.loadModel(ModelFixture.pyramid, normalize: false)
            #expect(raw != first)
            #expect(canvas.modelCache.count == 2)
        }
    }
}
