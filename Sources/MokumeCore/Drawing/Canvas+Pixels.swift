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
    /// **窓は書いてよいかをこの面に尋ねる** ([#1672])。窓はプロパティに取っておけるので、
    /// 取った時点ではなく書く時点で、置いてよい区間 (フレームの中と、本体の `setup()`・止まって
    /// いる間のコールバック) にいるかを見る。外で書くと 1 度注意して、書かない。
    ///
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    public var pixels: Pixels {
        loadPixelsIfNeeded()
        return target.pixels.asking { [weak self] in self?.admitsPixelWrite() ?? false }
    }

    /// 1 画素の色。範囲の外は透明を返す。
    public func get(_ x: Int, _ y: Int) -> LinearRGBA {
        loadPixelsIfNeeded()
        return target.pixels[x, y]
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
    /// 見るのは ``writesToSurface`` で、``canPlace`` ではない — 形の組み立ての中で書いた画素は
    /// 形に載らず、面へ直に書かれるからである。
    ///
    /// [ADR-0021]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0021-solid-space-and-frame-assembly.md
    /// [#1654]: https://github.com/mokume-metal/mokume/issues/1654
    /// [#1655]: https://github.com/mokume-metal/mokume/issues/1655
    /// [#1672]: https://github.com/mokume-metal/mokume/issues/1672
    func admitsPixelWrite() -> Bool {
        guard writesToSurface else {
            warnOutsideFrame(.pixelWrite)
            return false
        }
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
        guard !hasLoadedPixels || (hasPendingDrawing && !pixelLoadFailed) else { return }
        loadPixels()
    }
}
