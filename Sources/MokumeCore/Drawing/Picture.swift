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
    /// 自分で描いた場所。**`width` / `height` は座標の大きさ**で、`target` の画素数とは限らない
    /// (書き出しの倍率 `mokume render --scale` の下では、描き場所は倍率の画素で刻まれる・[#3453])。
    ///
    /// [#3453]: https://github.com/mokume-metal/mokume/issues/3453
    case drawn(RenderTarget, width: Int, height: Int)

    /// 絵の大きさ。**置く大きさ・切り出し・読み取り位置の割り算は、すべてこの座標の大きさで読む。**
    /// 読み込んだ絵では画素数、描き場所では座標の大きさ (倍率 1 では画素数と同じ)。
    var width: Int {
        switch self {
        case .loaded(let image): image.width
        case .drawn(_, let width, _): width
        }
    }

    var height: Int {
        switch self {
        case .loaded(let image): image.height
        case .drawn(_, _, let height): height
        }
    }

    var texture: any MTLTexture {
        switch self {
        case .loaded(let image): image.texture
        case .drawn(let target, _, _): target.texture
        }
    }

    /// 面を、持ち主と組にして渡す。**溜める側へ渡すときはこちら** (``HeldTexture``)。
    var held: HeldTexture {
        switch self {
        case .loaded(let image): HeldTexture(texture: image.texture, owner: image)
        case .drawn(let target, _, _): HeldTexture(texture: target.texture, owner: target)
        }
    }

    /// 読む直前に整える。**書き換えた画素があれば、ここで送りを頼む** (届けるのは
    /// 描き切り・#749) ので、送り直しを呼び忘れて絵が変わらない、が起きない。描いた場所は
    /// ここでは整えない — 置いた時点で、置く口の記録 (``Canvas/note(placing:)``) が出す先を描き
    /// 切れている絵へ追い付かせる (細かさを下げた面の出す先は描き切りだけでは追い付かない・[#2042])。
    ///
    /// その場で置く経路はここを直に呼ぶ。保持した形を置き直す経路は、記録した面から
    /// ``HeldTexture/prepare()`` を通ってここへ来る ([#1253])。
    ///
    /// [#1253]: https://github.com/mokume-metal/mokume/issues/1253
    /// [#2042]: https://github.com/mokume-metal/mokume/issues/2042
    func prepare() {
        if case .loaded(let image) = self { image.requestUpload() }
    }
}
