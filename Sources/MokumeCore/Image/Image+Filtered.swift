// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

extension Image {
    /// 効果の並びを掛けた、新しい絵を返す。**元の絵は変えない。**
    ///
    /// 並びは ``SketchPart/effects(_:)`` と同じ ``Effect`` の値で、`.threshold(level:)` のような組み込みも
    /// ``Effect/custom(_:)`` も掛けられる。**カメラの絵にも掛けられ**、返った絵はカメラの次の 1 枚で
    /// 書き換わらない。
    ///
    /// <!-- example: 文脈 var camera: Capture! -->
    /// ```swift
    /// func setup() throws {
    ///     camera = try createCapture()   // カメラが無ければ、起動の失敗として止まる
    /// }
    ///
    /// func draw() {
    ///     background(0)
    ///     // カメラを 2 値化して影絵にする
    ///     image(camera.image.filtered([.threshold(level: 0.45)]), 0, 0, width, height)
    ///     // 効果の掛からない色の円を、その上に置く
    ///     fill(242, 115, 64)
    ///     circle(mouseX, mouseY, 80)
    /// }
    /// ```
    ///
    /// ## 画素を書き換える口との使い分け
    ///
    /// - ``set(_:_:_:)``・``fill(_:)``・``write(_:)-(DisplayImage)``・``Pixels/update(_:)`` は**自分を変える**命令形
    /// - `filtered(_:)` は**新しい絵を返し**、元を変えない。手本の `PImage.filter()` は自分を変えるので、
    ///   同じ名前で新しい絵を返すと同名異義になる (そのため `filtered`)
    ///
    /// ## 費用
    ///
    /// **呼ぶたびに、GPU で効果を通し、読み戻して、新しい絵を作る。**
    ///
    /// - **読み戻しは、投入済みの描画が全部終わるのを待つ。** GPU の列は順に走るので、この呼び出しの分だけを
    ///   待つことはできない。毎フレームの重い描画の途中で呼ぶと、その終わりまで CPU が止まる。毎フレーム掛ける
    ///   なら、カメラの絵のように小さく変わる絵に、フレームの頭に近い所で 1 回に絞るのが目安で、変わらない絵は
    ///   `setup()` で 1 度掛けて持つほうが安い
    /// - 新しい絵の確保も毎回かかる
    /// - 作業の面と効果の置き場は、大きさが同じ絵どうしで使い回す (走っているスケッチがあれば、スケッチが
    ///   持つ。最近使った 2 つの大きさまで)。新しい絵に続けて掛けても、2 回目からは確保も組み立てもしない
    /// - 効果を通せなかったとき (作業の面を作れない・大きすぎる絵など) は、効果を掛けない ``copy()`` を返し、
    ///   理由を大きさごとに 1 度だけ警告する。数でない値の効果を外したことと、範囲の外の値を締めたことも、
    ///   大きさごとに 1 度だけ言う
    /// - 別の面への投入を GPU が打ち切っても、この呼び出しの分が無事なら効果は掛かる。この呼び出しが拠った
    ///   投入が打ち切られたときは、掛けない写しを返して警告する
    ///
    /// ## 時刻を読む効果
    ///
    /// ``Effect/custom(_:)`` の効果が読む秒は、**走っているスケッチの時刻**である (``SketchPart/time`` と同じ)。
    /// スケッチの外 (走っている実行が無い所) から呼ぶと、秒はいつも 0 になる。
    ///
    /// - Parameter effects: 前から順に掛かる効果の並び。空なら ``copy()`` と同じ絵になる。
    /// - Returns: 大きさが同じ、新しい `Image`。
    // shot: 撮れない 例はカメラの映像を要し、掛けた後の画素は絵ではなく検査で見る
    public func filtered(_ effects: [Effect]) -> Image {
        guard !effects.isEmpty else { return copy() }
        let canvas: Canvas
        do {
            canvas = try workspace()
        } catch {
            gpu.filterWorkspaces.warnUnavailable(
                width: width, height: height,
                "filtered(): could not make a surface to run the effects on for a \(width) x \(height) image: "
                    + "\(error.headline). An image without them was returned")
            return copy()
        }
        do {
            return try applyingEffects(effects, on: canvas)
        } catch {
            canvas.warnOnce(
                .filterFailed,
                "filtered(): could not run the effects: \(error.headline). An image without them was returned")
            return copy()
        }
    }

