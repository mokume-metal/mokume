// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 観測の区画 (`.mokume/observe`) を見張り、要求に応える。
///
/// ## 有効になる条件はファイルシステムに置く
///
/// **区画のディレクトリがあるときだけ観測が働く。** 要求を出す側がそれを作ることが、
/// そのまま観測の意思表示になる。環境変数を増やさずに済み、面がファイルだけで完結する
/// という [ADR-0018] 決定 1 とも揃う。無ければ何も見ない — 走っているスケッチは
/// 観測の存在を一切払わない。
///
/// ## 要求が無いフレームのコスト
///
/// ``pendingRequest()`` は要求ファイルの最終更新時刻を 1 回見るだけで返る。中身を読むのも、
/// JSON を解くのも、更新されていたときだけである。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class FrameObserver {
    /// 区画の中の名前。読み手はこれを直に開く。
    static let requestFileName = "request.json"
    static let reportFileName = "report.json"
    static let imageFileName = "frame.png"

    let directory: URL
    private let requests: RequestFile<ObservationRequest>
    private let reportURL: URL
    private let imageURL: URL

    /// 最終更新時刻を見た回数。要求が無いフレームのコストを検査が測るために持つ。
    var pollCount: Int { requests.pollCount }
    /// 要求ファイルを実際に読んだ回数。
    var readCount: Int { requests.readCount }

    /// 区画があるときだけ作る。
    static func makeIfEnabled(at directory: URL = WorkDirectory.facet("observe")) -> FrameObserver? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return FrameObserver(directory: directory)
    }

    init(directory: URL) {
        self.directory = directory
        self.requests = RequestFile(
            url: directory.appendingPathComponent(Self.requestFileName))
        self.reportURL = directory.appendingPathComponent(Self.reportFileName)
        self.imageURL = directory.appendingPathComponent(Self.imageFileName)
    }

    /// まだ応えていない要求があれば返す。規約は ``RequestFile`` が守る。
    func pendingRequest() -> ObservationRequest? {
        requests.pending()
    }

    /// 応答を書く。
    ///
    /// 絵があれば先に置き、**応答は最後に**書く ([ADR-0018] 決定 3) — 読み手は
    /// 識別子の一致で完成を判定するので、その時点で絵は揃っている。
    ///
    /// 絵が無い (採取できなかった) ときは、**前回の絵を先に消す**。新しい識別子の
    /// 応答と古い絵が組にされると、読み手は古い絵を新しいと信じてしまう。
    func respond(_ report: ObservationReport, image: DisplayImage?) throws {
        if let image {
            try AtomicFile.write(to: imageURL) { try PNGFile.write(image, to: $0) }
        } else {
            AtomicFile.remove(imageURL)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(report), to: reportURL)
        requests.markHandled(report.id)
    }
}
