// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 計算の置き場の組 (置き場所・指定・描く引数) を、呼び出しごとに使い分ける帳簿。
///
/// **粒 (``Particles``) と、数の並びを置き場所として読む道 (``PositionPlacer``) が同じ規則を使う。**
/// 組は呼び出しごとに分ける — 同じ描き切りの中で 2 回呼んだとき、1 回目の計算が 2 回目の指定を読んだり、
/// 1 回目の列が 2 回目の置き場所で描かれたりしない ([#1651])。規則を両方に写すと、片方だけ直したときに
/// 同じ事情が違う振る舞いになる (#1656 の持ち越しの尋ね方を直した跡が、写しの片方にだけ残る)。
///
/// 組そのもの (`Draw`) は持ち主が持つ。帳簿が持つのは、組ごとの「最後に使った面と、そのときの面の
/// 描き切りの印 (``Canvas/settleMark``)」だけで、持ち主の組の並びと同じ長さを保つ。
///
/// [#1651]: https://github.com/mokume-metal/mokume/issues/1651
struct DrawClaims {
    /// 組ごとに、最後に使った面と、そのときの面の描き切りの印。印が変わった組は、書いた指定を読む計算も、
    /// 置き場所を読む列も、投入か破棄を済ませている。ただし途中の描き切りから持ち越した落とす列
    /// (#1656) は、印が変わった後も置き場所を読むので、使い回す前に面へ尋ねる。
    private var entries: [(canvas: Weak<Canvas>, mark: Canvas.SettleMark)?] = [nil]

    /// 組を足すときに投げる失敗。**検査が差し替える** (確保の失敗は検査の中で起こせない)。
    var allocationFailureForTesting: RenderFailure?

    /// 組の数。持ち主の組の並びと同じ。
    var count: Int { entries.count }

    /// `canvas` のこの呼び出しが使う組の番号を選ぶ。**まだ読まれていない組は使わない** — 空いた組のうち
    /// 先頭のものを使い、空きが無ければ `addDraw` で 1 つ足す (足した組が末尾に入ること)。
    ///
    /// 空いているのは、使った面が居なくなったか、使ったときから面の描き切りの印が変わった組である。
    /// **粒は面をまたいで効く**: 1 つの群を本体と描き場所の両方で置けるので、本体で呼んで組 0 を取った後に
    /// 描き場所で呼ぶと、組 0 は本体の描き切りを待っているので、描き場所は組 1 を使う。**置き場所の道は
    /// 置き場を面ごとに持つ** (``Canvas/PositionLayouts``) ので、同じ面の中の呼び出しと描き切りの間にだけ効く。
    ///
    /// - Parameters:
    ///   - instances: 番号の組の置き場所。持ち越した落とす列が読む組かを面へ尋ねるのに使う
    ///     (``Canvas/keepsCaster(reading:)``)
    ///   - addDraw: 組を 1 つ、持ち主の並びの末尾へ足す
    ///
    /// 足すのに失敗したら投げる。何も選ばないので、呼ぶ側は進めも描きもせずに帰る。
    mutating func claim(
        by canvas: Canvas,
        instances: (Int) -> Numbers,
        addDraw: () throws(RenderFailure) -> Void
    ) throws(RenderFailure) -> Int {
        // **持ち越した落とす列が読む組は空いていない** ([#1656])。途中の描き切りの後も、フレームの
        // 終わりの焼き付けがその組の置き場所を読む
        //
        // [#1656]: https://github.com/mokume-metal/mokume/issues/1656
        var free: Int?
        for (index, entry) in entries.enumerated() {
            guard let entry, let owner = entry.canvas.value else {
                free = index
                break
            }
            if owner.settleMark != entry.mark, !owner.keepsCaster(reading: instances(index)) {
                free = index
                break
            }
        }
        let index: Int
        if let free {
            index = free
        } else {
            if let allocationFailureForTesting { throw allocationFailureForTesting }
            try addDraw()
            entries.append(nil)
            index = entries.count - 1
        }
        entries[index] = (Weak(canvas), canvas.settleMark)
        return index
    }
}
