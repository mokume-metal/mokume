// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

// 走っているスケッチへ差込口を足す・外す。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
extension Sketch {

    /// 入り口を、走っているスケッチへ足す。
    ///
    /// **呼べば使える機能を作るための口である** ([ADR-0042] 決定 2)。カメラのような機能は、
    /// 利用者に ``plugins`` へ書かせず、作る口の中でこれを呼ぶ。外のパッケージも同じ形を
    /// 作れる — 呼べば入る手軽さは、組み込みだけのものではない。
    ///
    /// ```swift
    /// final class Ticker: Inlet {
    ///     private(set) var count = 0
    ///     func supply() { count += 1 }
    /// }
    ///
    /// extension Sketch {
    ///     func createTicker() -> Ticker {
    ///         let ticker = Ticker()
    ///         attach(ticker)
    ///         return ticker
    ///     }
    /// }
    /// ```
    ///
    /// - 呼んだ時点で ``Inlet/open()`` する。投げたら診断に出して `false` を返す
    ///   ([ADR-0024] 決定 7)
    /// - `setup()` や入力のコールバックの中で足せば、そのフレームの `draw()` の前から
    ///   ``Inlet/supply()`` が呼ばれる。`draw()` の中で足せば、次のフレームから
    /// - 同じものを 2 度足しても 1 つのまま (開き直さない)
    /// - ``Inlet/supply()`` の中から頼んだときは、その巡回が終わってから開いて足す
    ///   (戻り値は `true`。開けなければ診断に出る)
    /// - ``plugins`` で宣言したものと同じ並びに入る。閉じるのは ``detach(_:)-(Inlet)`` か、
    ///   スケッチの終わり
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (中で起こした `Task` を含む) からは
    /// 頼めない。頼んでも足さずに診断に出し、`false` を返す。
    ///
    /// - Returns: 並びに居るか。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    @discardableResult
    public func attach(_ inlet: any Inlet) -> Bool {
        guard let runtime = runningSketch else {
            Diagnostics.warn(OutsideCall.attach.notice)
            return false
        }
        return runtime.attach(inlet)
    }

    /// 出口を、走っているスケッチへ足す。
    ///
    /// 決まりは ``attach(_:)-(Inlet)`` と同じ。**受け取るのは、足したフレームから後に描いた
    /// 絵だけである** — 足す前に描かれた絵は渡さない。
    ///
    /// - Returns: 並びに居るか。
    @discardableResult
    public func attach(_ outlet: any Outlet) -> Bool {
        guard let runtime = runningSketch else {
            Diagnostics.warn(OutsideCall.attach.notice)
            return false
        }
        return runtime.attach(outlet)
    }

    /// 入り口を外して閉じる。
    ///
    /// ``Inlet/close()`` を 1 度だけ呼び、以後 ``Inlet/supply()`` は呼ばれない。並びに
    /// 居なければ何もしない。``Inlet/supply()`` の中から頼んだときは、その巡回が終わって
    /// から外す。
    public func detach(_ inlet: any Inlet) {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.detach.notice)
        }
        runtime.detach(inlet)
    }

    /// 出口を外して閉じる。決まりは ``detach(_:)-(Inlet)`` と同じ。
    public func detach(_ outlet: any Outlet) {
        guard let runtime = runningSketch else {
            return Diagnostics.warn(OutsideCall.detach.notice)
        }
        runtime.detach(outlet)
    }
}
