// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 断片へ渡せる面。
///
/// 値 (``ShaderValue``) と型を分けてある。**詰め先が違う**からで、値は列ごとの 1 区画へ
/// 詰められるが、面は口へ割り当てるしかない ([#407](https://github.com/mokume-metal/mokume/issues/407))。
/// 1 つの辞書に混ぜると、詰める側 (`ShaderSource.pack`) に「これは詰めない」という
/// 分岐が並ぶことになる。
///
/// 受けるのは**読み込んだ絵と、自分で描いた面の両方**である — 貼る口 (``Canvas/texture(_:)-(Image)``)
/// が両方を受けるのと揃えてある。出どころで型を分けると、面を差し替えるだけのコードが
/// 出どころの数だけ増える。
public enum ShaderSurface {
    /// 読み込んだ (あるいは画素から作った) 絵。
    case image(Image)
    /// 自分で描いた場所。
    case graphics(Canvas)

    /// 内側の受け口へ畳む。**下位の描画資源は面に出さない** ([ADR-0024] 決定 8)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    var picture: Picture {
        switch self {
        case .image(let image): .loaded(image)
        case .graphics(let canvas): .drawn(canvas.output)
        }
    }

    /// いま読める面。**読む直前に整えてから返す** — 書き換えた画素があればここで送られる。
    var texture: any MTLTexture {
        let picture = picture
        picture.prepare()
        return picture.texture
    }
}
