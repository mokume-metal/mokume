// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// 動画ファイルから ``Movie`` を作れなかったこと。``Sketch/createVideo(_:)`` が投げる。
///
/// **作るときに投げ、フレームの間は投げない** ([ADR-0020] 決定 5)。失敗したときに別の道を
/// 選ぶ判断が要るのは作るときだけで、作れた後に読めなくなったことは ``Movie/state`` が名乗る。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
public enum MovieFailure: Error, Equatable, Sendable {
    /// その名前のファイルが見つからない。`searched` は探した場所を、探した順に並べたもの。
    case notFound(path: String, searched: [String])
    /// 見つかったが、動画として読めない (壊れている・対応していない形式・最初のコマが読めない)。
    case unreadable(path: String)
    /// 読めたが、映像が入っていない (音声だけのファイルなど)。
    case noVideo(path: String)
    /// 動画の大きさの絵を GPU に置けない。
    case unplaceable(width: Int, height: Int)
}

extension MovieFailure: CustomStringConvertible {
    public var description: String {
        switch self {
        case .notFound(let path, let searched):
            AssetFailure.notFound(path: path, searched: searched).description
        case .unreadable(let path):
            "\"\(path)\" cannot be read as a video. Check whether it is damaged, and that the "
                + "format is one macOS plays (QuickTime .mov or MPEG-4 .mp4 / .m4v, with H.264, "
                + "HEVC or ProRes)"
        case .noVideo(let path):
            "\"\(path)\" has no picture in it. If it is a sound file, analyze it with "
                + "createAudioIn(file:) instead"
        case .unplaceable(let width, let height):
            ImageFailure.unplaceable(width: width, height: height).description
        }
    }
}
