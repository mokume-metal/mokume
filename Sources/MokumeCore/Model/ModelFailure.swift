// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// モデルを読むときに起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **読み込みは投げる** — 失敗したら別の道を選ぶ判断が要るので、黙って既定へ
/// 倒してはいけない ([ADR-0020] 決定 5)。
///
/// **「読めなかった」と「読めたが面が無い」は別である。** 後者は失敗として投げず、
/// 置いたときに知らせる — 投げてしまうと、利用者は読み込みの側を直そうとして、
/// 実際には空のファイルを渡しているという事実に辿り着けない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum ModelFailure: Error, Equatable, Sendable {
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
    /// 開けたが、その形式として読めない。OBJ なら文字 (UTF-8) として読めない、STL なら
    /// 文字の STL としてもバイナリの STL としても読めない (壊れている・途中で切れた文字の STL・空)。
    /// 途中で切れたバイナリの STL は投げず、揃っている面だけを読む (揃った面が無ければ空のモデル)。
    /// 見出しが `solid` で始まり `facet normal` を含むバイナリの STL は、一時の置き場に写しを書けないときも、
    /// 壊れていなくてもこの場合になる (``SketchPart/loadModel(_:normalize:)``)。
    case unreadable(path: String)
    /// 対応していない形式。説明に、読める形式の一覧が載る。
    case unsupported(path: String, extensionName: String)
    /// 走っている面を取れない所で、この型を投げる資源の口を呼んだ。`call` は呼んだ口の名前
    /// (`"loadModel(_:normalize:)"` など)。返すものを走っている面からしか作れないので、`setup()` などから呼び直す
    /// ([#2683](https://github.com/mokume-metal/mokume/issues/2683))。
    ///
    /// 面を取れるのは `setup()`・`draw()`・入力のコールバックの中 (待つ読み込みは、そこで起こした
    /// `Task` の中も) だけで、初期化子の中・後片付けの後・`Task` の中からは取れない。**名前に反して、
    /// スケッチが走っている最中にも起こる** — `draw()` が回っている間に、そこで起こした `Task` から
    /// 同期の口を呼んでもこの場合になる ([#1322](https://github.com/mokume-metal/mokume/issues/1322)
    /// と同じ事情)。
    case notRunning(call: String)
}

extension ModelFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            // **切り分けの言葉を必ず添える** (``ImageFailure`` と同じ理由)。
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
        case .unreadable(let path):
            // **形式ごとに言い分ける。** バイナリの STL に「文字として読めない」と言うと、
            // 読み手を取り違えたように読める
            switch ModelFile.Format(path: path) {
            case .stl:
                return """
                    "\(path)" cannot be read as STL (neither ASCII nor binary). \
                    Check whether it is damaged or cut short
                    """
            case .obj, nil:
                return "\"\(path)\" cannot be read as text. Check whether it is damaged"
            }
        case .unsupported(let path, let extensionName):
            // **一覧は読み手の選び方と同じ所から引く** (``ModelFile/Format``)。別々に書くと、
            // 形式を足したときに説明だけが古いまま残る
            let readable = ModelFile.Format.allCases.map(\.displayName).joined(separator: ", ")
            return """
                The format of "\(path)" (.\(extensionName)) is not supported. \
                Readable formats: \(readable)
                """
        case .notRunning(let call):
            return OutsideRun.notRunningNotice(call)
        }
    }
}
