// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

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
/// **溜め続けない。** 直近 ``keep`` 件の観測だけを残し、それより古い写しは次の写しを置くときに消す。
/// 窓口は道具を 1 本ずつ走らせる (``MCPServer``) ので、呼び手が読む前に消えるのは、その間に
/// ``keep`` 件を超えて観測したときだけである。窓口が終われば置き場ごと消す。
/// ここは道具の側が呼び手に渡すまでの一時の写しで、頼まれた観測を恒久に残す置き場 (#2618) とは
/// 名前も消える条件も分ける。
final class ObservationCopies {
    /// 残す観測の件数の既定。
    static let defaultKeep = 4

    /// 写しを置く置き場。
    let root: URL
    /// 残す観測の件数。
    let keep: Int
    /// 写し方。検査から、写している間に区画を書き換える差し替えができる。
    var copyItem: (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    /// 古い順の、写しを置いた識別子。
    private var order: [String] = []

    init(root: URL? = nil, keep: Int = ObservationCopies.defaultKeep) {
        self.root = root
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-observe-\(UUID().uuidString.lowercased())", isDirectory: true)
        self.keep = max(1, keep)
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
            return .failed(reason: "the picture could not be copied (\(error.localizedDescription))")
        }
        order.removeAll { $0 == id }
        order.append(id)
        while order.count > keep {
            let oldest = order.removeFirst()
            try? FileManager.default.removeItem(at: root.appendingPathComponent(oldest, isDirectory: true))
        }
        return .copied(directory: directory)
    }

    /// 写したが渡さなかった写しを消す (写し終えた後に応答が自分のものでなくなっていた回)。
    func discard(id: String) {
        guard Self.isPlain(id) else { return }
        order.removeAll { $0 == id }
        try? FileManager.default.removeItem(at: root.appendingPathComponent(id, isDirectory: true))
    }

    /// 置き場の下に収まる 1 つの名前か。区画の外へ抜ける名前 (`../`・区切り・空) は写さない。
    private static func isPlain(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/")
            && !name.contains("\0")
    }
}
