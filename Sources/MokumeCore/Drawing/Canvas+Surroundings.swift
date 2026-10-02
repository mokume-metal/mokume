// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 周囲を置く・周囲を背景として描く。単位と寿命は ``Surroundings`` が定める。
extension Canvas {

    // 立体を取り巻く周囲を置く。
    public func surroundings(_ surroundings: Surroundings) {
        guard isDrawing else { return warnOutsideFrame(.surroundings) }
        guard surroundings.isUsable else { return warnBadSurroundings() }
        closeBatch()
        activeSurroundings = surroundings
    }

    // 周囲を背景として描く。
    public func background(_ surroundings: Surroundings) {
        // 塗り 1 色の背景と同じく、区間の外では溜めたものを捨てる前に断る (#1672)。形の組み立ての
        // 中も区間に数えない (`writesToSurface`・塗り 1 色の背景の説明)。値の検めより先に断る —
        // どのフレームにも属さない背景の値を言っても、直す先を指さない
        guard writesToSurface else { return warnOutsideFrame(.placing) }
        // 形の組み立ての中も、塗り 1 色の背景と同じ鍵で断る (#1588)
        guard !recordingShape else { return warnInsideShape(.background) }
        guard surroundings.isUsable else { return warnBadSurroundings() }
        // 塗り 1 色の背景と同じ関所で置き換える (#1685)。呼んだ時点のスタイルも、途中の描き切りで
        // 載った絵と奥行きも拾わず、切り抜きがあればその中だけを置き換える
        //
        // **置くのと描くのは別**である (``surroundings(_:)`` を呼ばずにこれだけを呼べば、背景にだけ
        // 出て映り込みには効かない)。片方を呼んだらもう片方も、という親切は入れない — 絵の理由が
        // 呼び出し 1 行から読めなくなる
        replaceSurface(with: .surroundings(surroundings))
    }

    /// 受け取れない周囲を、初回だけ知らせる。
    private func warnBadSurroundings() {
        warnOnce(
            .badSurroundings,
            "surroundings(): got a value that is not a number, or a negative colour, so the "
                + "surroundings were left as they were")
    }
}
