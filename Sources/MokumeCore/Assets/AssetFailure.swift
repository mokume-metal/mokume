// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 資材の名前から、在るファイルを探せなかったこと。``SketchPart/assetURL(_:)`` が投げる。
///
/// **「見つからない」と「在るかを確かめられない」を分ける** — 直す所が違うため。
///
/// - 全部の候補が無い (``notFound(path:searched:)``): 置き場を直す。資源の宣言も確かめる
/// - 入れない場所があり、在るかを確かめられない (``unreachable(path:location:reason:)``): その場所の
///   権利 (親のフォルダに入る権利など) を直す。資源の宣言の助言は的外れである
public enum AssetFailure: Error, Equatable, Sendable {
    /// その名前の資材が見つからない。`searched` は探した場所を、探した順に並べたもの。
    case notFound(path: String, searched: [String])
    /// 候補の場所に入れず (親のフォルダに入る権利が無い・symlink が巡っている・宛先の無い symlink など)、
    /// 在るかを確かめられない。`location` は確かめられなかった場所 (`..` を畳んだもの)、`reason` は
    /// OS が名乗った事情 (`Permission denied` など)。**そこで探すのを止める** — 入れない場所は在るかも
    /// しれない場所で、後ろの候補を黙って採ると原因が分からない
    /// ([#2838](https://github.com/mokume-metal/mokume/issues/2838))。
    ///
    /// 入れない親の下では、在るファイルと無いファイルの区別が付かない。だから説明は「見つかった」とも
    /// 「無い」とも言わない。
    case unreachable(path: String, location: String, reason: String)
}

extension AssetFailure: CustomStringConvertible {
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
        case .unreachable(let path, let location, let reason):
            return AssetOpening.notice(
                path: path, location: location, reason: AssetOpening.unreachableReason(reason))
        }
    }
}
