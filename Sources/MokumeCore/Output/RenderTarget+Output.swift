// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Metal

extension RenderTarget {

    // MARK: - 面に描かずに取り出す

    /// 出力段を通した絵を、**面に描かずに** 1 枚のテクスチャとして取り出す。
    ///
    /// [ADR-0024] 決定 6 の言う「取り出す道」である。画面へ差し出す経路は面の大きさへ
    /// 収めて帯を足すので、そこからは「絵そのもの」を取り出せない。毎フレーム絵を
    /// 受け取る出口はここから受け取る。
    ///
    /// **頼まれるまで 1 パスも積まない。** 出口が 1 つも無いスケッチは、この経路の
    /// 存在を一切払わない。
    ///
    /// 返るのは**使い回している 1 枚**なので、次に取り出すと中身が書き換わる
    /// ([ADR-0023] 決定 5)。持ち帰って後で読む用途には ``EncodedImage/read()`` で
    /// 値にしてから渡す。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    func encodeToImage() throws(RenderFailure) -> EncodedImage {
        let image: EncodedImage
        if let encodedStorage {
            image = encodedStorage
        } else {
            image = try EncodedImage(gpu: gpu, width: width, height: height)
            encodedStorage = image
            encodedImagesMade += 1
        }

        let pass: OutputPass
        if let outputPassStorage {
            pass = outputPassStorage
        } else {
            pass = try OutputPass(gpu: gpu)
            outputPassStorage = pass
        }

        pass.setSource(texture)
        // 明るさを写す段は**描画先が持つ**。画面へ差し出す経路と同じ設定が効く
        pass.setBrightness(brightness)

        let commands = try gpu.beginCommands()
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: image.makeRenderPass())
        else {
            throw .encoderUnavailable
        }
        // **描き終えた絵を読むので、前の書き込みが終わるのを待つ。** この世代の
        // コマンド構造は口をまたぐ依存を自動では張らない ([#341])
        //
        // [#341]: https://github.com/mokume-metal/mokume/issues/341
        encoder.barrier(
            afterQueueStages: .fragment, beforeStages: .fragment, visibilityOptions: .device)
        encoder.setRenderPipelineState(pass.state)
        encoder.setViewport(
            MTLViewport(
                originX: 0, originY: 0, width: Double(width), height: Double(height),
                znear: 0, zfar: 1))
        encoder.setArgumentTable(pass.argumentTable, stages: [.vertex, .fragment])
        encoder.drawPrimitives(primitiveType: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        // **読み戻せる状態まで待つ。** 呼び出し側へ制御が戻った時点で中身が確定して
        // いなければ、取り出した絵はひとつ前のフレームのものになりうる
        try gpu.commitAndWait(commands)
        return image
    }

    // MARK: - 読み戻す

    /// いまの内容を表示できる形へ変換して返す。
    ///
    /// `scale` を 1 より小さくすると、**出力段を通す前に**間引く — 変換は捨てない画素にしか
    /// 掛からないので、費用が指定した画素数に比例する。出力段は画素ごとの純関数で
    /// `PixelBuffer.scaled(by:)` は成分をそのまま拾うため、順序を入れ替えても出るバイト列は
    /// 変わらない (#382)。
    ///
    /// - Parameter scale: 縮小率 (1 = 実寸)。1 以上または 0 以下は実寸として扱う。
    public func encodeForDisplay(scale: Double = 1) throws(RenderFailure) -> DisplayImage {
        OutputStage.encode(try readPixels().scaled(by: scale), brightness: brightness)
    }

    /// いまの内容を PNG として書き出す。**書き込みが終わってから返る。**
    ///
    /// 出力段を 1 度だけ通す ([ADR-0011] 決定 3)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    public func writePNG(to url: URL) throws {
        try PNGFile.write(try encodeForDisplay(), to: url)
    }
}
