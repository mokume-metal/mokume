// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 画像を読む・作るときに起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **読み込みは投げる** — 失敗したら別の道を選ぶ判断が要るので、黙って既定へ
/// 倒してはいけない ([ADR-0020] 決定 5)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum ImageFailure: Error, Equatable, Sendable {
    /// その名前の資材が見つからない。
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
    /// 開けたが、画像として読めない。
    case undecodable(path: String)
    /// GPU 側へ置けない — 読めたが置き場が足りない、あるいは辺が 1 を割るか面の上限より大きい。
    ///
    /// **下の端も同じ case で運ぶ。** 呼ぶ側がすることは上限を越えたときと同じ (頼む大きさを
    /// 直す) で、分けても選び分ける先が無い (``RenderFailure/invalidSize(width:height:)`` と
    /// 同じ理由・[#1642](https://github.com/mokume-metal/mokume/issues/1642))。
    case unplaceable(width: Int, height: Int)
    /// 書き出せなかった。`path` は頼んだ行き先、`reason` は書けなかった事情 (置き場が無い・書く権利が
    /// 無いなど)。``Image/save(_:)`` が投げる
    /// (``DataFailure/unwritable(path:reason:)`` と同じ形)。
    case unwritable(path: String, reason: String)
    /// 走っている面を取れない所で、この型を投げる資源の口を呼んだ。`call` は呼んだ口の名前
    /// (`"loadImage(_:)"` など)。返すものを走っている面からしか作れないので、`setup()` などから呼び直す
    /// ([#2683](https://github.com/mokume-metal/mokume/issues/2683))。
    ///
    /// 面を取れるのは `setup()`・`draw()`・入力のコールバックの中 (待つ読み込みは、そこで起こした
    /// `Task` の中も) だけで、初期化子の中・後片付けの後・`Task` の中からは取れない。**名前に反して、
    /// スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで起こした `Task` から
    /// 同期の口を呼んでもこの場合になる ([#1322](https://github.com/mokume-metal/mokume/issues/1322)
    /// と同じ事情)。
    case notRunning(call: String)
}

extension ImageFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            // **切り分けの言葉を必ず添える。** 資材が読めない不具合は、描画側が
            // 正しく動いているのに絵にならない形で現れるので、実装を疑うと当たりが
            // 外れる。宣言の抜けを先に確かめられるようにする
            return """
                Cannot find "\(path)".
                Looked in:
                \(searched.map { "  - \($0)" }.joined(separator: "\n"))
                If you did put it there, check that the package declares where its resources are \
                (`.executableTarget(..., resources: [.copy("assets")])`). \
                Without that declaration the build still passes quietly, and the file just cannot \
                be read at run time
                """
        case .unopenable(let path, let location, let reason):
            return AssetOpening.notice(path: path, location: location, reason: reason)
        case .undecodable(let path):
            return "\"\(path)\" cannot be read as an image. Check that the format is one mokume handles"
        case .unplaceable(let width, let height):
            return """
                Cannot place a \(width)x\(height) image on the GPU.
                A side has to be at least 1 and at most \(RenderDevice.maxTextureSide) pixels — \
                check that it is within that
                """
        case .unwritable(let path, let reason):
            return "Cannot write \"\(path)\": \(reason)"
        case .notRunning(let call):
            return OutsideRun.notRunningNotice(call)
        }
    }
}
