// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 音声ファイルや標本列から ``AudioIn`` や ``SoundFile`` を作れなかったこと。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。失敗したときに別の道を
/// 選ぶ判断が要るのは作るときだけで、作れた後に値が来ないことは ``AudioIn/state`` が名乗る。
/// 鳴らす・止める口 (``SoundFile/play()`` ほか) も投げず、受けられない値は知らせて無視する。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum AudioFailure: Error, Equatable, Sendable {
    /// その名前のファイルが見つからない。`searched` は探した場所を、探した順に並べたもの。
    case notFound(path: String, searched: [String])
    /// 見つかったが、音声として読めない (壊れている・対応していない形式)。
    case unreadable(path: String)
    /// 標本が 1 つも無い。
    case empty
    /// 標本化率が正でない。
    case invalidSampleRate(Float)
}

extension AudioFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            AssetFailure.notFound(path: path, searched: searched).description
        case .unreadable(let path):
            "\"\(path)\" cannot be read as audio. Check whether it is damaged, and that the format "
                + "is one macOS plays (WAV, AIFF, CAF, MP3, AAC/M4A, FLAC)"
        case .empty:
            "There are no samples to analyze. Pass at least one sample"
        case .invalidSampleRate(let rate):
            "The sample rate \(rate) is not usable. Pass a positive number of samples per second "
                + "(44100 or 48000, for example)"
        }
    }
}
