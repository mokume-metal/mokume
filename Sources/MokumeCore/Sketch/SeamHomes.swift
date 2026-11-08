// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 入り口・出口を足した実行を、差込口ごとに**弱く**控える ([#2840])。
///
/// 止める口 (`AudioIn.stop()` など) と公開の ``SketchPart/detach(_:)-(Inlet)`` は、外す先の実行を
/// ``runningSketch`` で引く。だが ``runningSketch`` は `setup()`・`draw()`・入力のコールバックが返ると外れる
/// ので、中で起こした `Task` の続き (フレームの間に走る) からは引けず、機材が動いたまま断っていた。
/// 足した実行を控えておけば、**走っている実行が在る限り**、`Task` の中からも外せる。
///
/// - **弱く持つ。** 実行を強く持たせると、差込口が実行を生かし続ける。差込口も弱く持ち、使い回された
///   識別子を別の差込口の控えと取り違えない。
/// - **外れた・閉じた差込口は忘れる。** 実行の後片付けの後は、並びも空なので、止める口は今までどおり
///   名乗るだけになる (走っていない実行へは頼まない)。
/// - ``LaunchingSketch`` に実行は持たせない。あちらが持ち越すのは面だけで、描く口を `Task` から効かせない
///   理由 ([ADR-0010]) を崩さないためである。ここが効かせるのは、実行から差込口を外すことだけ。
///
/// [#2840]: https://github.com/mokume-metal/mokume/issues/2840
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
enum SeamHomes {
    private struct Home {
        weak var seam: AnyObject?
        weak var runtime: SketchRuntime?
    }

    private static var homes: [ObjectIdentifier: Home] = [:]

    /// `seam` を足した実行を控える。
    static func record(_ seam: AnyObject, in runtime: SketchRuntime) {
        // 持ち主の消えた控えを、足すたびに掃く (数は差込口の数だけで小さい)
        homes = homes.filter { $0.value.seam != nil && $0.value.runtime != nil }
        homes[ObjectIdentifier(seam)] = Home(seam: seam, runtime: runtime)
    }

    /// `seam` を足した実行。足されていない・外れた・実行が後片付けを終えた・消えた、なら `nil`。
    static func runtime(of seam: AnyObject) -> SketchRuntime? {
        guard let home = homes[ObjectIdentifier(seam)], home.seam === seam else { return nil }
        return home.runtime
    }

    /// 外れた差込口を忘れる。
    static func forget(_ seam: AnyObject) {
        homes[ObjectIdentifier(seam)] = nil
    }

    /// 実行の後片付けで、その実行が足した差込口を全部忘れる。
    static func forgetAll(in runtime: SketchRuntime) {
        homes = homes.filter { $0.value.runtime !== runtime }
    }
}

/// スケッチの実体ごとに、それを走らせている実行を**弱く**控える ([#3847])。
///
/// ホストのコード (``SketchView`` の隣のボタンの処理) は、実行の差し込み (``SketchRuntime/withActiveRuntime(_:)``)
/// の外で走る。そこから実体のメソッドを呼んで ``SketchPart/width`` を読むと、差している実行が無いので 0 になった。
/// 実体から実行を引ければ、映しているスケッチが 1 つでも複数でも、そのメソッドは自分の実行を読む
/// (``activeRun(for:from:)``)。
///
/// - 形は ``SeamHomes`` と同じで、実体も実行も弱く持つ。控えが実行や実体を生かし続けない
/// - 結ぶのは実行を作ったとき、忘れるのは実行の後片付け (``SketchRuntime/closePlugins()``)。止まった実行の実体は、
///   他の実行を拾わない
///
/// [#3847]: https://github.com/mokume-metal/mokume/issues/3847
enum SketchHomes {
    private struct Home {
        weak var sketch: AnyObject?
        weak var runtime: SketchRuntime?
    }

    private static var homes: [ObjectIdentifier: Home] = [:]

    /// `sketch` を走らせる実行を控える。
    static func record(_ sketch: any Sketch, in runtime: SketchRuntime) {
        // 持ち主の消えた控えを、結ぶたびに掃く (数は作った実行の数だけで小さい)
        homes = homes.filter { $0.value.sketch != nil && $0.value.runtime != nil }
        homes[ObjectIdentifier(sketch)] = Home(sketch: sketch, runtime: runtime)
    }

    /// `sketch` を走らせている実行。結ばれていない・後片付けを終えた・消えた、なら `nil`。
    static func runtime(of sketch: any Sketch) -> SketchRuntime? {
        guard let home = homes[ObjectIdentifier(sketch)], home.sketch === sketch else { return nil }
        return home.runtime
    }

    /// 実行の後片付けで、その実行の結びを忘れる。
    static func forget(_ runtime: SketchRuntime) {
        homes = homes.filter { $0.value.runtime !== runtime }
    }
}
