// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeCore

/// スケッチを窓を出さずに走らせる口。**`import MokumeHost` で使う。**
///
/// 道具・外のパッケージ・検査が、スケッチを 1 フレームずつ進め、描いた絵を値で読み、入力を注入するための
/// 入口である (ADR-0048 決定 3)。スケッチを書く人は使わない — 窓で走らせるなら `Game.main()`
/// (``Sketch/main()``) を、SwiftUI に埋め込むなら `MokumeUI` の `SketchView` を使う。
///
/// **後始末は口が持つ。** ``with(_:gpu:_:)`` は抜けるときに、``init(_:gpu:)`` で作った実行は参照が
/// 無くなったときに、差込口 (``Sketch/plugins``) を閉じる。利用者が閉じる呼び出しを書く必要は無い。
///
/// <!-- example: 組めない import MokumeHost の例で、全部の例を import mokume の 1 ファイルへ束ねて組む検査には入らない。同じ形は Tests/MokumeHostTests/HostOnlyFile.swift が組む -->
/// ```swift
/// import MokumeHost
///
/// try HeadlessRun.with(Game()) { run in
///     try run.advance(frames: 10)
///     run.send(.keyDown(code: .space, characters: " ", isRepeat: false))
///     try run.advance()
///     let pixels = try run.readPixels()     // 作業空間の値 (線形・アルファ乗算済み)
///     try run.writePNG(to: URL(fileURLWithPath: "frame.png"))
///     print(run.frameCount, run.time, pixels.width)
/// }   // ここで差込口が閉じる
/// ```
///
/// `Game` は別のファイルに `import mokume` して書く。
///
/// ## 時刻
///
/// 時刻はスケッチの設定のフレームレート (``SketchSettings/frameRate``) で刻む**再現する時計**で進む。
/// 1 回の ``advance(frames:)`` が何秒かかっても、1 フレームは `1 / frameRate` 秒である。だから同じスケッチを
/// 同じ回数だけ進めれば、同じ絵になる。
///
/// ## 閉じた後
///
/// 閉じた後も、進める・読むはそのまま使える。差込口が外れたまま描き続けるだけである。``with(_:gpu:_:)`` の
/// 外へ `run` を持ち出すと、差込口の無い実行を持ち続けることになるので、持ち続けたいなら
/// ``init(_:gpu:)`` で作る。
@MainActor
public final class HeadlessRun {
    private let runtime: SketchRuntime
    /// 差込口をもう閉じたか。`with` が閉じた後に参照が消えても、2 度は閉じない。
    private var isClosed = false

    /// スケッチを窓なしで組み立てる。参照が無くなったら差込口を閉じる。
    ///
    /// スケッチのプロパティに持ち続け、フレームごとに 1 枚ずつ進める使い方のための口である。範囲の中だけで
    /// 使うなら ``with(_:gpu:_:)`` を使う — 最適化は、最後に使った後の参照を範囲の終わりより早く手放しうる
    /// ので、差込口が範囲の終わりまで開いている保証が要るなら `with` で書く。
    ///
    /// - Parameters:
    ///   - sketch: 走らせるスケッチ。
    ///   - gpu: 描画の土台。省くとこの実行のために作る。多くの実行を続けて組むなら、1 つを作って渡し回す。
    /// - Throws: 組み立てられなかったとき (GPU が無い・設定が不正 など)。
    public init(_ sketch: some Sketch, gpu: RenderDevice? = nil) throws(RenderFailure) {
        let device: RenderDevice
        if let gpu { device = gpu } else { device = try RenderDevice() }
        runtime = try SketchRuntime(sketch: sketch, gpu: device)
    }

    isolated deinit {
        close()
    }

    /// スケッチを窓なしで走らせ、`body` を抜けたら差込口を閉じる。
    ///
    /// `body` が投げて抜けても閉じる。`body` が返した値をそのまま返す。
    ///
    /// - Parameters:
    ///   - sketch: 走らせるスケッチ。
    ///   - gpu: 描画の土台。省くとこの実行のために作る。
    ///   - body: 実行を受け取って進める・読む処理。
    /// - Returns: `body` が返した値。
    /// - Throws: 組み立てられなかったときの ``RenderFailure``、または `body` が投げたもの。
    public static func with<Result>(
        _ sketch: some Sketch, gpu: RenderDevice? = nil, _ body: (HeadlessRun) throws -> Result
    ) throws -> Result {
        let run = try HeadlessRun(sketch, gpu: gpu)
        defer { run.close() }
        return try body(run)
    }

    /// フレームを `frames` 枚進める。
    ///
    /// 1 枚ごとに、溜めた入力 (``send(_:)``) を当ててから ``Sketch/draw()`` を呼び、絵を仕上げる。
    /// 途中の枚で描けなかったら、そこで止めて投げる。
    ///
    /// - Parameter frames: 進める枚数。0 以下なら何もしない。
    /// - Throws: 描けなかったとき。
    public func advance(frames: Int = 1) throws(RenderFailure) {
        guard frames > 0 else { return }
        for _ in 0..<frames { try runtime.advance() }
    }

    /// 入力の出来事を 1 つ注入する。次に進めるフレームの頭で、窓で受けたのと同じ道で当たる。
    ///
    /// - Parameter event: 当てる出来事。
    public func send(_ event: InputEvent) {
        runtime.input.enqueue(event)
    }

    /// いまの絵を、作業空間の値のまま読む。
    ///
    /// 値は線形・アルファ乗算済みで、表示できる範囲を超えた明るさもそのまま入っている (``PixelBuffer``)。
    /// 表示に変換した値が要るなら ``displayImage(scale:)`` を使う。
    ///
    /// - Throws: GPU が絵を仕上げなかったとき。
    public func readPixels() throws(RenderFailure) -> PixelBuffer {
        try runtime.target.readPixels()
    }

    /// いまの絵を、表示に変換した値で読む。PNG に書くのと同じバイト列である。
    ///
    /// - Parameter scale: 縮小率 (1 = 実寸)。1 以上または 0 以下は実寸として扱う。
    /// - Throws: GPU が絵を仕上げなかったとき。
    public func displayImage(scale: Double = 1) throws(RenderFailure) -> DisplayImage {
        try runtime.target.encodeForDisplay(scale: scale)
    }

    /// いまの絵を PNG として書き出す。**書き込みが終わってから返る。**
    ///
    /// - Parameter url: 書き出す先。
    /// - Throws: GPU が絵を仕上げなかったとき、または書けなかったとき。
    public func writePNG(to url: URL) throws {
        try runtime.target.writePNG(to: url)
    }

    /// これまでに描いたフレームの数。
    public var frameCount: Int { runtime.frameCount }
    /// いまのフレームの時刻 (秒)。
    public var time: Float { runtime.time }
    /// 前のフレームからの経過 (秒)。
    public var deltaTime: Float { runtime.deltaTime }

    /// 差込口を閉じる。2 度目からは何もしない。
    private func close() {
        guard !isClosed else { return }
        isClosed = true
        runtime.closePlugins()
    }
}
