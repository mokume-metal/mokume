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
/// ## 書く順序
///
/// 1 枚でも続けて撮るときでも順序は同じ。**先に前回の成果物を消し、絵を 1 枚ずつ置き、
/// 目録 (`report.json`) を最後に原子的に書く** ([ADR-0018] 決定 3)。読み手は目録の
/// 識別子が一致した時点で、そこに並んだ絵が揃っていると判定してよい。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
@MainActor
final class FrameObserver {
    /// 区画の中の名前。読み手はこれを直に開く。
    static let requestFileName = "request.json"
    static let reportFileName = "report.json"
    /// 撮った絵の名前の頭。
    static let imagePrefix = "frame-"

    /// 撮った順の絵の名前。
    ///
    /// **桁を揃える。** 名前順に並べたときが撮った順になるので、目録を読まずに
    /// ディレクトリを覗いた人も列を取り違えない。
    static func imageFileName(at index: Int) -> String {
        String(format: "%@%03d.png", imagePrefix, index)
    }

    let directory: URL
    private let requests: RequestFile<ObservationRequest>
    private let reportURL: URL

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
    }

    /// まだ応えていない要求があれば返す。規約は ``RequestFile`` が守る。
    func pendingRequest() -> ObservationRequest? {
        requests.pending()
    }

    /// 前回の成果物を消す。**目録を先に、絵を後に**消す。
    ///
    /// 逆にすると、古い目録が指す絵だけが消えた状態を読み手が掴む窓が空く。目録が
    /// 無ければ、読み手は識別子の一致を待ち続けるだけで済む ([ADR-0018] 決定 3)。
    ///
    /// - Returns: 消した順。**消しながら並べている**ので、検査はこの並びで順序を見られる。
    ///   ディレクトリの書き込みを塞いで観察しようとしても、そのときは目録も絵も等しく
    ///   消せないため順序が現れない。
    ///
    /// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
    @discardableResult
    func clearProducts() -> [URL] {
        var removed: [URL] = []
        AtomicFile.remove(reportURL)
        removed.append(reportURL)
        let names =
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names.sorted() where name.hasPrefix(Self.imagePrefix) && name.hasSuffix(".png")
        {
            let url = directory.appendingPathComponent(name)
            AtomicFile.remove(url)
            removed.append(url)
        }
        return removed
    }

    /// 絵を 1 枚置く。名前を返す。
    func writeFrame(_ image: DisplayImage, at index: Int) throws -> String {
        let name = Self.imageFileName(at: index)
        try AtomicFile.write(to: directory.appendingPathComponent(name)) {
            try PNGFile.write(image, to: $0)
        }
        return name
    }

    /// 目録を書いて、この要求を終える。
    ///
    /// 応えようとしたことは、**書き込みに失敗しても**記録する。記録しないと同じ要求を
    /// 毎フレーム拾い直し、壊れた書き込み先の上でループになる。
    func finish(_ report: ObservationReport) throws {
        defer { requests.markHandled(report.id) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        try AtomicFile.write(try encoder.encode(report), to: reportURL)
    }
}
