// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 引数なしの `camera()` が何を既定へ戻すかの検査 (#1371)。GPU を要する。
///
/// **戻すのは視点 (見る位置・見ている先・上方向) だけで、投影は残る。** どこから見るかと、
/// どう写すかは別の指定である (`Canvas.apply(replacingProjection:)` の方針)。破れても例外は
/// 出ず、絵が既定の透視へ戻るだけなので、期待値は**投影の式から導いた画面座標**と、
/// **視点を一度も動かさずに同じ投影で撮った絵**の 2 つで見る。
///
/// 面は 64 × 64 で、既定の視点は面の中心 (32, 32) の真正面、距離 32 / tan(π/6) = 32√3 に
/// ある (縦の画角 π/3 で面の高さがちょうど収まる距離)。
@Suite(
    "引数なしの camera() が戻すもの",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct CameraResetTests {
    private let black = LinearRGBA.linear(red: 0, green: 0, blue: 0)
    private let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)

    /// 既定の視点から面までの距離 (32√3)。
    private let distance = 32 * Float(3).squareRoot()

    /// 画面座標の比べ方の許し。**正しい値と、投影が既定の透視へ戻ったときの値は数画素
    /// 離れる**ので、行列を通した丸めだけを許せばよい。
    private let tolerance: Float = 0.01

    private func makeCanvas() throws -> Canvas {
        try CanvasFixture.make(gpu: RenderDevice(), width: 64, height: 64)
    }

    /// 既定から大きく外した視点。**戻ったかどうかが画面座標に出る**ように、横にも
    /// 奥行きにもずらす。
    private func lookFromAside(_ canvas: Canvas) {
        canvas.camera(70, 10, 90, 32, 32, 0, 0, 1, 0)
    }

    /// 点 (8, 50, z) を奥行きだけ変えて画面へ落とす。**横 8 は中心から 24 左、縦 50 は
    /// 中心から 18 下**なので、投影の式に入る量が縦横で違う。
    private func screenPositions(of canvas: Canvas, depths: [Float]) -> [(x: Float, y: Float, z: Float)] {
        depths.map { z in (canvas.screenX(8, 50, z), canvas.screenY(8, 50, z), z) }
    }

    // MARK: - 視点は既定へ戻る

    @Test("投影を変えていなければ、camera() は既定の視点そのものへ戻る")
    func resettingWithoutProjectionChangeRestoresTheDefault() throws {
        let canvas = try makeCanvas()
        var camera: Camera?
        try canvas.draw {
            lookFromAside(canvas)
            canvas.camera()
            camera = canvas.currentCamera
        }

        let reset = try #require(camera)
        #expect(reset == canvas.defaultCamera)
        #expect(abs(reset.eye.x - 32) < tolerance)
        #expect(abs(reset.eye.y - 32) < tolerance)
        #expect(abs(reset.eye.z - distance) < tolerance)
        #expect(reset.center == SIMD3<Float>(32, 32, 0))
        #expect(reset.up == SIMD3<Float>(0, 1, 0))
    }

    // MARK: - 投影は残る

    @Test("平行投影の後に camera() を書いても、平行投影のまま視点だけが既定へ戻る")
    func resettingKeepsTheDefaultOrthographic() throws {
        let canvas = try makeCanvas()
        var camera: Camera?
        var seen: [(x: Float, y: Float, z: Float)] = []
        try canvas.draw {
            canvas.ortho()
            lookFromAside(canvas)
            canvas.camera()
            camera = canvas.currentCamera
            // 既定の手前と奥の面 (距離の 1/10 と 10 倍) の間に収まる奥行き
            seen = screenPositions(of: canvas, depths: [40, 0, -300])
        }

        let reset = try #require(camera)
        #expect(abs(reset.eye.z - distance) < tolerance)
        #expect(reset.center == SIMD3<Float>(32, 32, 0))
        // 既定の平行投影の範囲は、既定の視点を中心に面 1 枚ぶん (64 × 64)。だから
        // **奥行きによらず、空間の座標がそのまま画面の座標になる**
        for (x, y, z) in seen {
            #expect(abs(x - 8) < tolerance, "奥行き \(z) の点の横")
            #expect(abs(y - 50) < tolerance, "奥行き \(z) の点の縦")
        }
    }

    @Test("範囲を決めた平行投影も、camera() の後にそのまま残る")
    func resettingKeepsACustomOrthographic() throws {
        let canvas = try makeCanvas()
        var camera: Camera?
        var seen: [(x: Float, y: Float, z: Float)] = []
        try canvas.draw {
            // 面 1 枚半ぶん (96 × 96) を写す
            canvas.ortho(-48, 48, 48, -48, 5, 600)
            lookFromAside(canvas)
            canvas.camera()
            camera = canvas.currentCamera
            seen = screenPositions(of: canvas, depths: [0, -200])
        }

        let reset = try #require(camera)
        #expect(
            reset.projection
                == .orthographic(left: -48, right: 48, bottom: 48, top: -48, near: 5, far: 600))
        // 96 の範囲を 64 画素へ写すので、中心からのずれは 2/3 倍になる
        // (横: 32 − 24 × 2/3 = 16 / 縦: 32 + 18 × 2/3 = 44)。奥行きには依らない
        for (x, y, z) in seen {
            #expect(abs(x - 16) < tolerance, "奥行き \(z) の点の横")
            #expect(abs(y - 44) < tolerance, "奥行き \(z) の点の縦")
        }
    }

    @Test("画角を変えた透視投影も、camera() の後にそのまま残る")
    func resettingKeepsACustomPerspective() throws {
        let canvas = try makeCanvas()
        var camera: Camera?
        var seen: [(x: Float, y: Float, z: Float)] = []
        try canvas.draw {
            // 縦の画角を π/2 に広げる (tan(π/4) = 1 なので式が簡単になる)
            canvas.perspective(Float.pi / 2, 1, 5, 800)
            lookFromAside(canvas)
            canvas.camera()
            camera = canvas.currentCamera
            seen = screenPositions(of: canvas, depths: [0, -100])
        }

        let reset = try #require(camera)
        #expect(reset.projection == .perspective(fieldOfView: .pi / 2, aspect: 1, near: 5, far: 800))
        // 視点から奥行き方向の距離 (32√3 − z) で割って、面の半分 (32 画素) を掛ける。
        // 既定の画角 (π/3) へ戻っていれば、奥行き 0 の点は座標どおり (8, 50) に出る
        for (x, y, z) in seen {
            let depth = distance - z
            #expect(abs(x - (32 + 32 * (8 - 32) / depth)) < tolerance, "奥行き \(z) の点の横")
            #expect(abs(y - (32 + 32 * (50 - 32) / depth)) < tolerance, "奥行き \(z) の点の縦")
        }
    }

    // MARK: - 絵で見る

    /// 奥行きだけを変えた同じ大きさの立方体を 3 つ置いた絵。**投影が違えば大きさが変わり、
    /// 視点が違えば位置が変わる**ので、どちらが食い違ってもバイト列が変わる。
    private func picture(_ setUp: (Canvas) -> Void) throws -> [UInt8] {
        let canvas = try makeCanvas()
        try canvas.draw {
            canvas.background(black)
            canvas.lights()
            setUp(canvas)
            canvas.noStroke()
            canvas.fill(white)
            for (x, z) in [(Float(14), Float(30)), (32, 0), (50, -120)] {
                canvas.push()
                canvas.translate(x, 32, z)
                canvas.rotateY(0.6)
                canvas.rotateX(0.35)
                canvas.box(12)
                canvas.pop()
            }
        }
        return try canvas.target.encodeForDisplay().bytes
    }

    @Test(
        "camera() で戻した絵は、視点を一度も動かさずに同じ投影で撮った絵と一致する",
        arguments: ["ortho", "perspective"])
    func resetPictureMatchesTheUntouchedEye(projection: String) throws {
        func project(_ canvas: Canvas) {
            if projection == "ortho" {
                canvas.ortho(-40, 40, 40, -40, 5, 600)
            } else {
                canvas.perspective(Float.pi / 2, 1, 5, 800)
            }
        }

        let reset = try picture { canvas in
            project(canvas)
            lookFromAside(canvas)
            canvas.camera()
        }
        let untouched = try picture { canvas in project(canvas) }

        #expect(reset == untouched)
        // 対照: 既定の透視のまま撮った絵とは一致しない (場面が投影の違いを写せていること)
        #expect(try reset != picture { _ in })
    }
}
