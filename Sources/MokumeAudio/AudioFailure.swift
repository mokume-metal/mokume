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
    /// 見つかったが、開けない。`location` は名前が解けた場所 (`..` を畳んだもの)、`reason` は
    /// OS が名乗った開けなかった事情 (ディレクトリだった・読む権利が無い、など)。中身の形式とは
    /// 関係が無いので、直すのは `location` にあるものの置き場か権利である
    /// (``DataFailure/unopenable(path:location:reason:)`` と同じ形・
    /// [#2358](https://github.com/mokume-metal/mokume/issues/2358))。
    ///
    /// **親のフォルダに入れず、在るかを確かめられない場合も、この case で運ぶ** — `location` は確かめられ
    /// なかった場所で、`reason` は `cannot tell whether it exists (Permission denied)` の形になる。説明は
    /// 「見つかった」と言わず、資源の宣言の助言も出さない ([#2838](https://github.com/mokume-metal/mokume/issues/2838))。
    case unopenable(path: String, location: String, reason: String)
    /// 開けたが、音声として読めない (壊れている・対応していない形式)。
    case unreadable(path: String)
    /// 標本が 1 つも無い。
    case empty
    /// 標本化率が正でない。
    case invalidSampleRate(Float)
    /// 走っている実行へ足せない所 (`setup()`・`draw()`・入力のコールバックの外 — 初期化子の中・
    /// 後片付けの後・`Task` の中) で作る口を呼んだ。`call` は呼んだ口の名前 (`"loadSound(_:)"` など)。
    /// 作ったものは走っている実行へ足さないと鳴らず解析もされないので、ファイルを読む前に断る。
    /// `setup()` などから呼び直す ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。
    /// 渡した標本列が使えないときは、こちらより先にその場合 (``empty``・``invalidSampleRate(_:)``) を投げる。
    ///
    /// **名前に反して、スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで起こした
    /// `Task` から呼んでもこの場合になる (``ImageFailure/notRunning(call:)`` と同じ)。
    /// 待つ口 (``Sketch/requestSound(_:)``) は別で、走っている実行の中で起こした `Task` から呼べる。
    /// ``SketchPart/selectInput(_:)`` で選んだファイルなど、`Task` の中で読むなら、``Sketch/loadSound(_:)`` ではなくこちらを使う。
    /// 呼べないのは、`init`・後片付けの後・`Task.detached` と、待っている最中にスケッチが終わったとき。
    case notRunning(call: String)
}

extension AudioFailure: NotRunningFailure {}

extension AudioFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            AssetFailure.notFound(path: path, searched: searched).description
        case .unopenable(let path, let location, let reason):
            AssetOpening.notice(path: path, location: location, reason: reason)
        case .unreadable(let path):
            "\"\(path)\" cannot be read as audio. Check whether it is damaged, and that the format "
                + "is one macOS plays (WAV, AIFF, CAF, MP3, AAC/M4A, FLAC). If it is a video file, "
                + "it may have no audio track, or one in a format macOS cannot open"
        case .empty:
            "There are no samples to analyze. Pass at least one sample"
        case .invalidSampleRate(let rate):
            "The sample rate \(rate) is not usable. Pass a positive number of samples per second "
                + "(44100 or 48000, for example)"
        case .notRunning(let call):
            Self.notAttachedNotice(call)
        }
    }
}
