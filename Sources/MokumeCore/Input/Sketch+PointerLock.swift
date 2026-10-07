// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

extension Sketch {
    /// カーソルを捕まえる。捕まえている間はカーソルが隠れてその場に留まり、**手を動かした量
    /// だけが届き続ける** — 画面の端で止まらない。
    ///
    /// 一人称で見回すスケッチの口である。手本 (p5.js) と同じく、押すと捕まる書き方になる:
    ///
    /// ```swift
    /// var yaw: Float = 0
    ///
    /// func mouseClicked() { requestPointerLock() }
    ///
    /// func mouseMoved(deltaX: Float, deltaY: Float) {
    ///     yaw += deltaX * 0.005
    /// }
    /// ```
    ///
    /// ## 捕まえている間
    ///
    /// - ``mouseX`` / ``mouseY`` / ``pmouseX`` / ``pmouseY`` は捕まえた時点の位置のまま動かない。
    ///   押下と解放もその位置を名乗る
    /// - 動いた量は、押していなければ ``mouseMoved(deltaX:deltaY:)`` が、押していれば
    ///   ``mouseDragged(deltaX:deltaY:)`` が 1 件ずつ受け取る。フレームの合計は ``movedX`` /
    ///   ``movedY`` (押している間のぶんは ``dragX`` / ``dragY`` も) で読む
    /// - 量の単位は捕まえていないときと同じ描く解像度の画素で、縦軸は下向きである
    ///
    /// ## 捕まるのは、面を押してから
    ///
    /// 呼んだだけでは捕まえない。**窓が前に出ていて、ポインタが面の上にあり、前に外れてから
    /// (または起動してから) その面を 1 度押したとき**に捕まる。押していないのに捕まえると、
    /// 見ていない間にカーソルが消える。`mouseClicked()` の中で呼べばその 1 回の押しで捕まり、
    /// `setup()` や `draw()` から呼んでおけば次に面を押したときに捕まる。つまみ
    /// (``params``) を押しても捕まえない。
    ///
    /// ## 外れるのは 4 つ
    ///
    /// - Escape を押す。**Escape はスケッチにも普通のキーとして届く** (`keyPressed()` で
    ///   `keyCode == .escape`)。止めている間 (``noLoop()``) も効く
    /// - 窓が前から退く (⌘Tab で他のアプリへ移る・他の窓を押す)
    /// - ``exitPointerLock()`` を呼ぶ
    /// - 窓が閉じる・スケッチが終わる (端末の Ctrl-C も、後始末を通って外す)
    ///
    /// Escape か窓が退いて外れた後は、要求が残っていても — `draw()` から毎フレーム呼び続けて
    /// いても — **面をもう一度押すまで捕まえない**。押せば捕まり直す。
    ///
    /// **ここは手本と違う。** 手本では外れると要求も消え、もう一度呼ぶまで捕まらない。ここの
    /// 要求は ``exitPointerLock()`` を呼ぶまで残る — 見張り (`mokume watch`) の下では窓を持つのが
    /// 道具で、外れたことをスケッチへ知らせる経路が無いためで、直に走らせたときも同じに
    /// 振る舞う。外れたら要求も取り下げたいなら、`keyPressed()` で Escape を見て
    /// ``exitPointerLock()`` を呼ぶ。いま捕まっているかを読む口は無い。
    ///
    /// ## 窓の無い実行では何もしない
    ///
    /// 窓を開かずに書き出す実行 (`mokume render`・参照スケッチの `--render`) や、窓を持たない
    /// `SketchRuntime` では、呼んでも何も起きず、止まりもしない。走っていないとき (`init` の
    /// 中など) に呼んでも同じである。外から送る移動 (`.mokume/input` の `mouseMovedBy`) は、
    /// 捕まえていなくても量として届く。
    ///
    /// ## 見張りの下では
    ///
    /// 作品の窓とプレビューのうち、**押された窓が捕まえる**。2 つが同時に捕まえることはない。
    /// 保存で作り直したスケッチが要求しなければ、そこで外れる。
    ///
    /// ## 後始末を通らずに終わったとき
    ///
    /// `kill -9` やクラッシュで落ちると、外す処理は走らない。
    public func requestPointerLock() {
        runningSketch?.pointerLockRequested = true
    }

    /// 捕まえたカーソルを放し、``requestPointerLock()`` の要求を取り下げる。
    ///
    /// 放した後は、もう一度 ``requestPointerLock()`` を呼び、面を押すまで捕まえない。
    /// 捕まえていないときに呼んでも、要求を取り下げるだけである。窓の無い実行と、走っていない
    /// ときは何もしない。
    public func exitPointerLock() {
        runningSketch?.pointerLockRequested = false
    }
}
