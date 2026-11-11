// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 絵の一部を切り出す `cropped` と、大きさを変える `resized` ([#3711])。どちらも新しい絵を返し、元を変えない。
//
// [#3711]: https://github.com/mokume-metal/mokume/issues/3711
extension Image {
    /// 絵の一部を切り出した、新しい絵を返す。Processing の `PImage.get(x, y, w, h)` に当たる。**元の絵は変えない。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var picture: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         // 120 x 90 の絵: 横に赤、縦に青が増え、真ん中に明るい円
    ///         picture = try createImage(120, 90)
    ///         for y in 0..<90 {
    ///             for x in 0..<120 {
    ///                 let inside = (x - 60) * (x - 60) + (y - 45) * (y - 45) < 30 * 30
    ///                 picture.set(x, y, .display(
    ///                     red: inside ? 1 : Float(x) / 119, green: inside ? 0.85 : 0.3,
    ///                     blue: inside ? 0.4 : Float(y) / 89))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         image(picture, 20, 105)
    ///         // 右下の 4 分の 1 (60 x 45) を切り出して、等倍で右に置く
    ///         let corner = try! picture.cropped(x: 60, y: 45, width: 60, height: 45)
    ///         image(corner, 170, 150)
    ///         // 絵をはみ出す範囲は透明になる (右半分が背景のまま)
    ///         let beyond = try! picture.cropped(x: 90, y: 0, width: 60, height: 45)
    ///         image(beyond, 260, 105)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に元の絵。その右に、元の絵の右下 4 分の 1 を切り出した小さな絵と、右端の帯を切り出してはみ出した右半分が透明な絵 -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// 範囲は絵の左上を原点とした画素で数える。**絵をはみ出す部分は透明になる** (``get(_:_:)`` が範囲の外で
    /// 透明を返すのと同じ)。範囲が絵とまったく重ならなくても投げず、全体が透明の絵を返す。画素は作業空間の値の
    /// まま写す (8 bit を経由しない)。
    ///
    /// 返した絵は元と画素も面も共有しない (``copy()`` と同じ)。**カメラの `image` から切り出した絵は、カメラの
    /// 次の 1 枚で書き換わらない。**
    ///
    /// 手本の `PImage.get(x, y, w, h)` は、描き場所 (画面) からも同じ名前で切り出す。画面を切り出すのは
    /// 別の API ([#3714](https://github.com/mokume-metal/mokume/issues/3714)) で、これは絵からだけ切り出す。
    ///
    /// - Parameters:
    ///   - x: 切り出す範囲の左端。
    ///   - y: 切り出す範囲の上端。
    ///   - width: 切り出す幅 (返す絵の幅)。
    ///   - height: 切り出す高さ (返す絵の高さ)。
    /// - Returns: `width` x `height` の新しい `Image`。
    /// - Throws: 幅・高さのどちらかが 1 を割るか面の上限を越えるとき ``ImageFailure/unplaceable(width:height:)``。
    ///   1 を割る指定を 1×1 へ丸めない (`createImage(_:_:)` と同じ)。
    // shot: 後で撮る
    public func cropped(x: Int, y: Int, width: Int, height: Int) throws(ImageFailure) -> Image {
        try Self.refuseUnplaceable(width: width, height: height)
        let source = workingPixels
        var pixels = [SIMD4<Float16>](repeating: .zero, count: width * height)
        for row in 0..<height {
            // 足して桁が溢れる位置は、絵の外 (透明) である
            let (sourceY, rowOverflow) = y.addingReportingOverflow(row)
            guard !rowOverflow, sourceY >= 0, sourceY < self.height else { continue }
            for column in 0..<width {
                let (sourceX, overflow) = x.addingReportingOverflow(column)
                guard !overflow, sourceX >= 0, sourceX < self.width else { continue }
                pixels[row * width + column] = source[sourceY * self.width + sourceX]
            }
        }
        return try sibling(width: width, height: height, pixels: pixels)
    }

