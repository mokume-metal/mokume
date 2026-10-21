// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

/// 画素の面 — 描画先の写しへの窓。
///
/// 読むときに写しは作られず、書き換えは次に GPU が描画先へ触る前に自動で戻される
/// (送り直しの手順は無い)。使い方と、そう作った理由は ``SketchPart/pixels`` にある。
///
/// ## 行の間隔
///
/// 位置から場所を求めるのに `bytesPerRow` を使う。いまは幅ぶんそのままだが、
/// 置き場の都合で広くなりうる値なので `y * width + x` では届かない形にしてある。
///
public struct Pixels {
    /// 横の画素数。
    public let width: Int
    /// 縦の画素数。
    public let height: Int

    let base: UnsafeMutableRawPointer
    /// 1 行あたりのバイト数。
    let bytesPerRow: Int
    /// 書いたことを知らせる先。**書く口はすべてここへ知らせる** (``PixelMirror/noteCPUWrite()``) —
    /// 知らせ忘れると、書いた画素が描画先へ戻らず、止まっている間は窓にも出口にも出ない。
    let mirror: PixelMirror?
    /// 書いてよいかを尋ねる先。**書く口はすべて、書く前にここを通る** ([#1672])。
    ///
    /// 答えるのは窓を渡した面 (``Canvas/pixels``) で、だめなら面がそのわけを 1 度言う。窓は
    /// プロパティに取っておけるので、取った時点ではなく書く時点で尋ねる。`nil` なら尋ねない
    /// (面を通さずに取った窓)。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    let admitsWrite: (() -> Bool)?
    /// この窓が ``Image`` の画素への窓のとき、その絵 (``Image/pixels``)。
    ///
    /// 絵の画素は GPU と共有する写しではなく `Image` が持つ並びなので、読み書きは絵の口
    /// (`get`・`set`・`fill`・`transformPixels`) へ渡す。`base` は使わない。
    let image: Image?

    init(
        base: UnsafeMutableRawPointer, width: Int, height: Int, bytesPerRow: Int,
        mirror: PixelMirror?, admitsWrite: (() -> Bool)? = nil
    ) {
        self.base = base
        self.width = width
        self.height = height
        self.bytesPerRow = bytesPerRow
        self.mirror = mirror
        self.admitsWrite = admitsWrite
        self.image = nil
    }

    /// 絵の画素への窓。書く前に尋ねる先は無い (絵は置いてよい区間を持たない)。
    init(image: Image) {
        self.base = Self.unavailableBase
        self.width = image.width
        self.height = image.height
        self.bytesPerRow = 0
        self.mirror = nil
        self.admitsWrite = nil
        self.image = image
    }

    /// 書く前に `admits` へ尋ねる窓。中身は同じ写しを指す。
    func asking(_ admits: @escaping () -> Bool) -> Pixels {
        Pixels(
            base: base, width: width, height: height, bytesPerRow: bytesPerRow, mirror: mirror,
            admitsWrite: admits)
    }

    /// 大きさ 0 の窓。写しを用意できなかったときに返す — 読むと透明、書いても何も起きない。
    static let unavailable = Pixels(
        base: unavailableBase, width: 0, height: 0, bytesPerRow: 0, mirror: nil)
    /// 大きさ 0 の窓が指す先。大きさが 0 なので触られることはない。
    private static let unavailableBase = UnsafeMutableRawPointer.allocate(
        byteCount: 8, alignment: 8)

    /// 画素の総数。
    public var count: Int { width * height }

    /// 指定した位置の色。原点は左上。
    ///
    /// **読む値も書く値も、線形・アルファ乗算済みの ``LinearRGBA`` である** ([ADR-0011] 決定 4)。
    /// 変換が挟まらないので、読んだ値をそのまま書き戻しても、塗りの色 (`fill(_:)`) へ
    /// 渡しても色は沈まない。0–255 の乗算していない数で読むときは ``red(_:)`` ほかを通す。
    ///
    /// 範囲の外を読むと透明が返り、範囲の外へ書くと何も起きない
    /// (**読み取りは決して落ちない** — [ADR-0020] 決定 5)。書けるのは、置いてよい区間
    /// (フレームの中と、本体の `setup()`・止まっている間のコールバック) だけで、外で書くと
    /// 1 度注意して何もしない (``fill(_:)`` も同じ)。
    ///
    /// 書く色は検めずに面へ移す。数でない成分・無限の成分もそのまま書き (図形を描く経路が面へ
    /// 移すときと同じ)、有限の成分は面が表せる ±65504 で止まる (``fill(_:)`` も同じ)。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
    public subscript(x: Int, y: Int) -> LinearRGBA {
        get {
            if let image { return image.get(x, y) }
            guard contains(x, y) else { return .transparent }
            let texel = address(x, y).pointee
            return LinearRGBA(
                premultipliedRed: Float(texel.x), green: Float(texel.y),
                blue: Float(texel.z), alpha: Float(texel.w))
        }
        nonmutating set {
            if let image {
                image.set(x, y, newValue)
                return
            }
            guard admitsWrite?() ?? true, contains(x, y) else { return }
            address(x, y).pointee = HalfSurface.texel(newValue)
            mirror?.noteCPUWrite()
        }
    }

