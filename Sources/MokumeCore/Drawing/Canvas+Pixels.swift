// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 画素の面。意味の説明は利用者が最初に触る層 (`Sketch`) が正本で、ここは受け口である
// ([ADR-0020] 決定 4)。
//
// **待つ場所をここ 1 つに決めている。** 画素を読むには GPU の仕事が終わっている必要が
// あり、待つ場所が経路ごとに違うと「どの時点の絵を読んでいるか」が呼び方で変わる。
// だから読み書きの入口はすべて `loadPixelsIfNeeded()` を通り、待つ実装は 1 つしかない。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Canvas {
    /// 溜めている図形を描き切り、画素を読める状態にする。
    public func loadPixels() {
        // **形の組み立て (`createShape`) の中では描き切らない** ([#1588])。描き切ると溜め場が
        // 空になり、組み立てが控えた区間が溜め場の外を指して、出口の切り出しで落ちる。組み立てた
        // ものもまだ描いていない形なので、読んでも意味を持たない。**断るのは自分の面が組み立ての途中の
        // ときだけ** — 組み立ての途中の本体に置かれた描き場所は読める ([#2203])。4 つの口 (ここ・`pixels`・`get`・
        // `set`) が同じ鍵で 1 度注意する (``refusesInsideShape()``)
        //
        // [#1588]: https://github.com/mokume-metal/mokume/issues/1588
        // [#2203]: https://github.com/mokume-metal/mokume/issues/2203
        guard !refusesInsideShape() else { return }
        do {
            // **効果はフレームの終わりに立つ段**なので、途中で読む画素には効いていない
            // (通すと、効果のかかった絵の上に続きが描かれる)。**読み戻しも同じコマンドに
            // 積む** — 描画先は GPU 専用の面なので、読むには写しへ blit する必要がある。
            // ここで積めば、続く `pixels` は blit を積み直さず待つだけで済む (#753)
            try flush(applyingEffects: false, mirroringPixels: true)
            pixelLoadFailed = false
        } catch {
            // 読み取りは落とさない (ADR-0020 決定 5) ので、投げずに残す。次のフレームの
            // 描き切りが同じ理由で失敗し、そちらから外へ出る。**このフレームの読む口は
            // もうやり直さない** (``pixelLoadFailed``)
            pixelLoadFailed = true
            Diagnostics.warn("Could not finish drawing before reading pixels: \(error.headline)")
        }
        hasLoadedPixels = true
    }

    /// 描いた結果の画素。
    ///
    /// **ビューは書いてよいかをこの面に尋ねる** ([#1672])。ビューはプロパティに取っておけるので、
    /// 取った時点ではなく書く時点で、置いてよい区間 (フレームの中と、本体の `setup()`・止まって
    /// いる間のコールバック) にいるかを見る。外で書くと 1 度注意して、書かない。
    ///
    /// 形の組み立ての中では読み込まず、いまの写しを返す (``loadPixels()``・[#1588])。書き込みは
    /// 書く時点で断る (`admitsPixelWrite()`)。**断るのは自分の面が組み立ての途中のときだけ**で、組み立ての
    /// 途中の本体に置かれた描き場所は読める ([#2203])。読み込みは、置いた側に置いた時点の絵を写させる
    /// (組み立ての入口より前の列を写しへ差し替えるだけで描き切らない・#1855 の案 E)。写しの上限と失敗のときは
    /// 組み立ての前の列だけを描き切り、組み立てている区間は残す (#2850)。
    ///
    /// **1 画素ごとに通っても安い。** 状態は呼ばれた時点で直に読み (控えない)、待ちと写しの確かめは
    /// 前の答えが有効なら省く (`RenderTarget.pixels`・[#2369])。
    ///
    /// **ただし、全画素を書き換えるなら ``Pixels/update(_:)`` が速い。** 上の安さは 1 回の読み書きの費用の話で、
    /// こちらは回し方の話である。添字の 2 重ループは画素ごとに書いてよいかを尋ね、`update` は入口で 1 回だけ
    /// 尋ねる。1280×720 で、ビューを 1 度取って全画素を `p[x, y] = p[x, y]` で書く形が 73.2 ms、同じ処理を
    /// `update` で書く形が 2.0 ms だった (約 37 倍・M3 Max・release・15 回の中央値・[#2955])。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    /// [#2203]: https://github.com/mokume-metal/mokume/issues/2203
    /// [#2369]: https://github.com/mokume-metal/mokume/issues/2369
    /// [#2955]: https://github.com/mokume-metal/mokume/issues/2955
    public var pixels: Pixels {
        let loading = needsPixelLoad
        if !refusesInsideShape(), loading { loadPixels() }
        return target.pixels.asking(pixelWriteGate)
    }

    /// ビューに渡す問い合わせ。面ごとに 1 つ (``pixelWriteGateMade``)。
    private var pixelWriteGate: () -> Bool {
        if let gate = pixelWriteGateMade { return gate }
        let gate: () -> Bool = { [weak self] in self?.admitsPixelWrite() ?? false }
        pixelWriteGateMade = gate
        return gate
    }

    /// 1 画素の色。範囲の外では透明を返す。形の組み立ての中でも透明を返すが、**それは自分の面が組み立ての
    /// 途中のときだけ**である (``loadPixels()``・組み立ての途中の本体に置かれた描き場所は読める・[#2203])。
    ///
    /// 返す値は線形・アルファ乗算済みの ``LinearRGBA`` である ([ADR-0011] 決定 4)。0–255 の
    /// 乗算していない数で読むときは ``red(_:)`` ほかを通す。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    /// [#2203]: https://github.com/mokume-metal/mokume/issues/2203
    public func get(_ x: Int, _ y: Int) -> LinearRGBA {
        let loading = needsPixelLoad
        guard !refusesInsideShape() else { return .transparent }
        if loading { loadPixels() }
        return target.pixels[x, y]
    }

    /// 描いた絵の全体を、新しい ``Image`` にして返す。大きさは座標の大きさ (``width`` × ``height``)。
    public func get() throws(ImageFailure) -> Image {
        try get(0, 0, Int(width), Int(height))
    }

    /// 描いた絵の領域を、新しい ``Image`` にして返す。領域も返す絵の大きさも座標の単位で数える
    /// (1 画素の ``get(_:_:)`` は実際の画素で数える)。範囲の外は透明。形の組み立ての中では、読まずに
    /// 透明の絵を返す (``get(_:_:)`` と同じ)。
    ///
    /// **刻んだ画素が座標と違えば、読み直して座標の大きさにそろえる** ([#3714])。書き出しの倍率で細かく
    /// 刻んでいれば光の量で平均して縮め、細かさを下げていれば広げる (``Image/resized(width:height:)`` と同じ
    /// 読み方)。読む範囲は刻んだ画素の境へ外向きに丸めるので、座標 1 つが画素の境に乗らない細かさ (0.5 で
    /// 奇数の位置など) では、半画素までずれうる。
    ///
    /// [#3714]: https://github.com/mokume-metal/mokume/issues/3714
    public func get(_ x: Int, _ y: Int, _ w: Int, _ h: Int) throws(ImageFailure) -> Image {
        // 返す絵の大きさは、読む前に検める (``createImage(_:_:)`` と同じ範囲・1 を割る指定を丸めない)
        let sides = RenderDevice.textureSides
        guard sides.contains(w), sides.contains(h) else { throw .unplaceable(width: w, height: h) }
        let loading = needsPixelLoad
        let texels: [SIMD4<Float16>]
        if refusesInsideShape() {
            texels = [SIMD4<Float16>](repeating: .zero, count: w * h)
        } else {
            if loading { loadPixels() }
            texels = regionTexels(x, y, w, h)
        }
        return try makeImage(ImageFile.Decoded(width: w, height: h, pixels: texels))
    }

    /// ``Rect`` の領域を、新しい ``Image`` にして返す。``imageMode(_:)``・``rectMode(_:)`` に従わず、値のとおり
    /// 左上で読む。値は近い整数へ丸めて ``get(_:_:_:_:)`` へ渡す。
    public func get(in rect: Rect) throws(ImageFailure) -> Image {
        let (w, h) = (Self.wholeUnits(rect.width), Self.wholeUnits(rect.height))
        guard let w, let h else { throw .unplaceable(width: w ?? 0, height: h ?? 0) }
        // 位置が数でないか Int に収まらなければ、どの画素とも重ならない (透明の絵になる)
        return try get(Self.wholeUnits(rect.left) ?? .min, Self.wholeUnits(rect.top) ?? .min, w, h)
    }

    /// 座標を近い整数へ丸める。数でない・Int に収まらないなら `nil`。
    private static func wholeUnits(_ value: Float) -> Int? {
        let rounded = value.rounded()
        guard rounded.isFinite, abs(rounded) < 0x1p62 else { return nil }
        return Int(rounded)
    }

    /// 座標の領域 (`x`, `y`, `w`, `h`) を、刻んだ画素 (``pixels``) から読んで `w` × `h` の並びにする。
    private func regionTexels(_ x: Int, _ y: Int, _ w: Int, _ h: Int) -> [SIMD4<Float16>] {
        let view = target.pixels
        let (columns, rows) = (Int(width), Int(height))
        // 面とまったく重ならないか、写しを用意できなかった (大きさ 0 のビュー) なら全体が透明。`w`・`h` は
        // 1〜面の上限なので、`x < columns` を確かめた後の `x + w` は溢れない
        guard view.width > 0, view.height > 0, x < columns, y < rows, x + w > 0, y + h > 0
        else { return [SIMD4<Float16>](repeating: .zero, count: w * h) }
        if view.width == columns, view.height == rows {
            return view.texels(x: x, y: y, columns: w, rows: h)
        }
        // ここでは x・y が (-w, 面の幅) の内にあるので、Double で掛けても溢れない。行き先と大きさが同じなら
        // `resample` は元の画素をそのまま読む
        let (scaleX, scaleY) = (Double(view.width) / Double(columns), Double(view.height) / Double(rows))
        let left = Int((Double(x) * scaleX).rounded(.down))
        let top = Int((Double(y) * scaleY).rounded(.down))
        let right = max(Int((Double(x + w) * scaleX).rounded(.up)), left + 1)
        let bottom = max(Int((Double(y + h) * scaleY).rounded(.up)), top + 1)
        let drawn = view.texels(x: left, y: top, columns: right - left, rows: bottom - top)
        return ImageResampling.resample(
            drawn, from: (right - left, bottom - top), to: (w, h))
    }

    public func set(_ x: Int, _ y: Int, _ color: LinearRGBA) {
        // 画素の書き込みも置くことに含む ([#1672])。読む前に断る — 区間の外で描き切らせない
        //
        // [#1672]: https://github.com/mokume-metal/mokume/issues/1672
        guard admitsPixelWrite() else { return }
        loadPixelsIfNeeded()
        target.pixels[x, y] = color
    }

    /// 画素を書いてよいか。だめなら 1 度だけ言う ([ADR-0021] 決定 4 の追補 (2026-09-27)・[#1672])。
    ///
    /// **書いた画素も、置いた図形と同じく次の描き切りで面に載る**ので、属する先の規則が同じで
    /// なければならない。区間の外で書いた画素を通していたので、描き場所では `get()` が読めるのに
    /// `image()` には出ず ([#1654])、効果を掛けた描き場所では次のフレームに効果が 2 回掛かった
    /// ([#1655])。
    ///
    /// 見るのは ``writesToSurface`` で、``canPlace`` ではない — ``canPlace`` は形の組み立ての中を
    /// 含むが、画素は形に載らないので、組み立ては画素の書き込みの居場所にならない。**組み立ての
    /// 中は、区間の中でも断る** ([#1588])。書く前に読むので、通すと描き切って組み立ての区間を
    /// 壊す (``refusesInsideShape()``)。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1654]: https://github.com/mokume-metal/mokume/issues/1654
    /// [#1655]: https://github.com/mokume-metal/mokume/issues/1655
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    func admitsPixelWrite() -> Bool {
        guard writesToSurface else {
            warnOutsideFrame(.pixelWrite)
            return false
        }
        // 形の組み立ての中では書かない。書く前に読むので、通すと描き切る (``loadPixels()``・#1588)。
        // 区間の外なら上の注意を先に言う (塗り直しと同じ順)
        let loading = needsPixelLoad
        guard !refusesInsideShape() else { return false }
        // **書く前に、このフレームの絵を写しへ読んでおく。** ビュー (``pixels``) は取っておけるので、
        // 前のフレームで取ったビューにこのフレームで書くと、写しは前のフレームの絵 (効果を通した
        // 後) のまま書き込み待ちになる。するとこのフレームの最初の描き切りが、効果を通す前の
        // 絵を戻した後に写し全体を書き戻し、効果が 2 回掛かる (#1655 と同じ形・#1672 の反証 1)。
        // 読めば最初の描き切りは書く前に済み、写しもいまの絵になる。取り直さないビューでも、GPU が
        // 写しへ読み戻している途中に書かない (`pixels` が待つ)
        if loading { _ = pixels }
        // 画素の書き込みはベクターへ書けない (#3139)。**名乗りはこの合流点で数える** — 書く口は
        // `set(_:_:_:)` と、ビュー (``pixels``) の添字・`fill(_:)`・`update(_:)` の 3 つが、どれもここへ着く。
        // `set(_:_:_:)` の中だけで数えると、ビューから書いた画素は黙って SVG から抜ける
        noteVectorDrop(.pixels)
        return true
    }

    /// 画素の口が、形の組み立てのために断るか。断るなら 1 度だけ言う ([#1588])。
    ///
    /// **断るのは、自分の面が組み立ての途中のときだけ** (``recordingShape``)。書く前に読む口は描き切るので、
    /// 通すと自分の組み立ての区間を壊す。組み立ての途中の本体に置かれた描き場所は断らない ([#2203]) —
    /// 置いた側は組み立ての入口より前の列を写しへ差し替えるだけで描き切らず、写しの上限と失敗のときも
    /// 組み立ての前の列だけを描き切って組み立てている区間は残す (#1855 の案 E・#2850)。以前はこの口が置いた側を
    /// 組み立ての区間ごと描き切らせたので、置かれた描き場所でも断っていた (#1588)。
    ///
    /// [#1588]: https://github.com/mokume-metal/mokume/issues/1588
    /// [#2203]: https://github.com/mokume-metal/mokume/issues/2203
    private func refusesInsideShape() -> Bool {
        guard recordingShape else { return false }
        warnInsideShape(.pixels)
        return true
    }

    /// このフレームでまだ読んでいないか、読んだあとに描いたなら、読める状態にする。
    ///
    /// **読んだあとに描いたものも読む** ([#1368])。フレームで 1 度読んだかだけを見ていた
    /// ときは、読んだあとの図形が描き切られず、古い写しが読めていた — 「`loadPixels()` を
    /// 省いても結果は変わらない」が、画素に 1 度触れたフレームでは成り立っていなかった。
    ///
    /// 描いていなければ写しをそのまま使うので、読んで描かずにまた読むだけなら、
    /// 画素を 100 万回読んでも描き切るのも待つのも 1 度きり (#753)。
    ///
    /// **失敗した描き切りは、読むたびにはやり直さない。** 失敗しても溜めたものは残るので、
    /// 溜めたかだけを見ると GPU が詰まっているときに 1 画素ごとに待つことになる。
    ///
    /// [#1368]: https://github.com/mokume-metal/mokume/issues/1368
    private func loadPixelsIfNeeded() {
        guard needsPixelLoad else { return }
        loadPixels()
    }

    /// このフレームでまだ読んでいないか、読んだあとに描いたか (``loadPixelsIfNeeded()``)。
    private var needsPixelLoad: Bool {
        !hasLoadedPixels || (hasPendingDrawing && !pixelLoadFailed)
    }
}