    /// 大きさを変えた、新しい絵を返す。Processing の `PImage.resize(w, h)` に当たる。**元の絵は変えない。**
    ///
    /// @Row {
    ///   @Column(size: 3) {
    ///     <!-- example: 文脈 var stripes: Image! -->
    ///     ```swift
    ///     func setup() throws {
    ///         // 1 画素ずつ白と黒を交互に並べた 40 x 30 の縞
    ///         stripes = try createImage(40, 30)
    ///         for y in 0..<30 {
    ///             for x in 0..<40 {
    ///                 let level: Float = x % 2 == 0 ? 1 : 0
    ///                 stripes.set(x, y, .display(red: level, green: level, blue: level))
    ///             }
    ///         }
    ///     }
    ///
    ///     func draw() {
    ///         background(23, 26, 31)
    ///         // 縮めると光の量で平均した灰色になる (白と黒の半々は、画面で中間より明るく見える灰色)
    ///         let half = try! stripes.resized(width: 20, height: 15)
    ///         // 縦横比を変えて引き伸ばすと、縞の 1 本ずつが広がる
    ///         let wide = try! stripes.resized(width: 160, height: 30)
    ///         image(stripes, 20, 40)
    ///         image(half, 80, 47)
    ///         image(wide, 120, 40)
    ///         // 比べる中間の灰色 (エンコードした値の平均) の帯
    ///         fill(128)
    ///         noStroke()
    ///         rect(80, 90, 20, 15)
    ///     }
    ///     ```
    ///   }
    ///   @Column {
    ///     <!-- shot: 左に白黒の細い縞、その右に半分の大きさへ縮めた明るめの灰色の四角、右に横へ 4 倍に引き伸ばした縞。下に比べるための暗めの灰色の四角 -->
    ///     <!-- /shot -->
    ///   }
    /// }
    ///
    /// **手本の `resize` は自分を変えるが、これは新しい絵を返して元を変えない** (そのため `resized`。同じ名前で
    /// 新しい値を返すと同名異義になる)。手本の `resize(150, 0)` (0 で縦横比を保つ) は無い — 1 を割る指定は
    /// 丸めずに投げる。縦横比を保つなら、`resized(width: 150, height: 150 * h / w)` と自分で数える。
    ///
    /// 縦と横は別々に変える。どちらの向きも決まった読み方で、同じ絵と大きさからは同じ画素が出る。
    ///
    /// - **縮める向き**は、作業空間 (線形・アルファ乗算済み) のまま、**光の量で平均する**。新しい 1 画素が覆う元の
    ///   範囲を、覆う長さの割合で混ぜる (面積の平均)。エンコードした 8 bit の値のまま平均すると、明暗が接する所が
    ///   暗くなる (白と黒の半々が 0.5 ではなく約 0.21 の光になる)。カメラのコマを縮めるときも同じく光の量で混ぜる
    /// - **広げる向き**は、`image(picture, x, y, w, h)` が絵を引き伸ばして置くときと同じく、隣り合う 2 画素の
    ///   中心の間を直線で補う。端は端の画素の色で延ばす
    ///
    /// 透けた画素は乗算済みのまま混ぜるので、透明な画素の色が縁へにじまない。返した絵は元と画素も面も共有しない
    /// (``copy()`` と同じ)。
    ///
    /// - Parameters:
    ///   - width: 返す絵の幅。
    ///   - height: 返す絵の高さ。
    /// - Returns: `width` x `height` の新しい `Image`。大きさが同じなら ``copy()`` と同じ画素になる。
    /// - Throws: 幅・高さのどちらかが 1 を割るか面の上限を越えるとき ``ImageFailure/unplaceable(width:height:)``。
    ///   1 を割る指定を 1×1 へ丸めない (`createImage(_:_:)` と同じ)。
    // shot: 後で撮る
    public func resized(width: Int, height: Int) throws(ImageFailure) -> Image {
        try Self.refuseUnplaceable(width: width, height: height)
        let pixels = ImageResampling.resample(
            workingPixels, from: (self.width, self.height), to: (width, height))
        return try sibling(width: width, height: height, pixels: pixels)
    }