    /// 全体を 1 色で埋める。色は添字で書くときと同じく、検めずに面へ移す。
    public func fill(_ color: LinearRGBA) {
        if let image {
            image.fill(color)
            return
        }
        guard admitsWrite?() ?? true else { return }
        let texel = HalfSurface.texel(color)
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: SIMD4<Float16>.self)
            for x in 0..<width { row[x] = texel }
        }
        if count > 0 { mirror?.noteCPUWrite() }
    }

    /// 全画素を、位置と元の色から決めた色で書き換える。Processing の `loadPixels()` と 2 重ループと
    /// `updatePixels()` に当たる。
    ///
    /// 閉包へ渡すのは、画素の位置 `x`・`y` (原点は左上で、添字と同じ向き) と、その画素の
    /// いまの色。返した色がその画素に書かれる。**走査は上の行から、左から右へ** 1 度ずつ
    /// 全画素に進む。
    ///
    /// ```swift
    /// pixels.update { x, y, c in
    ///     brightness(c) > 50 ? color(255) : color(0)   // 明るさで 2 値にする
    /// }
    /// ```
    ///
    /// **書いてよいかの判定と、GPU の仕事の決着は、入口で 1 回だけ行う。** 添字で全画素を書く
    /// 2 重ループは画素ごとに許可を尋ねるので、同じ処理でもこちらが速い。意味は添字と同じで、
    /// 置いてよい区間の外 (``Canvas/pixels``) と形の組み立ての中では、閉包を 1 度も呼ばずに
    /// 1 度注意して何もしない。範囲の外へ書くことはない。
    ///
    /// 読む値も書く値も、添字と同じ**線形・アルファ乗算済みの ``LinearRGBA``** である。書く色は
    /// 検めずに面へ移し、有限の成分は面が表せる ±65504 で止まる。
    ///
    /// **閉包の中で同じ面を読み書きしない。** 同じ面の別の画素を読むと、書き換え済みの値と
    /// 呼ぶ前の値のどちらが読めるかは決まっていない (面ごとに違う)。必要なら、呼ぶ前に別の
    /// 並びへ読んでおく。
    ///
    /// ``Image/pixels`` から取った窓なら、その絵の画素を書き換える。**絵ごとに効果を掛けて新しい絵を
    /// 返す口 (`filtered(_:)`) とは違い、この口は自分を変える** — ``subscript(_:_:)``・
    /// ``fill(_:)`` と同じである。
    public func update(_ transform: (_ x: Int, _ y: Int, _ color: LinearRGBA) -> LinearRGBA) {
        if let image {
            image.transformPixels(transform)
            return
        }
        guard admitsWrite?() ?? true, count > 0 else { return }
        for y in 0..<height {
            let row = base.advanced(by: y * bytesPerRow)
                .assumingMemoryBound(to: SIMD4<Float16>.self)
            for x in 0..<width {
                let texel = row[x]
                let color = LinearRGBA(
                    premultipliedRed: Float(texel.x), green: Float(texel.y),
                    blue: Float(texel.z), alpha: Float(texel.w))
                row[x] = HalfSurface.texel(transform(x, y, color))
            }
        }
        mirror?.noteCPUWrite()
    }

    private func contains(_ x: Int, _ y: Int) -> Bool {
        x >= 0 && y >= 0 && x < width && y < height
    }

    private func address(_ x: Int, _ y: Int) -> UnsafeMutablePointer<SIMD4<Float16>> {
        base.advanced(by: y * bytesPerRow)
            .assumingMemoryBound(to: SIMD4<Float16>.self)
            .advanced(by: x)
    }
}
