// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 効果の段が読み書きできる絵。
///
/// 段が要るのは「面・大きさ・書き込むパスの記述」の 3 つだけである。描画先
/// (``RenderTarget``) も中間の絵 (``StageImage``) もこれに従うので、段のコードは
/// どちらへ書いているかを知らない。
protocol EffectSurface: AnyObject {
    var texture: any MTLTexture { get }
    var width: Int { get }
    var height: Int { get }
}

extension EffectSurface {
    /// 効果の段が書き込むパスの記述を作る。
    ///
    /// **奥行きを持たない。** 段は絵から絵への変換で、前後関係を持たないためである。
    /// 奥行きを付けたパスへ、奥行きを見ないパイプラインを通すことはできない。
    func makeEffectPass() -> MTL4RenderPassDescriptor {
        let pass = MTL4RenderPassDescriptor()
        let attachment = pass.colorAttachments[0]!
        attachment.texture = texture
        // 画面いっぱいの三角形が全部の画素を書くので、前の内容は読まない
        attachment.loadAction = .dontCare
        attachment.storeAction = .store
        return pass
    }
}

/// 段の途中の絵 — 効果の控えと、時間方向の拡大が持つ前のフレーム。
///
/// **色だけを持つ。** 描画先 (``RenderTarget``) は立体を置くために奥行きの面を伴うが、
/// 段は絵から絵への変換で奥行きを見ないので、ここに同じ面を付けると使われないまま
/// 1 枚ぶんの確保が乗る ([#753])。``RenderTarget`` に「奥行きを持たない」形を足す
/// 案は採らない — 確保の有無で描き方が 2 通りに分かれることを [ADR-0021] 決定 2・3 が
/// 退けているためで、別の型にすれば描画先の不変条件はそのまま残る。
///
/// 画素を CPU から読む口は無い。段の途中の絵を読む出口は存在しないので、写しも持たない。
///
/// [#753]: https://github.com/mokume-metal/mokume/issues/753
/// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
final class StageImage: EffectSurface {
    let width: Int
    let height: Int
    /// GPU 専用の面。描画先と同じ形式で、段が読み書きする。
    let texture: any MTLTexture

    /// - Parameter startingTransparent: 作った時点で透明な黒に塗るか。GPU 専用の面の
    ///   初期値は未定義なので、**書かれる前に読まれる面**は塗っておく (時間方向の拡大の
    ///   控えは最初のフレームから読まれる)。効果の控えは全画素を書く段しか通らないうえ、
    ///   コマンドを組み立てている最中に作られるので塗れない
    ///   (``RenderDevice/makeClearedTexture(descriptor:)``)。
    init(gpu: RenderDevice, width: Int, height: Int, startingTransparent: Bool)
        throws(RenderFailure)
    {
        self.width = width
        self.height = height
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: RenderTarget.pixelFormat, width: width, height: height,
            mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let texture =
            startingTransparent
            ? try gpu.makeClearedTexture(descriptor: descriptor)
            : try gpu.makeTexture(descriptor: descriptor)
        texture.label = "mokume.stage"
        self.texture = texture
    }
}
