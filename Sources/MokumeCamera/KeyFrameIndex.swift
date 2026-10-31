// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AVFoundation
import CoreMedia

/// 動画のトラックの鍵のコマ (それだけで復号できるコマ) の位置を、**復号せずに**トラックのサンプルの
/// 目録から引く ([#2764])。``MovieReader`` が、``MovieFrames/seekAhead`` より近い先へ飛ぶときに、
/// 読み進めずに読み直すかを決めるのに使う。
///
/// 読み直すと、飛び先の手前の鍵のコマから復号し直す。だから飛び先の手前の鍵のコマが、次に届くコマより
/// 十分に先にあれば、間のコマを復号せずに済むぶん読み直したほうが速い。どちらで読んでも映るコマは
/// 変わらない。**読み直しを足すほうにだけ使い、減らすほうには使わない** — 間に鍵のコマが無くても、
/// 遠い先は読み直すほうが速い (読み直すと飛び先より前のコマを変換しない。``MovieReader`` の説明)。
///
/// 数えるのは完全な鍵のコマ (full sync) だけである。部分的な鍵のコマ (HEVC の open GOP の CRA) を跨ぐ
/// 問いには答えず (``Answer/unknown``)、読み手は 1 秒で分ける元の判定に戻る — 読み手が部分的な鍵から
/// 読み直せるかは目録から分からないので、どの動画でも元より悪くしないことを先に取る。
///
/// [#2764]: https://github.com/mokume-metal/mokume/issues/2764
nonisolated struct KeyFrameIndex {
    /// 読み進めるか読み直すかの答え。
    enum Answer: Equatable {
        /// 間に十分先の鍵のコマがある。読み直す。
        case restart
        /// 間に鍵のコマが無いか、あってもすぐ先。鍵のコマのためには読み直さない。
        case readOn
        /// 目録から決められない。元の判定に任せる。
        case unknown
    }

    /// 1 回の問いで遡るサンプルの上限。鍵のコマの間隔がこれより長い動画では答えない (30 fps で 20 秒)。
    static let searchLimit = 600

    private let track: AVAssetTrack
    /// トラックの始まり (アセットの時間軸の上)。
    private let start: CMTime

    /// - Parameters:
    ///   - track: 映像のトラック。
    ///   - start: トラックの始まり (アセットの時間軸の上)。
    ///   - canProvideSampleCursors: トラックが目録を引かせるか (`AVAssetTrack.load(.canProvideSampleCursors)`)。
    ///     引かせないなら `nil`。
    init?(track: AVAssetTrack, start: CMTime, canProvideSampleCursors: Bool) {
        guard canProvideSampleCursors else { return nil }
        self.track = track
        self.start = start
    }

    /// 次に届くコマ (表示の時刻 `lower` 秒) から `target` 秒まで進むとき、読み直す値打ちがあるか。
    ///
    /// `target` 以下で最も遅い鍵のコマが `lower` より `margin` 秒以上先にあれば ``Answer/restart``。
    func answer(after lower: Double, upTo target: Double, margin: Double) -> Answer {
        let at = CMTimeAdd(start, CMTime(seconds: target, preferredTimescale: Self.timescale))
        guard let cursor = track.makeSampleCursor(presentationTimeStamp: at) else { return .unknown }
        // 表示の時刻がその位置以下で最も遅いサンプルから、復号の順に遡る。並べ替えのある動画では表示の
        // 時刻が飛び先より後の鍵のコマにも出会うので、飛び先以下のものだけを数える
        for _ in 0..<Self.searchLimit {
            let time = CMTimeSubtract(cursor.presentationTimeStamp, start).seconds
            let sync = cursor.currentSampleSyncInfo
            if sync.sampleIsFullSync.boolValue, time <= target {
                return time - lower >= margin ? .restart : .readOn
            }
            if sync.sampleIsPartialSync.boolValue, time > lower, time <= target { return .unknown }
            guard cursor.stepInDecodeOrder(byCount: -1) == -1 else { return .unknown }
        }
        return .unknown
    }

    /// 位置を表す刻み (1 µs)。``MovieReader`` と同じ。
    private static let timescale: CMTimeScale = 1_000_000
}
