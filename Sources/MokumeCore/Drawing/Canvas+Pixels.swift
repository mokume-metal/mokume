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
            try flush()
        } catch {
            // 読み取りは落とさない (ADR-0020 決定 5) ので、投げずに残す。次のフレームの
            // 描き切りが同じ理由で失敗し、そちらから外へ出る
            Diagnostics.warn("画素を読む前の描き切りに失敗しました: \(error)")
        }
        hasLoadedPixels = true
    }

    /// 描いた結果の画素。
    public var pixels: Pixels {
        loadPixelsIfNeeded()
        return target.pixels
    }

    /// 1 画素の色。範囲の外は透明を返す。
    public func get(_ x: Int, _ y: Int) -> LinearRGBA {
        loadPixelsIfNeeded()
        return target.pixels[x, y]
    }

    // 1 画素の色を書き換える。範囲の外は何もしない。
    public func set(_ x: Int, _ y: Int, _ color: LinearRGBA) {
        loadPixelsIfNeeded()
        target.pixels[x, y] = color
    }

    /// このフレームでまだ読んでいなければ、読める状態にする。
    ///
    /// 1 フレームに 1 度しか描き切らないので、画素を 100 万回読んでも待つのは 1 度きり。
    private func loadPixelsIfNeeded() {
        guard !hasLoadedPixels else { return }
        loadPixels()
    }
}
