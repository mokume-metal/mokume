// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 書き出しの動画の音声トラックへ載せる、音の 1 窓 (1 フレームぶんの標本)。
///
/// 窓はフレームの番号から決まる。**フレーム `N` は標本 `[⌊N·sr/fps⌋, ⌊(N+1)·sr/fps⌋)`** で、原点は固定の時計の
/// フレーム 0 の頭 (標本 0)。窓の長さを丸めて足さないので、`sr` が `fps` の倍数でないとき (48000 Hz・144 fps) は
/// 窓ごとの長さが 1 標本ずつ違うだけで、継ぎ目に欠けも重なりも無い ([ADR-0042] 決定 6 の改訂)。
///
/// ``SoundSource`` が、渡された窓へ自分の音を**足す**。Core はすべての音源が足した和を音声トラックへ書く。
///
/// ```swift
/// final class Tone: Inlet, SoundSource {
///     private var phase: Float = 0
///     func supply() {}
///     func mix(into window: inout SoundWindow) {
///         for index in 0..<window.count {
///             let sample = 0.2 * sin(phase)
///             window.left[index] += sample
///             window.right[index] += sample
///             phase += 2 * .pi * 440 / Float(SoundWindow.sampleRate)
///         }
///     }
/// }
/// ```
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
public nonisolated struct SoundWindow: Sendable, Equatable {
    /// 音の流れの標本化率 (Hz)。書き出しの音声トラックはこの率で書く。
    public static let sampleRate = 48_000

    /// フレームの番号 (固定の時計のフレーム 0 が 0)。
    public let frame: Int
    /// 窓の先頭の標本の番号 (`⌊frame·sampleRate/fps⌋`)。
    public let start: Int
    /// 左の標本 (-1〜1 が全振幅)。最初は全部 0。音源が足す。
    public var left: [Float]
    /// 右の標本。最初は全部 0。音源が足す。
    public var right: [Float]

    /// 窓の長さ (標本)。
    public var count: Int { left.count }

    /// 無音の窓を作る。
    public init(frame: Int, start: Int, count: Int) {
        self.frame = frame
        self.start = start
        left = [Float](repeating: 0, count: count)
        right = [Float](repeating: 0, count: count)
    }

    /// フレーム `frame` の窓の先頭の標本の番号 `⌊frame·sampleRate/frameRate⌋`。絶対のフレーム番号から直に求める。
    public static func start(ofFrame frame: Int, frameRate: Int) -> Int {
        Int((Double(frame) * Double(sampleRate) / Double(max(1, frameRate))).rounded(.down))
    }

    /// フレーム `frame` の窓の長さ (標本)。`⌊(frame+1)·sampleRate/frameRate⌋ − ⌊frame·sampleRate/frameRate⌋`。
    public static func count(ofFrame frame: Int, frameRate: Int) -> Int {
        start(ofFrame: frame + 1, frameRate: frameRate) - start(ofFrame: frame, frameRate: frameRate)
    }

    /// フレーム `frame` の無音の窓。
    public init(frame: Int, frameRate: Int) {
        self.init(
            frame: frame, start: Self.start(ofFrame: frame, frameRate: frameRate),
            count: Self.count(ofFrame: frame, frameRate: frameRate))
    }
}

/// 音を出す入り口の印 — 書き出しの動画の音声トラックへ、音を窓ごとに載せる差込口。
///
/// 音の流れ (再生・合成・エフェクトを通した音) を持つ入り口 (``Inlet``) が、``Inlet`` に加えて準拠する。
/// **組み込みの音の入り口も外のパッケージの音源も、同じこの口を通る** ([ADR-0024] 決定 10)。``Inlet`` を
/// 継がない独立の protocol なのは、``Inlet`` の準拠が既定でメインアクターに隔離されるので、継ぐと準拠の隔離が
/// 食い違うため (Swift 6.3 で「隔離された準拠に依る」と断られる)。
///
/// ## 載せる条件と時刻
///
/// 固定の時計 (``Clock/frameIndex(frameRate:)``) で、画面へ出さずに `.mov` を録り始めたとき、
/// **録りを頼まれたフレームの `draw()` が終わった時点**で、スケッチに ``SoundSource`` の入り口が居れば音声トラックが
/// 付く (居なければ付かない)。付いたら、毎フレーム `draw()` が終わった後・次のフレームの供給の前に、
/// そのフレームの窓 (``SoundWindow``) をすべての音源に足させて書く。**フレーム `N` の `draw()` が頼んだ操作は
/// 窓 `N` の先頭から効く**。録りの途中で足された音源は、トラックがあれば載る。トラックが無いときは載せず、
/// そのことを 1 度だけ診断に出す。
///
/// 載せない録り (実時間の時計・画面へ出す録り・MP4・GIF・連番) で音源が居れば、載せないことを 1 度だけ診断に出す。
/// 動画の書き損じと同じく、音声の書き損じも `mokume render` の終了コードに現れる。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
public protocol SoundSource: AnyObject {
    /// 音声トラックが始まる。最初の窓 (``SoundWindow/frame``) の直前に 1 度呼ばれる。録りの途中で足された
    /// 音源には、足された直後に呼ばれる。`frameRate` は録りの fps。
    func beginTrack(frameRate: Int)

    /// 窓へ、自分の音を足す。**窓の外の標本を足さない**。毎フレーム 1 度、窓の番号の順に呼ばれる。
    func mix(into window: inout SoundWindow)

    /// 録りが終わった。以後、窓は来ない。
    func endTrack()
}

extension SoundSource {
    public func beginTrack(frameRate: Int) {}
    public func endTrack() {}
}
