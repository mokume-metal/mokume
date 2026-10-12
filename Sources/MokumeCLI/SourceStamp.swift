// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

/// 監視しているソースの世代。
///
/// **中身から導く。** 時刻や連番で振ると「編集して元に戻した」ときに別の世代を
/// 名乗ってしまい、読み手は反映されていない変更を反映済みと読む。中身から導けば、
/// 変われば必ず変わり、変わらなければ変わらない。
enum SourceStamp {
    /// 数えるファイル。ここに無い変更は作り直しを起こさない (資材の置き場は別に数える ―
    /// ``sources(in:)``)。
    ///
    /// **断片 (`.metal`) は数えない。** 断片は走らせたまま差し替わるので、作り直して
    /// 起動し直すと**差し替わる様子そのものが見られなくなる** — 保存のたびに窓が
    /// 開き直り、絵は最初から始まる。監視は 2 つあってよく、見るものを分ければよい:
    /// 作り直しが要る変更はここが、走らせたまま差し替わる変更は走っている側が見る。
    static let watchedExtensions: Set<String> = ["swift"]

    /// 資材の置き場の中でも数えないもの。**断片は置き場の中でも数えない** (上と同じ理由)。
    static let unwatchedAssetExtensions: Set<String> = ["metal"]

    /// いまの世代。読めるファイルが 1 つも無ければ `nil`。
    ///
    /// **控えを持たない 1 回きりの読み**で、毎回すべてを読む。巡回のように繰り返し呼ぶ側は
    /// ``Reader`` を 1 つ持ち回る — 名乗る世代は同じで、読む量だけが違う。
    static func current(for directory: URL) -> String? {
        Reader().current(for: directory)
    }

    /// 監視するファイルを集める。
    ///
    /// **資材の置き場 (`Sources/<target>/assets/`) の下も数える**
    /// ([#2312](https://github.com/mokume-metal/mokume/issues/2312))。資材は
    /// `resources: [.copy("assets")]` でビルドに入って束へ写され、走っているスケッチはその
    /// 写しを読む — 数えないと、資材だけを変えた保存では作り直さず、古い写しを読み続ける。
    /// 置き場の名前は走らせる前の宣言の検査と同じ 1 つ (``ResourceDeclaration/directoryName``)
    /// を使う。隠しファイルと断片 (``unwatchedAssetExtensions``) は数えない。
    static func sources(in directory: URL) -> [URL] {
        var found: [URL] = []
        let manifest = directory.appendingPathComponent("Package.swift")
        if FileManager.default.fileExists(atPath: manifest.path) { found.append(manifest) }

        let sources = directory.appendingPathComponent("Sources", isDirectory: true)
        if let walker = FileManager.default.enumerator(
            at: sources, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])
        {
            for case let url as URL in walker
            where watchedExtensions.contains(url.pathExtension.lowercased()) {
                found.append(url)
            }
        }
        found += assets(under: sources)
        // 置き場の中の `.swift` は両方の数え方に当たるので、1 度に畳む
        var seen = Set<String>()
        return found.filter { seen.insert($0.path).inserted }.sorted { $0.path < $1.path }
    }

    /// 資材の置き場の下の、数えるファイル。
    ///
    /// **包みの中まで降りる** (`.skipsPackageDescendants` を付けない)。`.copy` は置き場を
    /// 丸ごと写すので、包みの形をしたディレクトリの中身もビルドに入る。
    private static func assets(under sources: URL) -> [URL] {
        guard
            let targets = try? FileManager.default.contentsOfDirectory(
                at: sources, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        else { return [] }
        var found: [URL] = []
        for target in targets {
            let place = target.appendingPathComponent(
                ResourceDeclaration.directoryName, isDirectory: true)
            guard
                let walker = FileManager.default.enumerator(
                    at: place, includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles])
            else { continue }
            for case let url as URL in walker
            where !unwatchedAssetExtensions.contains(url.pathExtension.lowercased()) {
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true
                else { continue }
                found.append(url)
            }
        }
        return found
    }

    /// 世代を読む。**属性の変わらないファイルは読み直さない。**
    ///
    /// 巡回は 0.25 秒ごとに来るので、毎回すべての中身を読むと、資材の置き場に置かれた動画や
    /// モデルのような大きなファイルを読み続けることになる (#2312)。ファイルごとに中身の要約と
    /// 属性 (大きさ・更新時刻・ファイル番号) を控え、属性が前回と同じなら控えの要約を使う。
    /// **世代は中身から導いたまま** — 要約は中身から作り、属性は読み直すかを決めるだけに使う。
    /// 編集して元に戻せば、同じ世代を名乗る。
    ///
    /// ファイル番号も見るのは、置き換え (別のファイルを書いてから名前を付け替える保存) で
    /// 大きさと更新時刻がたまたま揃っても、読み直すため。
    final class Reader {
        /// 控え。**いま数えているファイルの分だけを持つ** (消えたファイルの分は次の読みで落とす)。
        private var kept: [String: Kept] = [:]
        /// 中身を読む口。**検査から読んだ回数を数えられる形にしてある。**
        private let read: (URL) -> Data?

        private struct Kept {
            let attributes: Attributes
            let digest: Data
        }

        private struct Attributes: Equatable {
            let size: Int
            let modified: Date
            let number: Int
        }

        init(read: @escaping (URL) -> Data? = { try? Data(contentsOf: $0) }) {
            self.read = read
        }

        /// いまの世代。読めるファイルが 1 つも無ければ `nil`。
        func current(for directory: URL) -> String? {
            let files = SourceStamp.sources(in: directory)
            guard !files.isEmpty else { return nil }
            var hasher = SHA256()
            var next: [String: Kept] = [:]
            for file in files {
                guard let digest = digest(of: file, keeping: &next) else { continue }
                // 名前も混ぜる。中身が同じファイルの名前だけが変わった場合も別の世代になる
                hasher.update(data: Data(file.path.utf8))
                hasher.update(data: digest)
            }
            kept = next
            return hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(12)
                .description
        }

        /// 中身の要約。属性が控えと同じなら読まずに控えを返す。読めなければ `nil`。
        ///
        /// **属性は読む前に取る。** 取ってから読むまでの間に書き換わっても、控えの属性は
        /// 古いほうなので、次の読みで食い違って読み直す (取り違えは読み直しの側へ倒れる)。
        private func digest(of file: URL, keeping next: inout [String: Kept]) -> Data? {
            let attributes = Self.attributes(of: file)
            if let attributes, let previous = kept[file.path], previous.attributes == attributes {
                next[file.path] = previous
                return previous.digest
            }
            guard let contents = read(file) else { return nil }
            let digest = Data(SHA256.hash(data: contents))
            if let attributes { next[file.path] = Kept(attributes: attributes, digest: digest) }
            return digest
        }

        private static func attributes(of file: URL) -> Attributes? {
            guard let found = try? FileManager.default.attributesOfItem(atPath: file.path),
                let size = (found[.size] as? NSNumber)?.intValue,
                let modified = found[.modificationDate] as? Date,
                let number = (found[.systemFileNumber] as? NSNumber)?.intValue
            else { return nil }
            return Attributes(size: size, modified: modified, number: number)
        }
    }
}