    /// 作業の面へ絵を置いて効果を通し、読み戻して新しい絵にする。
    ///
    /// 受け口の検め (数でない値を外す・範囲を締める) と段は ``SketchPart/filter(_:)`` と同じ 1 本
    /// (``Canvas/acceptedEffects(_:calledBy:)``・``Canvas/applyFilter(_:)``) を通り、**効果を通せなかった
    /// ことは握りつぶさず投げる** — 掛かっていない絵を成功の道で返さない。
    ///
    /// - **時刻**: 作業の面を、走っているスケッチの時刻の置き場に繋ぐ (``Canvas/borrowSketchState(from:)``・
    ///   `createGraphics` や `draw(into:)` と同じ手順)。繋がないと、作業の面は自分の置き場を持ち、
    ///   時刻を書くのはランタイムだけなので、`.custom` の秒がいつも 0 になる。
    /// - **打ち切りの判定**: 作業の面は使い回すので、前の呼び出しや、同じ GPU の別の面の投入は判定の範囲に
    ///   入れない (``RenderTarget/judgeDroppedWorkFromNow()``)。範囲に入るのはこの呼び出しが積んだ投入だけで、
    ///   スケッチ本体の描画の打ち切りで効果を断らない。待ちそのものは GPU の列の順なので、全部の完了を待つ。
    private func applyingEffects(_ effects: [Effect], on canvas: Canvas) throws(RenderFailure) -> Image {
        let accepted = canvas.acceptedEffects(effects, calledBy: "filtered")
        guard !accepted.isEmpty else { return copy() }
        let release: () -> Void
        if let main = runningSketch?.canvas, main.gpu === gpu {
            release = canvas.borrowSketchState(from: main)
        } else {
            release = {}
        }
        defer { release() }
        canvas.target.judgeDroppedWorkFromNow()
        var failure: RenderFailure?
        try canvas.draw {
            // 使い回す面なので、前の絵を消してから置く (透明の上に置けば、置いた絵がそのまま残る)
            canvas.background(.transparent)
            canvas.image(self, 0, 0)
            do throws(RenderFailure) {
                try canvas.applyFilter(accepted)
            } catch {
                failure = error
            }
        }
        if let failure { throw failure }
        let filtered = try canvas.target.readPixels()
        var pixels: [SIMD4<Float16>] = []
        pixels.reserveCapacity(width * height)
        for index in 0..<(width * height) {
            let base = index * 4
            pixels.append(
                SIMD4(
                    filtered.components[base], filtered.components[base + 1],
                    filtered.components[base + 2], filtered.components[base + 3]))
        }
        return try Image(width: width, height: height, pixels: pixels, gpu: gpu)
    }

    /// 作業の面。**この GPU で、絵と同じ大きさの面を使い回す** (``FilterWorkspaces``)。細かさは 1 で、絵の
    /// 画素と面の画素は 1 対 1 になる。
    ///
    /// 見つける順: 走っているスケッチが持っているもの → 生きている持ち主が居るもの (別の絵が持つ) → 新しく作る。
    /// 見つけたものは、この絵と走っているスケッチが持つ (持ち主が居ないと、掛け終えた面がすぐ手放されて、
    /// 次の呼び出しでまた作ることになる)。
    private func workspace() throws(RenderFailure) -> Canvas {
        let pool = gpu.filterWorkspaces
        let canvas: Canvas
        if let held = filterWorkspace {
            canvas = held
        } else {
            canvas = try pool.workspace(gpu: gpu, width: width, height: height)
        }
        filterWorkspace = canvas
        if let main = runningSketch?.canvas, main.gpu === gpu { main.holdFilterWorkspace(canvas) }
        return canvas
    }
}

