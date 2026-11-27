// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 1 回の実行 (``SketchRuntime``) の終わり。実行が開いた入り口 (``RunBoundInlet``) が強く持ち、実行が終わったか
/// を読む (#4175)。
///
/// - **実体でなく実行に結ぶ。** 同じスケッチの実体を新しい実行で走らせても、前の実行の終わりは戻らない
/// - **実行の後片付けが、差込口を閉じ始める前に印を立てる** (``SketchRuntime/closePlugins(_:)``)。閉じている最中に
///   呼ばれた操作も、終わった後のものとして扱える
/// - **実行は弱く持ち、実行が消えていれば終わったとする。** 後片付けを通らずに手放された実行へも、もう足し直せない
package final class RunEnd {
    private weak var runtime: SketchRuntime?
    private var marked = false
    private var notified = false
    /// この実行が開いた入り口。弱く持つ (入り口を生かし続けない)。
    private var bound: [WeakInlet] = []

    private struct WeakInlet {
        weak var inlet: (any RunBoundInlet)?
    }

    init(_ runtime: SketchRuntime) {
        self.runtime = runtime
    }

    /// 実行が終わったか (後片付けを始めた・実行が消えた)。終わった実行へは、入り口を足し直せない。
    package var hasEnded: Bool { marked || runtime == nil }

    /// 実行が開いた入り口を控え、この実行に結ぶ。
    func bind(_ inlet: any RunBoundInlet) {
        bound.removeAll { $0.inlet == nil || $0.inlet === inlet }
        bound.append(WeakInlet(inlet: inlet))
        inlet.bind(to: self)
    }

    /// 後片付けを始めた。以後 ``hasEnded`` は `true`。
    func mark() {
        marked = true
    }

    /// 並びの入り口を閉じ終えた後に、結んだ入り口へ終わったことを伝える (1 度だけ)。並びから外れていて終わりの
    /// `close()` を受けなかった入り口も、ここで知る。
    func notify() {
        mark()
        guard !notified else { return }
        notified = true
        let inlets = bound.compactMap(\.inlet)
        bound.removeAll()
        for inlet in inlets { inlet.runEnded(self) }
    }
}

/// 自分を開いた実行が終わったことを知る入り口 (package)。実行は入り口を開くたびに ``bind(to:)`` で結び直し、
/// 後片付けで並びの入り口を閉じ終えた後に ``runEnded(_:)`` を呼ぶ。
///
/// ``Inlet`` を継がないのは、``Inlet`` への main actor に隔離された適合に重ねると、下限の Swift が適合を拒むため。
/// 実行は開いた ``Inlet`` をこの型へ動的に絞って結ぶ。
package protocol RunBoundInlet: AnyObject {
    /// `run` に開かれた。前に結んだ実行より、こちらが新しい。
    func bind(to run: RunEnd)
    /// `run` が終わった。いま結んでいる実行でなければ何もしない。
    func runEnded(_ run: RunEnd)
}
