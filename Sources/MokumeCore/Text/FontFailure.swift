// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 書体のファイルを読むときに起こりうる失敗。
///
/// 起こりうる失敗が列挙できるので typed throws で運ぶ ([ADR-0010] 決定 7)。
/// **読み込みは投げる** — 失敗したら別の道を選ぶ判断が要るので、黙って既定へ
/// 倒してはいけない ([ADR-0020] 決定 5)。
///
/// **case はこの 3 つで出し切る** ([#2249])。0.x の間も、公開の Failure 型に case を足すことは
/// 破壊として扱う。画像の ``ImageFailure`` が持つ `unplaceable` (GPU へ置けない) と `notRunning`
/// (走っている面が要る) は、書体の読み込みには起こらない — ``Font`` は面に属さない値で、
/// `loadFont(_:)` は走っている面を使わないので、走っていない所でも読める。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
/// [#2249]: https://github.com/mokume-metal/mokume/issues/2249
public enum FontFailure: Error, Equatable, Sendable {
    /// その名前の資材が見つからない。
    case notFound(path: String, searched: [String])
    /// 見つかったが、開けない。`location` は名前が解けた場所 (`..` を畳んだもの)、`reason` は
    /// OS が名乗った開けなかった事情 (ディレクトリだった・読む権利が無い、など)。中身の形式とは
    /// 関係が無いので、直すのは `location` にあるものの置き場か権利である
    /// (``ImageFailure/unopenable(path:location:reason:)`` と同じ形)。
    case unopenable(path: String, location: String, reason: String)
    /// 開けたが、書体として読めない (書体のファイルではない・壊れている・空)。
    case unreadable(path: String)
}

extension FontFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            // **切り分けの言葉を必ず添える** (``ImageFailure`` と同じ理由)
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
            return "\"\(path)\" cannot be read as a font. Check that it is a font file "
                + "(.ttf, .otf, .ttc or .otc)"
        }
    }
}
