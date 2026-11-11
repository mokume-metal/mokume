// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 別の絵の明るさを、この絵の不透明度に掛ける `mask` ([#3713])。
//
// [#3713]: https://github.com/mokume-metal/mokume/issues/3713
extension Image {
    /// 別の絵 (`mask`) の明るさを、この絵の不透明度に掛ける。Processing の `PImage.mask(img)` に当たる。
    /// **この絵を書き換え、`mask` は変えない。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var photo: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         // 横に赤、縦に青が増える不透明な絵
    ///         photo = try createImage(160, 120)
    ///         for y in 0..<120 {
    ///             for x in 0..<160 {
    ///                 photo.set(x, y, .display(red: Float(x) / 159, green: 0.35, blue: Float(y) / 119))
    ///             }
    ///         }
    ///         // 黒地に、中心ほど明るい丸のマスク
    ///         let spot = try createImage(160, 120)
    ///         for y in 0..<120 {
    ///             for x in 0..<160 {
    ///                 let distance = ((Float(x) - 80) * (Float(x) - 80) + (Float(y) - 60) * (Float(y) - 60)).squareRoot()
    ///                 let level = max(0, 1 - distance / 55)
    ///                 spot.set(x, y, .display(red: level, green: level, blue: level))
    ///             }
    ///         }
    ///         photo.mask(spot)  // 丸の外は透け、中心ほど元の色が残る
    ///     }
    ///
    ///     func draw() {
    ///         background(240)
    ///         image(photo, 120, 90)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 明るい灰色の地の中央に、赤から青への色が中心ほど濃く、縁へ向かって地へ溶けていく丸 -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// ## 明るさの読み方
    ///
    /// 掛けるのは、`mask` の同じ位置の画素の ``brightness(_:)`` を 100 で割った値 (0〜1) である。物差しは
    /// ``brightness(_:)`` と ``Effect/threshold(level:)`` と同じ表示の色で、**線形の成分ではない** — 表示で中間の
    /// 灰色 (`brightness` が 50、線形の成分では約 0.214) は不透明度を半分にする。白 (100) は何も変えず、黒 (0) は
    /// 完全に透明にする。表示できる範囲を超えて明るい画素は 1 として扱う。
    ///
    /// Processing は灰色の絵を前提にして青のチャンネルを読む。灰色なら 3 つのチャンネルは同じなので、結果も同じ
    /// になる。**灰色でない絵を渡すと、表示の色の 3 つの成分のうち最も大きいもの**を読む (`brightness` の定義)。
    /// 赤一色の画素は青が 0 でも 1 として読む。マスクの不透明度は読まない (透けたマスクの画素は、乗算を戻した色の
    /// 明るさで読む。不透明度が 0 の画素は 0)。
    ///
    /// ## 掛ける (置き換えない)
    ///
    /// 画素の色はそのままに、不透明度だけに明るさを掛ける。**不透明な絵 (写真など) では、不透明度を置き換える
    /// Processing と同じ結果になる。** 半透明の画素では結果が違う — 不透明度 0.5 の画素に白のマスクを掛けても 0.5 の
    /// ままで (Processing は 1 にする)、灰色 (50) を掛けると 0.25 になる。画素は乗算済み ([ADR-0011]) で持つので、
    /// 置き換えを再現できないのは不透明度が 0 の画素だけである (色が残っていない)。
    ///
    /// ## 大きさが違うとき
    ///
    /// `mask` の大きさがこの絵と違えば、**何も変えず、理由を 1 度だけ警告する** (``write(_:)-(DisplayImage)`` と同じ)。
    /// 大きさを揃えるなら ``resized(width:height:)`` か ``cropped(x:y:width:height:)`` を通す。
    ///
    /// 書き換えは ``set(_:_:_:)`` と同じく、描くときに自動で送られる。カメラの `image` に掛けたときは、次の 1 枚が
    /// 届いて上書きされるまで効く。
    ///
    /// Processing の整数の配列を渡す `mask(maskArray)` は無い。
    ///
    /// - Parameter mask: 明るさを不透明度に使う絵。この絵と同じ大きさ。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    // shot: 後で撮る
    public func mask(_ mask: Image) {
        guard mask.width == width, mask.height == height else {
            warnMaskMismatchOnce(width: mask.width, height: mask.height)
            return
        }
        // 先にマスクの値を写す。自分自身をマスクに渡されても、書き換える前の明るさで読む
        let levels = mask.workingPixels.map { texel in
            Self.maskLevel(
                LinearRGBA(
                    premultipliedRed: Float(texel.x), green: Float(texel.y), blue: Float(texel.z),
                    alpha: Float(texel.w)))
        }
        let columns = width
        transformPixels { x, y, color in
            let level = levels[y * columns + x]
            return LinearRGBA(
                premultipliedRed: color.red * level, green: color.green * level, blue: color.blue * level,
                alpha: color.alpha * level)
        }
    }

    /// マスクの 1 画素を、掛ける値 (0〜1) にする。``brightness(_:)`` の物差しで読み、範囲の外は端へ寄せる。
    nonisolated static func maskLevel(_ color: LinearRGBA) -> Float {
        let level = brightness(color) / 100
        guard level.isFinite else { return 0 }
        return min(max(level, 0), 1)
    }

    /// 大きさの違うマスクを渡されたことを、**最初の 1 度だけ**知らせる。
    private func warnMaskMismatchOnce(width passedWidth: Int, height passedHeight: Int) {
        guard !warnedMaskMismatch else { return }
        warnedMaskMismatch = true
        Diagnostics.warn(
            "mask(): the mask passed is \(passedWidth)x\(passedHeight), which differs from this image's "
                + "\(width)x\(height), so nothing was changed. Make them the same size first "
                + "(resized(width:height:) or cropped(x:y:width:height:))")
    }
}
