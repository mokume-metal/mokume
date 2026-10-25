// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import mokume

/// 窓口が呼び手へ渡す、観測の絵の写し ([#2992](https://github.com/mokume-metal/mokume/issues/2992))。
///
/// 観測の区画は応答 1 枚・要求 1 枚で、書き手を調停しない (ADR-0018 決定 3)。次の書き手の撮り始めは
/// 応答を消し、絵を番号だけの固定名で書き直すので、**区画の中の場所を返すと、呼び手が読む前に別の
/// 書き手の絵に入れ替わりうる**。窓口は応答を見たら絵を自分の置き場へ写し、写し終えた後に応答が
/// まだ自分の識別子を echo していることを確かめてから、写しの場所を渡す (確かめるのは呼び手 —
/// ``Tools``)。
///
/// **置き場は窓口 1 つにつき 1 つの一時ディレクトリで、その下を要求の識別子ごとに分ける。** 別の書き手の
/// 撮影では書き換わらず、別の窓口とも重ならない。
///
/// **溜め続けない。** 直近 ``keep`` 件の観測だけを残し、さらに写した絵の合計が ``maxPictures`` 枚を
/// 越えたら古い観測から消す (最新の 1 件は、それだけで越えても残す)。古い写しは次の写しを置くときに
/// 消す。窓口は道具を 1 本ずつ走らせる (``MCPServer``) ので、呼び手が読む前に消えるのは、その間に
/// 上限を超えて観測したときだけである。窓口が終われば置き場ごと消す (``deinit``)。**信号で終わる窓口は
/// ``deinit`` を通らない** (``MCPServer`` は SIGTERM・SIGINT・SIGHUP で畳む) ので、置き場の名前に
/// 持ち主の pid を入れておき、次の窓口が立つときに、持ち主が居ない古い置き場を掃く
/// (``sweepStale(in:isAlive:)``)。
/// ここは道具の側が呼び手に渡すまでの一時の写しで、頼まれた観測を恒久に残す置き場 (#2618) とは
/// 名前も消える条件も分ける。
final class ObservationCopies {
    /// 残す観測の件数の既定。
    static let defaultKeep = 4
    /// 残す絵の枚数の合計の既定。続けて撮る観測の上限 (``ObservationRequest/maximumCount``) と同じ。
    static let defaultMaxPictures = ObservationRequest.maximumCount
    /// 置き場の名前の頭。続く `<pid>-<uuid>` の pid が持ち主。**窓口の外の一時の場所と名前が重ならない**
    /// 綴りにしてある (掃くのはこの綴りだけ)。
    static let prefix = "mokume-picture-copies-"

    /// 写しを置く置き場。
    let root: URL
    /// 残す観測の件数。
    let keep: Int
    /// 残す絵の枚数の合計。
    let maxPictures: Int
    /// 写し方。検査から、写している間に区画を書き換える差し替えができる。
    var copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    /// 古い順の、写しを置いた識別子と、その枚数。
    private var order: [(id: String, pictures: Int)] = []

    /// - Parameter root: 置き場。渡さなければ、一時の場所に pid 入りの名前で作る。
    ///
    /// **作るだけで、古い置き場は掃かない。** 掃く (``sweepStale(in:isAlive:)``) のは一時の場所の
    /// 全体を一覧する仕事で、窓口が立つときに 1 度だけ行えばよい (``MCPCommand/run(_:serving:)``)。
    /// ここで掃くと、道具の束 (``Tools``) を作るたびに一覧が走る — 検査は束を何百と作るので、
    /// 一時の場所に溜まった数万の項目を毎回なめて、無関係な検査まで桁違いに遅くなった ([#3131])。
    ///
    /// [#3131]: https://github.com/mokume-metal/mokume/pull/3131
    init(
        root: URL? = nil, keep: Int = ObservationCopies.defaultKeep,
        maxPictures: Int = ObservationCopies.defaultMaxPictures
    ) {
        if let root {
            self.root = root
        } else {
            self.root = FileManager.default.temporaryDirectory.appendingPathComponent(
                "\(Self.prefix)\(getpid())-\(UUID().uuidString.lowercased())", isDirectory: true)
        }
        self.keep = max(1, keep)
        self.maxPictures = max(1, maxPictures)
    }

    /// `directory` の下の、持ち主の居ない古い置き場を消す。
    ///
    /// 名前の `<pid>` が、いま走っていないプロセスのものだけを消す。**自分の置き場と、走っている窓口の
    /// 置き場は触らない。** pid の再利用で消し損ねることはあっても、生きている窓口の置き場は消さない向きに倒す。
    /// - Parameter isAlive: pid のプロセスが居るか。検査から差し替える。
    static func sweepStale(
        in directory: URL,
        isAlive: (pid_t) -> Bool = { pid in kill(pid, 0) == 0 || errno == EPERM }
    ) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(prefix) {
            let rest = name.dropFirst(prefix.count)
            guard let digits = rest.split(separator: "-", maxSplits: 1).first,
                let pid = pid_t(digits), pid > 0, !isAlive(pid)
            else { continue }
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    deinit {
        // `root` は窓口が作ったものか、検査が渡した一時の場所。どちらも窓口とともに消す
        try? FileManager.default.removeItem(at: root)
    }

    /// 写した結果。
    enum Outcome: Equatable {
        /// 全枚を写した。名前は目録のまま。
        case copied(directory: URL)
        /// 写せなかった。理由は呼び手が読む文。**区画の応答が自分のままかは、呼び手が確かめる。**
        case failed(reason: String)
    }

    /// 目録の名前の絵を、区画から識別子の置き場へ写す。
    ///
    /// 1 枚でも写せなければ、途中までの写しは消して ``Outcome/failed(reason:)`` を返す。
    /// **応答の識別子の確かめは呼び手が写し終えた後に行う** — ここで確かめても、確かめた後に
    /// 掃除が始まりうる。
    func copy(names: [String], from facet: URL, id: String) -> Outcome {
        guard Self.isPlain(id), names.allSatisfy(Self.isPlain) else {
            return .failed(reason: "the name of a picture is not a plain file name")
        }
        let directory = root.appendingPathComponent(id, isDirectory: true)
        do {
            try? FileManager.default.removeItem(at: directory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in names {
                try copyItem(facet.appendingPathComponent(name), directory.appendingPathComponent(name))
            }
        } catch {
            try? FileManager.default.removeItem(at: directory)
            return .failed(reason: "the picture could not be copied (\(Diagnostics.failureText(error)))")
        }
        order.removeAll { $0.id == id }
        order.append((id, names.count))
        // 件数と枚数の合計の両方で縛る。最新の 1 件は、それだけで枚数の上限を越えても残す
        while order.count > keep || (order.count > 1 && order.reduce(0, { $0 + $1.pictures }) > maxPictures) {
            let oldest = order.removeFirst()
            try? FileManager.default.removeItem(at: root.appendingPathComponent(oldest.id, isDirectory: true))
        }
        return .copied(directory: directory)
    }

    /// 写したが渡さなかった写しを消す (写し終えた後に応答が自分のものでなくなっていた回)。
    func discard(id: String) {
        guard Self.isPlain(id) else { return }
        order.removeAll { $0.id == id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }

    /// 置き場の下に収まる 1 つの名前か。区画の外へ抜ける名前 (`../`・区切り・空) は写さない。
    private static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\0")
    }
}
