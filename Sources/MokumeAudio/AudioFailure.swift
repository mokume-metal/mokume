// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 音声ファイルやサンプル列から ``AudioIn`` や ``SoundFile`` を作れなかったことを表すエラー。
///
/// **作成時に投げ、フレームの処理中は投げない** ([ADR-0020] 決定 5)。失敗したときに別の方法を
/// 選ぶ判断が要るのは作成時だけで、作成後に値が届かないことは ``AudioIn/state`` が示す。
/// 再生・停止のメソッド (``SoundFile/play()`` ほか) も投げず、受け付けられない値は警告して無視する。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum AudioFailure: Error, Equatable, Sendable {
    /// その名前のファイルが見つからない。`searched` は探した場所を、探した順に並べたもの。
    case notFound(path: String, searched: [String])
    /// 見つかったが、開けない。`location` はパスを解決した場所 (`..` を正規化したもの)、`reason` は
    /// OS が返した、開けなかった理由 (ディレクトリだった・読み取り権限が無い、など)。ファイルの形式とは
    /// 関係が無いので、直すのは `location` にあるファイルの配置か権限である
    /// (``DataFailure/unopenable(path:location:reason:)`` と同じ形・
    /// [#2358](https://github.com/mokume-metal/mokume/issues/2358))。
    ///
    /// **親フォルダに入れず、存在するかを確かめられない場合も、この case で返す** — `location` は確かめられ
    /// なかった場所で、`reason` は `cannot tell whether it exists (Permission denied)` の形になる。エラーの説明は
    /// 「見つかった」と言わず、リソースの宣言についての助言も出さない ([#2838](https://github.com/mokume-metal/mokume/issues/2838))。
    case unopenable(path: String, location: String, reason: String)
    /// 開けたが、音声として読めない (壊れている・対応していない形式)。
    case unreadable(path: String)
    /// サンプルが 1 つも無い。
    case empty
    /// サンプルレートが正でない。
    case invalidSampleRate(Float)
    /// 実行中のスケッチへ追加できない場所 (`setup()`・`draw()`・入力のコールバックの外 — 初期化子の中・
    /// 終了処理の後・`Task` の中) で、作成用の関数を呼んだ。`call` は呼んだ関数の名前 (`"loadSound(_:)"` など)。
    /// 作ったものは実行中のスケッチへ追加しないと再生も解析もされないので、ファイルを読む前にエラーにする。
    /// `setup()` などから呼び直す ([#2740](https://github.com/mokume-metal/mokume/issues/2740))。
    /// 渡したサンプル列が使えないときは、こちらより先にその case (``empty``・``invalidSampleRate(_:)``) を投げる。
    ///
    /// **名前に反して、スケッチの実行中にも起きる** — `draw()` が実行されている間に、そこで生成した
    /// `Task` から呼んでもこの case になる (``ImageFailure/notRunning(call:)`` と同じ)。
    /// 完了を待つ非同期の関数 (``Sketch/requestSound(_:)``) は別で、実行中のスケッチの中で生成した `Task` から呼べる。
    /// ``SketchPart/selectInput(_:)`` で選んだファイルなど、`Task` の中で読むなら、``Sketch/loadSound(_:)`` ではなくこちらを使う。
    /// 呼べないのは、`init`・終了処理の後・`Task.detached` と、待っている最中にスケッチが終了したとき。
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
