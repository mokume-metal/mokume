// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Accelerate
import AVFoundation
import Foundation
import MokumeDiagnostics
import VideoToolbox

/// 動きをファイルへ書き出すときに起こりうる失敗。
enum MovieWriteFailure: Error, Equatable {
    /// この機械に符号化器が無い。
    case encoderUnavailable
    /// 書き出し先を開けない。
    case destinationUnavailable(path: String)
    /// 画素の器を借りられない。
    case bufferUnavailable
    /// 書き込みに失敗した。
    case writeFailed(path: String, reason: String)
}

/// 動画を 1 本書く。**MokumeCore で AVFoundation に触れる唯一の場所である** (カメラの
/// 受け取りは本体の上に載る `MokumeCamera` が持つ — [ADR-0042] 決定 3)。
///
/// ## 隔離の外に置く
///
/// 静止画の ``PNGFile`` と同じ姿勢で、符号化はフレームの外で走らせる
/// ([ADR-0010] 決定 4)。触るのは ``MovieWriter`` が持つ 1 本の仕事だけなので、
/// この型自身は錠を持たない。
///
/// ## 形式は選べない
///
/// ProRes 4444 の .mov で固定する。**符号化の選び方が、書き出した動きが再現するか
/// どうかを決めるからである** ([ADR-0025] 決定 3)。同じ入力を 2 回書き出して測ると、
/// H.264 は画素が一致せず、HEVC は run によって外れ、ProRes 4444 はデコードした画素と
/// 時刻が一致した ([ADR-0025] の水準 3)。**一致するのは中身で、ファイルそのものではない** —
/// 容れ物 (`mvhd`・`tkhd`・`mdhd`) の作成・更新時刻には AVFoundation が書き出した時刻の秒を
/// 入れるので、違う秒に書いた 2 本はファイルとしては一致しない ([#1628])。配布向けの軽い
/// 符号化は「再現を捨てて小さくする」選択なので、要る場面が出てから足す ([ADR-0008])。
///
/// **符号化器は、専用回路を使わない側を選ぶ** ([#1813])。ProRes 4444 を専用回路の符号化器
/// (`appleproreshw.4444`。指定しなければこちらが選ばれる) で符号化させると、**色が細かく乱れた絵に
/// 一様でない不透明度が重なったとき、640×360 以上で `Cannot Encode` と断られ、断られた書き手は
/// 立ち直らないので録り全体が失われる**。色が一色・滑らかな絵は、不透明度が乱数でも通る。
/// `AlphaChannelMode` を替えても、専用回路を必須にしても、ProRes 4444 XQ にしても避けられず、
/// 専用回路を使わない符号化器 (`prores-4444`) だけが通った。形式は変わらず、決めているのは形式で、
/// どの符号化器で書くかではない ([ADR-0025] 決定 3)。
///
/// **不透明度と水準 3 は、測った範囲で変わらない。** 断られた 4 絵柄 × 640×360 / 641×361 / 1920×1080 で、
/// 復号した不透明度は入力と一致し、同じ入力を 2 回書くと復号した画素と時刻が全画素で一致した。
/// 色が乱れた絵に不透明度が重なる別の絵では、半透明の画素の色が乗算されずに残った (塊の内側で
/// 入力との差は最大 1・`MovieWriterTests`)。専用回路を使わない符号化器は複数のスレッドで並列に
/// 符号化するので、測っていない大きさ・絵柄では言わない。
///
/// **代償は、符号化に使う CPU である。** 符号化は別のプロセス (`VTEncoderXPCService`) が行うので、
/// このプロセスの CPU 時間には現れない。40 枚を初期化から `finish` まで書いた CPU 時間
/// (このプロセス + 符号化のプロセス・ms)。release・3 ラウンドの中央値で、専用回路 → 使わない。
/// 2 つのテストを 1 本ずつ走らせた値である:
///
/// | | 大きさ | 一色 | 勾配 + 不透明度が乱数 | RGB が乱数 + 不透明度 255 |
/// | --- | --- | --- | --- | --- |
/// | M3 Max (16 コア) | 1920×1080 | 46 → 307 | 110 → 720 | 73 → 1621 |
/// | | 3840×2160 | 429 → 1569 | 652 → 3061 | 466 → 7071 |
/// | 無印 M4 (10 コア) | 1920×1080 | 127 → 304 | 170 → 743 | 124 → 1806 |
/// | | 3840×2160 | 691 → 1732 | 971 → 3404 | 704 → 7832 |
///
/// **絵と大きさによって 2〜22 倍になる** (1920×1080 以上。RGB が乱数の絵が最も大きく、1920×1080 で
/// M3 Max 約 22 倍・M4 約 15 倍)。640×360 は 0.2〜3 倍で、M4 の一色では減る。壁時間は、一色と勾配では
/// 同じか短く、RGB が乱数の絵では 1.2〜3 倍に伸びた (3840×2160 で M3 Max 258 → 550 ms・M4 286 → 862 ms)。
/// 60 fps の実時間で送ると、1920×1080 は 3 つの絵とも両機で遅れず、3840×2160 の RGB が乱数の絵だけが
/// M4 で追いつけない (3 秒ぶんを送る間に約 0.55 秒遅れ、``MovieWriter/write(_:frame:time:)`` の待ちが
/// 約 30 ms)。この絵は 1 枚あたりの所要が 60 fps の枠 (16.7 ms) を挟む位置にある (40 枚の壁時間 ÷ 40:
/// M4 約 21.6 ms・M3 Max 約 13.8 ms)。M3 Max は今回は遅れなかったが、前に測った回 (約 20.8 ms) は
/// 0.2〜0.8 秒遅れたので、機械の負荷で結果が変わりうる。
///
/// **測っていない機種がある。** 無印 M4 までは測った。M1〜M3 の無印 (コア 8) は実機が無く未測で、
/// 3840×2160 の色の細かい絵は M4 より遅れる見込みである。M1 無印は専用回路が無いとされ、指定は効かず、
/// この不具合も出ない見込みだが、これも未測である。電力も測っていない。
///
/// **固定の約束ではなく、測った回避策である。** 指定は ``encoderSpecification()`` の 1 か所だけで、
/// Apple 側が直ったら外して戻せる。戻して検査 (`MovieWriterTests` の「色の細かい絵に…」) が赤に
/// ならなければ、直っている。そのとき `theMovieIsNotWrittenByTheHardwareEncoder` (書き上がりが
/// 専用回路のものでないことを見る) は赤になるので外す。
///
/// **指定が効くと測ったのは、専用回路のある 2 台である** (M3 Max・無印の Mac mini M4。指定なしで
/// `Cannot Encode`、指定ありで緑)。GitHub のホストの VM (`macos-26-arm64`) では、指定の有無によらず
/// 色の細かい絵が別のエラー (`NSOSStatusErrorDomain -17913`。run ごとに落ちるセルが違う) で落ちる
/// ので、ここでは指定が効いたかを見られない。断られていた絵を書く検査は、既定の符号化器が
/// 専用回路である (仮想化されていない) 機械でだけ走らせ、ほかでは飛ばす (`DefaultProResEncoder`)。
/// 機械によらず動いて赤になれるのは、書き手へ指定を渡したことを見る
/// `theWriterIsHandedTheEncoderSpecification` だけである。
///
/// ## 符号化器の用意は、読み直して待つ
///
/// `append(_:at:)` は `isReadyForMoreMediaData` が立つまで待つ。**この待ちは外せない** —
/// 用意できていない入力へ書き足すと、AVFoundation は例外を投げる。``Backpressure`` とは
/// 役目が違い、あちらはこの待ちを頼む側 (フレームループ) まで伝える段である
/// (``MovieWriter`` の「待ち方」)。
///
/// **待ち方は、1ms ごとに読み直す形を選んでいる。** 毎回状態を読み直すので、合図を
/// 取りこぼしようがない。待ちに入るのは 1 本あたりたいてい 0〜2 回、多くて数十回で、
/// 費用は無視できる ([#979] の実測)。合図で待つ 2 つの形は採らない:
///
/// - **`PixelBufferReceiver.append(_:with:) async`** — 非推奨の案内が指す先だが、入力が
///   受け取れる状態のまま戻らないことがある (macOS 26.6 で、256×192・120 枚の書き出しの
///   約 9%)。ここで止まると枠が返らず、上限に達したところで main actor が塞がって
///   **撮影中に窓ごと固まる**
/// - **KVO で変化を待つ** — 通知を 1 度取りこぼせば、同じく永久に待つ。取りこぼしが無いと
///   言えるだけの回数を測れていない
///
/// 受け手の API へ移る日のために: 受け手を作った時点で、入力は writer に加わっている。
/// `add(_:)` を重ねると入力が 2 本と数えられ、来ない 2 本目を待って動画の 1 秒ほどで止まる。
///
/// ## 止まった writer は待たない
///
/// **待つ前と待つ間に `writer.status` を読み、`.writing` でなくなったら writer 自身の理由で
/// 書き損じにする。** 止まった writer へはもう書けないので、用意を待つ意味が無い。
///
/// 用意のフラグに任せない理由は 2 つある ([#1299] の実測・macOS 27.0):
///
/// - **理由が落ちる。** 転んだ writer は用意を `true` に戻すが、画素の器を手放す。フラグだけを
///   見て器を借りに行くと「器を借りられない」(`bufferUnavailable`) で決着し、ディスクが埋まった
///   (`Disk Full`) のような本当の理由が消える。差込口を外すときに名乗るのは最後に決着した枚の
///   理由なので、利用者には `bufferUnavailable` しか届かなかった
/// - **フラグが戻ることは約束されていない。** 27.0 では時刻が戻る 1 枚でもディスクが埋まる
///   入り方でも戻ったが、26 では測っていない。戻らなければ待ちが永久に回り、枠が返らずに
///   上限のところで main actor が塞がる。`status` で抜ければ、どちらでも同じに終わる
///
/// **確かめた後に転ぶ枚も同じである** ([#2944])。`.writing` と確かめてから器の池を取るまでの間に writer が
/// 転ぶと、池は `nil` になり器も借りられない。取れなかった後にもう一度状態を読み、`.writing` でなければ
/// `bufferUnavailable` ではなく writer の理由で書き損じにする。
///
/// `.writing` のまま用意が永久に戻らない場合は覆わない。測られた例が無い ([#979] の測定では
/// 待ちに入るのはたいてい 0〜2 回) ので、実害が出てから足す ([ADR-0008])。
///
/// [#979]: https://github.com/mokume-metal/mokume/issues/979
/// [#1299]: https://github.com/mokume-metal/mokume/issues/1299
/// [#2944]: https://github.com/mokume-metal/mokume/issues/2944
/// [#1628]: https://github.com/mokume-metal/mokume/issues/1628
/// [#1813]: https://github.com/mokume-metal/mokume/issues/1813
/// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated final class MovieFile: MovieOutput {
    /// 書く動画の形。**元にする形 (ProRes 4444) と、配る形 (H.264 の MP4) の 2 つだけ** ([#2440])。
    ///
    /// ProRes 4444 の `.mov` が元である ([ADR-0025] 決定 3 — 水準 3 を名乗れる唯一の形)。H.264 の MP4 は
    /// **配る形**で、同じ引数から書いても画素が一致するとは約束しない。再生環境が広く軽いが、符号化は
    /// 損失があり、透けは書かず (H.264 に無い)、色は sRGB へ写してから書く (``DistributionColor``)。
    ///
    /// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
    /// [ADR-0025]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0025-determinism-levels.md
    enum Format: Equatable {
        /// ProRes 4444 の `.mov`。元にする形。
        case proRes4444
        /// H.264 の MP4。配る形。
        case h264
    }

    /// 時刻の刻み。24 / 25 / 30 / 50 / 60 のどれで割っても整数になる値を選ぶ —
    /// 端数が出ると、フレームの時刻が刻みへ丸められるたびに少しずつずれる。
    ///
    /// **入力と容れ物の両方へ渡す** ([#2307])。`CMTime` をこの刻みで作るだけでは、AVFoundation は
    /// トラックも容れ物も既定の 600 で書く。600 を割り切らない fps (48・90 など) では 1 枚の長さが
    /// 揃わず、600 を越える fps では隣のフレームが同じ時刻へ丸まった。この刻みを越える fps は、
    /// 撮る係が撮り始める前に断る (``FrameRecorder/movieFrameRateLimit``)。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    static let timescale: CMTimeScale = 90_000

    private let path: String
    private let format: Format
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    /// 音声トラックの入力 ([#3125])。音を載せない録りでは `nil` (入力を作らず、映像のバイトも変わらない)。
    ///
    /// [#3125]: https://github.com/mokume-metal/mokume/issues/3125
    private let soundInput: AVAssetWriterInput?
    /// 最初の窓の先頭の時刻。区間の始まりは、これと最初の映像の時刻の早いほう。
    private let soundStart: CMTime?
    private let frameDuration: Double
    /// 最初の 1 枚を受け取ったか。**区間の始まりは最初のフレームの時刻**で、
    /// 0 ではない — 途中から撮り始めた動画の頭に、何も無い時間を作らないため。
    private(set) var hasStarted = false

    /// ``append(_:at:)`` と ``finish(lastFrameAt:)`` が writer の状態・画素の器の池・失敗の理由を読む所への
    /// 差込口。**検査だけが使う** ([#2944])。
    ///
    /// 確かめた直後に writer が転ぶ形は、本物の writer では決まった所に作れない (転ぶのは符号化器の
    /// 側で、いつ起きるかは負荷しだい)。だから**読む所だけ**を差し替えられるようにして、「状態を読んだ
    /// 後、池を取る前に転ぶ」を決定的に作る。空のままなら本物の writer と adaptor を読む。
    ///
    /// **差し替えは `finish` の失敗の理由にも効く** (理由を読む口は 1 つ — `failureReason`)。
    /// 差し替えるのは書き足す所と理由だけで、`finish` が呼ぶ AVFoundation (`markAsFinished` など) の
    /// 状態は本物のままである。
    ///
    /// [#2944]: https://github.com/mokume-metal/mokume/issues/2944
    struct ReadsForTesting {
        /// `writer.status` の代わり。
        var status: (() -> AVAssetWriter.Status)?
        /// `adaptor.pixelBufferPool` の代わり。
        var pool: (() -> CVPixelBufferPool?)?
        /// 池から器を 1 つ借りる手の代わり (`nil` は借りられなかった)。
        var borrow: ((CVPixelBufferPool) -> CVPixelBuffer?)?
        /// `writer.error` の代わり。言った失敗の理由 (`nil` は何も言っていない)。
        var error: (() -> String?)?
        /// 器の先頭の番地を取る手の代わり (`nil` は取れなかった)。取る間は器をロックしている。
        var baseAddress: ((CVPixelBuffer) -> UnsafeMutableRawPointer?)?
        /// 器を writer へ渡す手の代わり (`false` は writer が断った)。検査が、渡さなかったことを数える。
        var appendBuffer: ((CVPixelBuffer, CMTime) -> Bool)?
    }

    /// 検査が差し込む読み方。空なら本物を読む。
    var readsForTesting = ReadsForTesting()

    private var writerStatus: AVAssetWriter.Status { readsForTesting.status?() ?? writer.status }

    private var pixelBufferPool: CVPixelBufferPool? {
        if let pool = readsForTesting.pool { return pool() }
        return adaptor.pixelBufferPool
    }

    /// writer が言った失敗の理由。言っていなければ `nil`。
    private var writerError: String? {
        if let error = readsForTesting.error { return error() }
        return writer.error.map(Diagnostics.failureText)
    }

    /// 書き損じの理由。writer が言わなければ `unknown`。**理由を読む口はここだけ。**
    private var failureReason: String { writerError ?? "unknown" }

    /// 池から器を 1 つ借りる。借りられなければ `nil`。
    private func borrowBuffer(from pool: CVPixelBufferPool) -> CVPixelBuffer? {
        if let borrow = readsForTesting.borrow { return borrow(pool) }
        var borrowed: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &borrowed) == kCVReturnSuccess else {
            return nil
        }
        return borrowed
    }

    /// 器を取れなかったときの失敗。**writer が転んでいれば、器のせいではなく writer の理由で書き損じに
    /// する** ([#2944])。
    ///
    /// 器の先頭の番地を取れなかった枚 (``fill(_:with:)``・[#2974]) も同じ口を通る。
    ///
    /// 状態を確かめてから池を取るまでの間に writer が転ぶと、池は `nil` になり、器も借りられない。
    /// 取れなかった後にもう一度読めば、その枚も符号化器の理由を名乗る ([#1299])。**転んだと読むのは、
    /// `.writing` でなくなったとき、または writer が失敗の理由 (`error`) を言ったとき**である。状態の
    /// 変わり方は非同期で、`error` が先に立って状態がまだ `.writing` と読めることがあるため、`error` を
    /// より確かな信号として併せて見る。どちらでもない (`.writing` のまま・理由も無い) のに取れないときは、
    /// これまでどおり ``MovieWriteFailure/bufferUnavailable``。
    ///
    /// [#1299]: https://github.com/mokume-metal/mokume/issues/1299
    /// [#2944]: https://github.com/mokume-metal/mokume/issues/2944
    /// [#2974]: https://github.com/mokume-metal/mokume/issues/2974
    private func bufferFailure() -> MovieWriteFailure {
        guard writerStatus == .writing, writerError == nil else {
            return .writeFailed(path: path, reason: failureReason)
        }
        return .bufferUnavailable
    }

    /// 絵の大きさ。**開いた後は変えられない**ので、受け取った絵と食い違えば断る。
    let width: Int
    let height: Int

    /// この機械の符号化器が受け取る設定の鍵。**符号化器が無ければ nil。**
    ///
    /// 受けない鍵を渡すと AVFoundation は例外を投げ、Swift からは捕まえられない —
    /// **プロセスごと落ちる。** 符号化器によって受ける鍵が違う (専用回路の符号化器は
    /// `ExpectedFrameRate` を受けるが、専用回路を使わない符号化器や、仮想化された機械の
    /// 符号化器は受けない) ので、渡す前に**書き手と同じ符号化器に**聞く。
    static func supportedProperties(width: Int, height: Int) -> [String: Any]? {
        var encoder: CFString?
        var properties: CFDictionary?
        let status = VTCopySupportedPropertyDictionaryForEncoder(
            width: Int32(width), height: Int32(height),
            codecType: kCMVideoCodecType_AppleProRes4444,
            encoderSpecification: encoderSpecification() as CFDictionary, encoderIDOut: &encoder,
            supportedPropertiesOut: &properties)
        guard status == noErr else { return nil }
        return properties as? [String: Any]
    }

    /// 書き出しと問い合わせが渡す、符号化器の選び方。**2 か所で写さず、ここに 1 つだけ置く** —
    /// 問い合わせが書き手と違う符号化器に聞くと、書き手が受けない鍵を渡してプロセスごと落ちる
    /// (上の ``supportedProperties(width:height:)``)。
    ///
    /// **専用回路を使わない側を選ぶ理由と代償は、型の冒頭の「形式は選べない」の節にある**
    /// ([#1813])。測った回避策なので、Apple 側が直ったときに戻せるよう、指定はここだけにしてある。
    ///
    /// `static let` の辞書は Swift 6 で Sendable にならないので、呼ぶたびに作る。
    ///
    /// [#1813]: https://github.com/mokume-metal/mokume/issues/1813
    static func encoderSpecification() -> [String: Any] {
        [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder as String: false]
    }

    /// この機械で動きを書き出せるか。
    static var isAvailable: Bool { supportedProperties(width: 640, height: 360) != nil }

    /// この機械の符号化器が、乗算前のアルファをそのまま受けるか。
    ///
    /// 受けない機械では透けたところの色が黒へ寄る ([ADR-0023] 決定 4 の表が言う
    /// 「保つ」のうち、色まで保てるかは符号化器による)。
    ///
    /// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
    static var keepsStraightAlpha: Bool {
        supportedProperties(width: 640, height: 360)?[
            kVTCompressionPropertyKey_AlphaChannelMode as String] != nil
    }

    /// writer の入力へ渡す出力設定。**検査が「書き手へ符号化器の指定を渡したか」を機械によらず
    /// 見られるよう、`init` から切り出してある** ([#1813])。専用回路の無い機械 (GitHub のホストの VM)
    /// では、指定の有無によらず同じ結果になるので、書き上がりからは見えない。
    ///
    /// [#1813]: https://github.com/mokume-metal/mokume/issues/1813
    static func outputSettings(
        width: Int, height: Int, compression: [String: Any]
    ) -> [String: Any] {
        [
            AVVideoCodecKey: AVVideoCodecType.proRes4444,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            // **問い合わせと同じ符号化器を指す** (``encoderSpecification()``)
            AVVideoEncoderSpecificationKey: encoderSpecification(),
            // **色を名乗る。** 作業空間と同じ Display P3 で書き出す ([ADR-0011] 決定 1)。
            // 名乗らないと、再生する側は狭い色域だと見なして色を寄せる
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_P3_D65,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: compression,
        ]
    }

    /// 配る形 (H.264 の MP4) の出力設定 ([#2440])。
    ///
    /// **色は sRGB で名乗る** (書く前に ``DistributionColor`` が写す)。BT.709 の原色・sRGB の伝達関数・
    /// BT.709 の行列で、配る相手の再生環境が最も広く読める組。ビットレートは 1 画素あたり約 0.25 ビット
    /// (下限 2 Mbps) — 生成する絵は輪郭が硬く、既定の低い値だと縁が崩れる。
    ///
    /// [#2440]: https://github.com/mokume-metal/mokume/issues/2440
    static func h264Settings(width: Int, height: Int, frameRate: Int) -> [String: Any] {
        let bitsPerSecond = max(2_000_000, Int(Double(width * height * max(1, frameRate)) * 0.25))
        return [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_IEC_sRGB,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: bitsPerSecond,
                AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                AVVideoExpectedSourceFrameRateKey: frameRate,
            ],
        ]
    }

    /// 音声トラックの時刻の刻み (標本化率)。時刻は標本の番号 ÷ 標本化率で、映像と同じく絶対の時刻。
    static let soundTimescale = CMTimeScale(SoundWindow.sampleRate)

    /// 音声トラックの出力設定。**流れの形式のまま** — LPCM・32 ビット浮動小数点・48 kHz・2 チャンネル。AAC や整数への
    /// 丸めは使わない ([ADR-0042] 決定 6 の改訂)。
    ///
    /// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
    static func soundSettings() -> [String: Any] {
        [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: SoundWindow.sampleRate,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
        ]
    }

    /// - Parameters:
    ///   - soundStart: 音声トラックを付けるとき、最初の窓の先頭の標本の番号。`nil` なら付けない。
    init(
        path: String, width: Int, height: Int, frameRate: Int, format: Format = .proRes4444,
        soundStart: Int? = nil
    ) throws(MovieWriteFailure) {
        // **書き出し先がディレクトリなら、消さずに断る。** 下の「同じ名前が残っていると開けない」の
        // `removeItem` はディレクトリを中身ごと消す。出力先は利用者が指定するパスなので、取り違えて
        // ディレクトリを指すと、そのディレクトリが黙って消える ([#2859](https://github.com/mokume-metal/mokume/issues/2859))
        if AtomicFile.isDirectory(URL(fileURLWithPath: path), following: false) {
            throw .writeFailed(path: path, reason: Diagnostics.posixReason(EISDIR))
        }
        // H.264 の MP4 は専用回路を含む OS の符号化器に任せる (ProRes 4444 の問い合わせは要らない)
        let supported: [String: Any]
        switch format {
        case .proRes4444:
            guard let properties = Self.supportedProperties(width: width, height: height) else {
                throw .encoderUnavailable
            }
            supported = properties
        case .h264:
            supported = [:]
        }
        self.path = path
        self.format = format
        self.width = width
        self.height = height
        // `max(1, …)` は、組み立て (`SketchRuntime.checkFrameRates`) が 1 未満を断っているので届かない (#1642)。割り算の守りとして残す
        self.frameDuration = 1 / Double(max(1, frameRate))

        let url = URL(fileURLWithPath: path)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 同じ名前が残っていると開けない。撮り直しは上書きになるのが自然である
        try? FileManager.default.removeItem(at: url)

        guard let writer = try? AVAssetWriter(outputURL: url, fileType: format == .h264 ? .mp4 : .mov)
        else {
            throw .destinationUnavailable(path: path)
        }
        // **容れ物の刻みも揃える** (#2307)。既定の 600 のままだと、動画の長さが 600 分の 1 秒へ
        // 丸まる (7 fps の 10 枚で 1/1200 秒ずれる・90 000 fps の 3 枚は長さ 0 になる)
        writer.movieTimeScale = Self.timescale
        self.writer = writer

        // **乗算していないアルファをそのまま渡す** ([ADR-0011] 決定 4 の境界)。
        // 指定しないと乗算済みとして扱われ、透けた部分の色が黒へ寄る
        var compression: [String: Any] = [:]
        let settings: [String: Any]
        switch format {
        case .proRes4444:
            let alphaMode = kVTCompressionPropertyKey_AlphaChannelMode as String
            if supported[alphaMode] != nil {
                compression[alphaMode] = kVTAlphaChannelMode_StraightAlpha as String
            } else {
                Diagnostics.warn(
                    "This machine's encoder does not take unpremultiplied alpha. "
                        + "Anything transparent will be composited onto black")
            }
            settings = Self.outputSettings(width: width, height: height, compression: compression)
        case .h264:
            settings = Self.h264Settings(width: width, height: height, frameRate: frameRate)
        }

        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        // 実時間に追いつく必要は無い。詰まったら待たせるほうが、落とすより正しい
        input.expectsMediaDataInRealTime = false
        // **トラックの刻みを渡す** (#2307)。渡さないと各枚の時刻が 600 分の 1 秒へ丸まる
        input.mediaTimeScale = Self.timescale
        adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
            ])
        guard writer.canAdd(input) else { throw .destinationUnavailable(path: path) }
        writer.add(input)
        if let soundStart, format == .proRes4444 {
            let sound = AVAssetWriterInput(mediaType: .audio, outputSettings: Self.soundSettings())
            // **音声の入力だけ実時間にする** ([#3125] の測定)。映像と音声を 1 つの仕事から交互に足すと、両方が
            // 実時間でない (`false`) 入力では 1.1〜1.7 秒で双方の用意が戻らず止まる。音声だけ `true` にすれば、
            // 音声が映像より 0〜2 フレーム先行しても止まらず完走した。用意の待ちは映像と同じ読み直しで待つ
            //
            // [#3125]: https://github.com/mokume-metal/mokume/issues/3125
            sound.expectsMediaDataInRealTime = true
            // 音声の入力は刻みを変えられない (既定が標本化率)。時刻は標本の番号 ÷ 標本化率で渡す
            guard writer.canAdd(sound) else { throw .destinationUnavailable(path: path) }
            writer.add(sound)
            soundInput = sound
            self.soundStart = CMTime(value: CMTimeValue(soundStart), timescale: Self.soundTimescale)
        } else {
            soundInput = nil
            self.soundStart = nil
        }
        guard writer.startWriting() else {
            throw .writeFailed(path: path, reason: failureReason)
        }
    }

    /// 1 枚を書き足す。**時刻はフレーム自身のもの**で、通し番号ではない。
    ///
    /// 詰まっているあいだは待つ。ここはフレームループの外なので、待っても絵は遅くならない。
    /// writer が止まっていれば待たず、writer の理由で書き損じにする (型の冒頭)。
    func append(_ image: DisplayImage, at time: Double) async throws(MovieWriteFailure) {
        guard image.width == width, image.height == height else {
            throw .writeFailed(path: path, reason: "the frame size differs from when recording began")
        }
        let stamp = Self.stamp(time)
        if !hasStarted {
            // **止まった writer の区間は始めない。** 状態が `.writing` でない writer へ
            // `startSession` を呼ぶと AVFoundation は例外を投げうる (Swift からは捕まえられず、
            // プロセスごと落ちる)。最初の 1 枚の前に転んでいたら、ここで writer の理由を名乗る (#2944)
            guard writerStatus == .writing else {
                throw .writeFailed(path: path, reason: failureReason)
            }
            // 区間の始まりは、映像の最初の時刻と音声の最初の時刻の早いほう (音声の窓の先頭は標本に切り捨てるので、
            // 映像より最大 1 標本ぶん早い)
            writer.startSession(atSourceTime: soundStart.map { CMTimeMinimum($0, stamp) } ?? stamp)
            hasStarted = true
        }
        // 読み直して待つ。合図で待つ形を採らない理由は型の冒頭にある (#979)。
        // **止まった writer は待たない** — 理由も型の冒頭にある (#1299)
        while writerStatus == .writing, !input.isReadyForMoreMediaData {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard writerStatus == .writing else {
            throw .writeFailed(path: path, reason: failureReason)
        }
        // **池を取れない・器を借りられないときは、取れなかった後に状態を読み直す。** 確かめてから取るまでの
        // 間に writer が転ぶと、取れないのは器のせいではない (``bufferFailure()``・#2944)
        guard let pool = pixelBufferPool else { throw bufferFailure() }
        // **器は借りて返す。** フレームごとに確保すると、長く撮ったときにだけ重くなる
        // ([ADR-0023] 決定 5)
        guard let buffer = borrowBuffer(from: pool) else { throw bufferFailure() }

        // **番地を取れなければ、中身の無い器を書いた枚として渡さない** (#2974)。前に池へ返した器の
        // 残りか初期化されていない画素が、録画に入る。取れなかった枚は書き損じとして名乗る
        //
        // 配る形は、色を sRGB へ写してから書く (透けは書かない・``DistributionColor``)
        let drawn = format == .h264 ? DistributionColor.srgb(image, alpha: .drop) : image
        guard fill(buffer, with: drawn) else { throw bufferFailure() }
        let handed = readsForTesting.appendBuffer?(buffer, stamp)
            ?? adaptor.append(buffer, withPresentationTime: stamp)
        guard handed else {
            throw .writeFailed(path: path, reason: failureReason)
        }
    }

    /// 音の 1 窓を書き足す。**最初の映像を書き足した後に呼ぶ** (区間は映像の最初の時刻で始まる)。
    ///
    /// 時刻は窓の先頭の標本の番号 ÷ 標本化率で、映像と同じ絶対の時刻。詰まっているあいだは映像と同じく
    /// 読み直して待ち、writer が止まっていれば writer の理由で書き損じにする。音声トラックを付けていなければ
    /// 何もしない。
    func appendSound(_ window: SoundWindow) async throws(MovieWriteFailure) {
        guard let soundInput else { return }
        guard hasStarted else {
            throw .writeFailed(path: path, reason: "a sound window came before the first picture")
        }
        while writerStatus == .writing, !soundInput.isReadyForMoreMediaData {
            try? await Task.sleep(for: .milliseconds(1))
        }
        guard writerStatus == .writing else {
            throw .writeFailed(path: path, reason: failureReason)
        }
        guard let buffer = Self.soundBuffer(of: window) else {
            throw .writeFailed(path: path, reason: "could not make a sample buffer of the sound")
        }
        guard soundInput.append(buffer) else {
            throw .writeFailed(path: path, reason: failureReason)
        }
    }

    /// 窓を、2 チャンネルが交互に並ぶ LPCM の標本の束にする (``soundSettings()`` と同じ形)。
    static func soundBuffer(of window: SoundWindow) -> CMSampleBuffer? {
        let count = window.count
        guard count > 0, window.right.count == count else { return nil }
        var description = AudioStreamBasicDescription(
            mSampleRate: Float64(SoundWindow.sampleRate), mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked, mBytesPerPacket: 8,
            mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2, mBitsPerChannel: 32,
            mReserved: 0)
        var format: CMAudioFormatDescription?
        guard
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &description, layoutSize: 0, layout: nil, magicCookieSize: 0,
                magicCookie: nil, extensions: nil, formatDescriptionOut: &format) == noErr,
            let format
        else { return nil }
        var interleaved = [Float](repeating: 0, count: count * 2)
        for index in 0..<count {
            interleaved[2 * index] = window.left[index]
            interleaved[2 * index + 1] = window.right[index]
        }
        let bytes = interleaved.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard
            CMBlockBufferCreateWithMemoryBlock(
                allocator: nil, memoryBlock: nil, blockLength: bytes, blockAllocator: nil,
                customBlockSource: nil, offsetToData: 0, dataLength: bytes,
                flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block) == noErr,
            let block
        else { return nil }
        let copied = interleaved.withUnsafeBytes {
            CMBlockBufferReplaceDataBytes(
                with: $0.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: bytes)
        }
        guard copied == noErr else { return nil }
        var sample: CMSampleBuffer?
        guard
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: count,
                presentationTimeStamp: CMTime(value: CMTimeValue(window.start), timescale: soundTimescale),
                packetDescriptions: nil, sampleBufferOut: &sample) == noErr
        else { return nil }
        return sample
    }

    /// 書き終える。**ファイルが閉じてから返る。**
    ///
    /// - Parameter time: 最後のフレームの時刻。ここに 1 フレームぶんを足したところが
    ///   動画の終わりになる — 足さないと最後の 1 枚が長さ 0 になり、再生されない。
    func finish(lastFrameAt time: Double) async throws(MovieWriteFailure) {
        guard hasStarted else {
            // 最初の 1 枚の前に writer が転んでいたら (`append` は区間を始めずに断る)、その理由を名乗る。
            // 利用者に届くのは最後に決着した理由なので、「1 枚も無い」で覆わない。転んだ writer には
            // 取り消しを呼ばない
            if writerStatus != .writing || writerError != nil {
                throw .writeFailed(path: path, reason: failureReason)
            }
            // 1 枚も受け取っていない。中身の無いファイルを残さない
            writer.cancelWriting()
            throw .writeFailed(path: path, reason: "not a single frame was recorded")
        }
        input.markAsFinished()
        soundInput?.markAsFinished()
        writer.endSession(atSourceTime: Self.stamp(time + frameDuration))
        await writer.finishWriting()
        guard writer.status == .completed else {
            throw .writeFailed(path: path, reason: failureReason)
        }
    }

    /// 秒の時刻を、刻み (``timescale``) の**いちばん近い**目盛りへ置く ([#2307])。
    ///
    /// `CMTime(seconds:preferredTimescale:)` は近い目盛りへ丸めず、切り捨てる側へ寄る。n/fps 秒は
    /// 2 進の浮動小数で目盛りのわずかに手前になりうるので、1000 fps でも 1 枚の長さが 89 と 91 に
    /// 割れ、90 000 を割り切らない fps では半刻みを越えてずれた (7 fps の 4 枚目が 51 428.57 刻みの
    /// ところ 51 428)。
    ///
    /// 有限でない時刻と、目盛りの数が 64 ビットに収まらない時刻は、丸めずに `CMTime` へ任せる
    /// (書き手がそのまま断る)。
    ///
    /// [#2307]: https://github.com/mokume-metal/mokume/issues/2307
    static func stamp(_ seconds: Double) -> CMTime {
        let ticks = (seconds * Double(timescale)).rounded()
        guard ticks.isFinite, abs(ticks) < 0x1p62 else {
            return CMTime(seconds: seconds, preferredTimescale: timescale)
        }
        return CMTime(value: CMTimeValue(ticks), timescale: timescale)
    }

    /// 表示できる形の絵を、符号化器が読む並び (BGRA) へ写す。
    ///
    /// **アルファは乗算しない。** 乗算すると透けた部分の色が失われ、書き出した動きと
    /// 静止画で半透明の見え方が変わる ([ADR-0023] 決定 4 の表)。
    ///
    /// 器の先頭の番地を取れなければ何も写さず `false` を返す。呼ぶ側は、その枚を書き損じにする。
    private func fill(_ buffer: CVPixelBuffer, with image: DisplayImage) -> Bool {
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let address: UnsafeMutableRawPointer?
        if let seam = readsForTesting.baseAddress {
            address = seam(buffer)
        } else {
            address = CVPixelBufferGetBaseAddress(buffer)
        }
        guard let base = address else { return false }
        let destination = base.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        image.bytes.withUnsafeBufferPointer { source in
            Self.writeBGRA(
                from: source, width: width, height: height, into: destination, stride: stride)
        }
        return true
    }

    /// 詰め物の無い RGBA の行を、行幅 `stride` の BGRA へ並べ替えて写す。
    /// **各行の詰め物には書かない。**
    ///
    /// 並べ替えは vImage に任せる。1 バイトずつ写すループより 4K で 1 枚 8 ms ほど軽い
    /// ([#1754] の実測)。vImage が断ったとき (`permute` が誤りを返したとき) は、同じ結果を
    /// 出すループで写し直す — 書き出す絵は、どちらを通っても 1 バイトも変わらない。
    ///
    /// [#1754]: https://github.com/mokume-metal/mokume/issues/1754
    static func writeBGRA(
        from source: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
        into destination: UnsafeMutablePointer<UInt8>, stride: Int,
        permute: (UnsafeBufferPointer<UInt8>, Int, Int, UnsafeMutablePointer<UInt8>, Int)
            -> vImage_Error = permuteToBGRA
    ) {
        guard permute(source, width, height, destination, stride) != kvImageNoError else {
            return
        }
        writeBGRAByLoop(from: source, width: width, height: height, into: destination, stride: stride)
    }

    /// vImage で RGBA → BGRA へ並べ替える。
    static func permuteToBGRA(
        _ source: UnsafeBufferPointer<UInt8>, _ width: Int, _ height: Int,
        _ destination: UnsafeMutablePointer<UInt8>, _ stride: Int
    ) -> vImage_Error {
        guard let base = source.baseAddress else { return kvImageNullPointerArgument }
        // 読むだけの元を包む。vImage の型が可変のポインタを取るだけで、書き換えはしない
        var from = vImage_Buffer(
            data: UnsafeMutableRawPointer(mutating: base), height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: width * 4)
        var to = vImage_Buffer(
            data: destination, height: vImagePixelCount(height),
            width: vImagePixelCount(width), rowBytes: stride)
        // 出す側の i 番目のチャンネルへ、元の map[i] 番目を置く: B ← 2, G ← 1, R ← 0, A ← 3
        let map: [UInt8] = [2, 1, 0, 3]
        return vImagePermuteChannels_ARGB8888(&from, &to, map, vImage_Flags(kvImageNoFlags))
    }

    /// 1 バイトずつ RGBA → BGRA へ写す。vImage が断ったときの道で、検査の参照でもある。
    static func writeBGRAByLoop(
        from source: UnsafeBufferPointer<UInt8>, width: Int, height: Int,
        into destination: UnsafeMutablePointer<UInt8>, stride: Int
    ) {
        for y in 0..<height {
            let row = y * stride
            let line = y * width * 4
            for x in 0..<width {
                let to = row + x * 4
                let from = line + x * 4
                destination[to] = source[from + 2]
                destination[to + 1] = source[from + 1]
                destination[to + 2] = source[from]
                destination[to + 3] = source[from + 3]
            }
        }
    }
}
