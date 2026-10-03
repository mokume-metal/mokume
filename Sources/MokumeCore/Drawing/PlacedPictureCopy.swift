// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

// `@MainActor` を明示する理由は ``RenderDevice`` の冒頭と同じ (release のテストビルドで
// 暗黙の既定隔離が見失われる・#761)。

/// 置いた描き場所の、**置いた時点の絵の写し** ([#1656])。
///
/// 描き場所を置いた後に、同じフレームでその描き場所を描き換えると、置いた場所には置いた時点の
/// 絵が出なければならない (`createGraphics` の説明「描き換えても、置いた時点の絵が出る」)。以前は
/// 描き換わる直前に置いた側を描き切らせていたが、それはフレームの途中の区切りになり、区切りより
/// 前の面が後の立体の影を受けないなど、利用者の呼んでいない区切りで絵が割れた。いまは描き換わる
/// 直前の描き場所の絵をこれへ写し、置いた側の溜めた列が読む面をこれに差し替える (案 A2)。
///
/// 溜めた列は面を ``HeldTexture`` として持つので、持ち主にこれを渡す。持ち主が描き場所 (の
/// ``RenderTarget``) でないので、差し替えた列は描き場所を置いたことにならない (写しは後から
/// 変わらない)。
///
/// [#1656]: https://github.com/mokume-metal/mokume/issues/1656
@MainActor final class PlacedPictureCopy {
    let texture: any MTLTexture
    private let gpu: RenderDevice
    /// 最後に写した境目の番号 (``Canvas`` が数える)。使わなくなった写しを手放すのに読む。
    var lastUsedEpoch = 0

    init(gpu: RenderDevice, like source: any MTLTexture) throws(RenderFailure) {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: source.pixelFormat, width: source.width, height: source.height,
            mipmapped: false)
        descriptor.usage = [.shaderRead]
        descriptor.storageMode = .private
        let texture = try gpu.makeTexture(descriptor: descriptor)
        texture.label = "mokume.placedPictureCopy"
        self.texture = texture
        self.gpu = gpu
    }

    /// `source` と同じ形の面か。
    func fits(_ source: any MTLTexture) -> Bool {
        texture.width == source.width && texture.height == source.height
            && texture.pixelFormat == source.pixelFormat
    }

    /// 溜めた列が読む面として渡す形。
    var held: HeldTexture { HeldTexture(texture: texture, owner: self) }

    /// **常駐から退かせる** ([#795] と同じ)。列がまだ読んでいれば、列が持ち主ごと抱えている
    /// ので、ここは走らない。
    ///
    /// [#795]: https://github.com/mokume-metal/mokume/issues/795
    isolated deinit { gpu.retire(texture) }
}
