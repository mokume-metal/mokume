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

    /// 資材の置き場の中でも数えないもの。**断片は置き場の中でも数えない** — #279 の決定
    /// (作り直さずに走らせたまま差し替える) を置き場の中でも保つ。
    ///
    /// **ただし置き場の断片は、いまは走らせたまま差し替わらない。** 見張りの子が断片を探すと
    /// ビルドが束へ写した写しに解け、断片の見張りはその写しを見るので、置き場の元のファイルを
    /// 保存しても写しは変わらない (#2312 の完了条件 5 で、見張りの下で確かめた)。どちらへ
    /// 直すか (作り直すか・子に元の在処を読ませるか) は選択が要るので、ここでは数えないまま
    /// 別の Issue で扱う。
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
    ///
    /// **読んだ時刻に近い更新時刻の控えは信じない** (``racyWindow``)。更新時刻の刻みが粗い
    /// ボリューム (HFS+ は 1 秒・FAT は 2 秒) では、読んだのと同じ刻みの中で同じ大きさのまま
    /// 上書きされると、属性が揃ったまま中身だけが変わる。控えが無かった頃は毎回中身を読んで
    /// いたので、「変われば必ず変わる」をそこで後退させない (版管理の道具が「読んだ直後の
    /// 書き換え」に対して取るのと同じ守り)。
    final class Reader {
        /// 更新時刻からこれだけ経ってから読んだファイルだけ、控えを信じる。**最も粗い刻み
        /// (FAT の 2 秒) に合わせる。** 保存した直後の数回の巡回だけ読み直しが続く。
        static let racyWindow: TimeInterval = 2

        /// 控え。**いま数えているファイルの分だけを持つ** (消えたファイルの分は次の読みで落とす)。
        private var kept: [String: Kept] = [:]
        /// 中身の要約を取る口。**検査から呼んだ回数を数えられる形にしてある。**
        private let summarize: (URL) -> Data?

        private struct Kept {
            let attributes: Attributes
            let digest: Data
            /// 要約を取った時刻。控えを信じてよいかを ``racyWindow`` で決める。
            let readAt: Date
        }

        private struct Attributes: Equatable {
            let size: Int
            let modified: Date
            let number: Int
        }

        init(summarize: @escaping (URL) -> Data? = Reader.digest(of:)) {
            self.summarize = summarize
        }

        /// 中身の要約 (SHA-256)。読めなければ `nil`。
        ///
        /// **少しずつ読む。** 丸ごと読むと、置き場の動画やモデルの大きさぶんの記憶を巡回の中で
        /// 取る。写像 (`mmap`) で読む形は採らない — 読んでいる間に別の手がファイルを切り詰めると、
        /// 道具ごと落ちる (SIGBUS)。
        nonisolated static func digest(of file: URL) -> Data? {
            guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
            defer { try? handle.close() }
            var hasher = SHA256()
            while true {
                // 終わりに着くと `nil` (空のこともある) が返る。読めなかったときだけ投げる
                let chunk: Data?
                do { chunk = try handle.read(upToCount: 1 << 20) } catch { return nil }
                guard let chunk, !chunk.isEmpty else { break }
                hasher.update(data: chunk)
            }
            return Data(hasher.finalize())
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

        /// 中身の要約。属性が控えと同じで、控えが更新時刻から十分に後に取られていれば、読まずに
        /// 控えを返す。読めなければ `nil`。
        ///
        /// **属性は読む前に取る。** 取ってから読むまでの間に書き換わっても、控えの属性は
        /// 古いほうなので、次の読みで食い違って読み直す (取り違えは読み直しの側へ倒れる)。
        private func digest(of file: URL, keeping next: inout [String: Kept]) -> Data? {
            let attributes = Self.attributes(of: file)
            if let attributes, let previous = kept[file.path], previous.attributes == attributes,
                previous.readAt.timeIntervalSince(attributes.modified) >= Self.racyWindow
            {
                next[file.path] = previous
                return previous.digest
            }
            let readAt = Date()
            guard let summary = summarize(file) else { return nil }
            if let attributes {
                next[file.path] = Kept(attributes: attributes, digest: summary, readAt: readAt)
            }
            return summary
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
