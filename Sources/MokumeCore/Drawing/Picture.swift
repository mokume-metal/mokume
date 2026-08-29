// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 読める絵。**読み込んだ絵と、自分で描いた場所を 1 つの値で受ける。**
///
/// 「効果に渡せる絵」と「自分で描ける絵」を別の型にしない ([ADR-0023] 決定 1) のと
/// 同じ理由で、**貼る側・置く側が受ける口も 1 つ**にしておく。出どころごとに口を
/// 分けると、絵を差し替えるだけのコードが出どころの数だけ増える。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
enum Picture {
    /// 読み込んだ (あるいは画素から作った) 絵。
    case loaded(Image)
    /// 自分で描いた場所。
    case drawn(RenderTarget)

    var width: Int {
        switch self {
        case .loaded(let image): image.width
        case .drawn(let target): target.width
        }
    }

    var height: Int {
        switch self {
        case .loaded(let image): image.height
        case .drawn(let target): target.height
        }
    }

    var texture: any MTLTexture {
        switch self {
        case .loaded(let image): image.texture
        case .drawn(let target): target.texture
        }
    }

    /// 読む直前に整える。**書き換えた画素があればここで送られる**ので、送り直しを
    /// 呼び忘れて絵が変わらない、が起きない。描いた場所は描き切りが済んでいる。
    func prepare() {
        if case .loaded(let image) = self { image.uploadIfNeeded() }
    }
}