/// ``Image/filtered(_:)`` が効果を通す作業の面の置き場。**この GPU 1 つで、絵の大きさごとに 1 面を使い回す。**
///
/// 面を絵 1 枚ごとに持つと、新しい絵に掛けるたびに面一式の確保と効果の組み立てが丸ごと走る
/// (`photo.filtered(a).filtered(b)` や、`camera.image.copy().filtered(…)` を毎フレーム呼ぶと、2 段目以降は
/// 毎回払う)。そこで大きさが同じなら別の絵でも同じ面を使う。
///
/// **ここは弱くしか持たない。** 面 (``Canvas``) は GPU を強く持つので、GPU が面を強く持つと循環して
/// どちらも手放されない。強く持つのは、使っている絵 (``Image``) と、走っているスケッチの面
/// (``Canvas/holdFilterWorkspace(_:)``) である。
///
/// **作れなかった大きさは覚える。** 大きすぎる絵などで作れなかったとき、呼ぶたびに作り直しを試して失敗する
/// 費用を払わない。覚えた大きさは、同じ失敗を返し、警告も大きさごとに 1 度だけ言う。
@MainActor final class FilterWorkspaces {
    struct Size: Hashable {
        let width: Int
        let height: Int
    }

    private struct Entry {
        weak var canvas: Canvas?
    }

    private var entries: [Size: Entry] = [:]
    /// 作れなかった大きさと、その理由。
    private var failures: [Size: RenderFailure] = [:]
    /// 作れなかったことを言った大きさ。
    private var warned: Set<Size> = []
    /// 面を作った回数。**使い回していること**を検査が数で見る。
    private(set) var made = 0
    /// 検査の差し込み: 次に作る面を、この理由で失敗させる (大きすぎる絵など、作れない状況を作らずに起こす)。
    var failsNextMakeForTesting: RenderFailure?

    /// 大きさに合う面。生きているものを使い、無ければ作る。
    func workspace(gpu: RenderDevice, width: Int, height: Int) throws(RenderFailure) -> Canvas {
        let size = Size(width: width, height: height)
        if let failure = failures[size] { throw failure }
        if let canvas = entries[size]?.canvas { return canvas }
        entries = entries.filter { $0.value.canvas != nil }
        do throws(RenderFailure) {
            if let injected = failsNextMakeForTesting {
                failsNextMakeForTesting = nil
                throw injected
            }
            let made = try Canvas(
                target: RenderTarget(gpu: gpu, width: width, height: height), gpu: gpu)
            self.made += 1
            entries[size] = Entry(canvas: made)
            return made
        } catch {
            failures[size] = error
            throw error
        }
    }

    /// 面を作れなかったことを、大きさごとに 1 度だけ言う。
    func warnUnavailable(width: Int, height: Int, _ message: String) {
        guard warned.insert(Size(width: width, height: height)).inserted else { return }
        Diagnostics.warn(message)
    }
}

extension Canvas {
    /// 走っているスケッチの面が持つ作業の面の数。大きさの違う絵に掛けても、使った分が全部残らないための上限。
    static let filterWorkspaceLimit = 2

    /// ``Image/filtered(_:)`` の作業の面を、この面の寿命のあいだ持つ。**最近使った ``filterWorkspaceLimit`` 面まで**
    /// で、古いものから手放す (面は絵と同じ大きさの面が数枚なので、大きさの違う絵に掛けるたびに残らないように)。
    func holdFilterWorkspace(_ workspace: Canvas) {
        filterWorkspaces.removeAll { $0 === workspace }
        filterWorkspaces.insert(workspace, at: 0)
        if filterWorkspaces.count > Self.filterWorkspaceLimit {
            filterWorkspaces.removeLast(filterWorkspaces.count - Self.filterWorkspaceLimit)
        }
    }
}