    /// 返す絵の大きさを、画素を組む前に検める (``Canvas/createImage(_:_:)`` と同じ範囲)。
    private static func refuseUnplaceable(width: Int, height: Int) throws(ImageFailure) {
        let sides = RenderDevice.textureSides
        guard sides.contains(width), sides.contains(height) else {
            throw .unplaceable(width: width, height: height)
        }
    }

    /// 同じ GPU に、新しい絵を作る。
    private func sibling(width: Int, height: Int, pixels: [SIMD4<Float16>]) throws(ImageFailure) -> Image {
        do {
            return try Image(width: width, height: height, pixels: pixels, gpu: gpu)
        } catch {
            throw .unplaceable(width: width, height: height)
        }
    }
}

/// `resized` の読み方 ([#3711])。**縦と横を別々に、決まった重みで混ぜる。**
///
/// 縮める向きは面積の平均 (光の量の平均)、広げる向きは画素の中心どうしの直線の補い (端は延ばす) で、
/// 描くときの読み方 (線形・端で延ばす) と揃える。値は作業空間 (線形・乗算済み) のまま、Float で混ぜてから
/// 半精度へ戻す。
///
/// [#3711]: https://github.com/mokume-metal/mokume/issues/3711
nonisolated enum ImageResampling {
    /// 1 本の向きで、新しい画素ごとに混ぜる元の画素と重み。重みの和は 1。
    static func weights(from source: Int, to destination: Int) -> [[(index: Int, weight: Float)]] {
        if destination == source {
            return (0..<source).map { [(index: $0, weight: Float(1))] }
        }
        let ratio = Double(source) / Double(destination)
        if destination < source {
            // 新しい画素 j が覆う元の範囲 [j * ratio, (j + 1) * ratio) を、覆う長さの割合で混ぜる
            return (0..<destination).map { j in
                let start = Double(j) * ratio
                let end = Double(j + 1) * ratio
                var taps: [(index: Int, weight: Float)] = []
                var index = Int(start.rounded(.down))
                while Double(index) < end, index < source {
                    let covered = min(end, Double(index + 1)) - max(start, Double(index))
                    if covered > 0 { taps.append((index, Float(covered / ratio))) }
                    index += 1
                }
                return taps
            }
        }
        // 広げる: 新しい画素の中心が元のどこに当たるかを求め、隣り合う 2 つの中心の間を直線で補う
        return (0..<destination).map { j in
            let place = min(max((Double(j) + 0.5) * ratio - 0.5, 0), Double(source - 1))
            let lower = Int(place.rounded(.down))
            let upper = min(lower + 1, source - 1)
            let fraction = Float(place - Double(lower))
            if upper == lower || fraction == 0 { return [(index: lower, weight: Float(1))] }
            return [(index: lower, weight: 1 - fraction), (index: upper, weight: fraction)]
        }
    }

    /// 画素の並びを `from` の大きさから `to` の大きさへ読み直す。横を先に、縦を後に混ぜる。
    static func resample(
        _ pixels: [SIMD4<Float16>], from: (width: Int, height: Int), to: (width: Int, height: Int)
    ) -> [SIMD4<Float16>] {
        let across = weights(from: from.width, to: to.width)
        let down = weights(from: from.height, to: to.height)
        // 横: from.height 行 x to.width 列
        var rows = [SIMD4<Float>](repeating: .zero, count: to.width * from.height)
        for y in 0..<from.height {
            let base = y * from.width
            for (x, taps) in across.enumerated() {
                var sum = SIMD4<Float>.zero
                for tap in taps { sum += SIMD4<Float>(pixels[base + tap.index]) * tap.weight }
                rows[y * to.width + x] = sum
            }
        }
        // 縦: to.height 行 x to.width 列
        var result = [SIMD4<Float16>](repeating: .zero, count: to.width * to.height)
        for (y, taps) in down.enumerated() {
            for x in 0..<to.width {
                var sum = SIMD4<Float>.zero
                for tap in taps { sum += rows[tap.index * to.width + x] * tap.weight }
                result[y * to.width + x] = SIMD4<Float16>(sum)
            }
        }
        return result
    }
}
