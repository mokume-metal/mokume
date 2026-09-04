// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import simd

// 周囲を置く・周囲を背景として描く。単位と寿命は ``Surroundings`` が定める。
extension Canvas {

    // 立体を取り巻く周囲を置く。
    public func surroundings(_ surroundings: Surroundings) {
        guard isDrawing else { return warnSurroundingsOutsideFrame() }
        guard surroundings.isUsable else { return warnBadSurroundings() }
        closeBatch()
        activeSurroundings = surroundings
    }

    // 周囲を背景として描く。
    public func background(_ surroundings: Surroundings) {
        guard surroundings.isUsable else { return warnBadSurroundings() }
        // 塗り 1 色の背景と同じく、溜めていたものを捨ててから置き直す
        discardPending()
        drawBackdrop(surroundings)
    }

    /// いまの視点が写す範囲いっぱいに、周囲そのものを出す面を置く。
    ///
    /// **置くのと描くのは別**である ([`surroundings(_:)`](Canvas+Surroundings.swift) を
    /// 呼ばずにこれだけを呼べば、背景にだけ出て映り込みには効かない)。片方を呼んだら
    /// もう片方も、という親切は入れない — 絵の理由が呼び出し 1 行から読めなくなる。
    private func drawBackdrop(_ surroundings: Surroundings) {
        let corners = currentCamera.backdropCorners()
        backdrop = surroundings
        inSolidBatch {
            // 面の向きは持たせない。この列は光も材質も見ずに、周囲の色をそのまま出す
            let white = LinearRGBA.linear(red: 1, green: 1, blue: 1)
            for index in [0, 1, 2, 0, 2, 3] {
                appendSolidVertex(position: corners[index], normal: .zero, color: white)
            }
        }
        // **旗を下ろす前に閉じる。** 列は閉じた時点の設定で描かれるので、先に下ろすと
        // この面が「ただの立体」として閉じられ、周囲ではなく塗りで出る
        closeBatch()
        backdrop = nil
    }

    /// フレームの外で周囲を置いたことを、初回だけ知らせる。
    private func warnSurroundingsOutsideFrame() {
        warnOnce(
            .surroundingsOutsideFrame,
            "周囲はフレームごとに置き直すものなので、描くところ (draw) で呼んでください。"
                + "初期化のときに置いた周囲はどのフレームにも属さないため、無視しました")
    }

    /// 受け取れない周囲を、初回だけ知らせる。
    private func warnBadSurroundings() {
        warnOnce(
            .badSurroundings,
            "surroundings(): 数でない値・負の色が渡されたので、周囲を変えませんでした")
    }
}
