// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// JSON を区画へ置く口 ([#989](https://github.com/mokume-metal/mokume/issues/989))。GPU は要らない。
///
/// **入口は 2 つで、名前が失敗の扱いを決める。** かつては同じ処理が 8 箇所にあり、
/// `try?` で捨てる・`warn` で名乗る・`throws` で投げるの 3 通りが混ざっていた。
@Suite("JSON を置く口")
struct AtomicFileTests {
    /// **宣言順と辞書順が違う**見本 (宣言は zebra → apple → middle)。
    private struct Sample: Encodable {
        let zebra: Int
        let apple: String
        let middle: Bool
    }

    private let sample = Sample(zebra: 1, apple: "a", middle: true)

    private func makeFacet() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 書かれた JSON に現れる鍵を、現れた順に取る。
    private func keys(in text: String) -> [String] {
        text.split(separator: "\n").compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\"") else { return nil }
            let rest = trimmed.dropFirst()
            guard let end = rest.firstIndex(of: "\"") else { return nil }
            return String(rest[..<end])
        }
    }

    @Test("鍵の並びは辞書順で決まる")
    func spellsKeysInSortedOrder() throws {
        let url = try makeFacet().appendingPathComponent("sample.json")
        try AtomicFile.writeJSON(sample, to: url)

        // 宣言順 (zebra, apple, middle) ではなく辞書順で届く。`.sortedKeys` を付けて
        // いなかった頃は辞書の走査順で、プロセスごとに変わっていた (#854 の実測)
        #expect(keys(in: try String(contentsOf: url, encoding: .utf8)) == ["apple", "middle", "zebra"])
    }

    @Test("置けたら真、置けなければ偽")
    func reportsWhetherItLanded() throws {
        let facet = try makeFacet()
        let url = facet.appendingPathComponent("report.json")
        #expect(AtomicFile.publishJSON(sample, to: url, "見本"))

        // 書き込み先を塞ぐ。**捨てたかどうかで続きが変わる呼び手が居る** —
        // 置けたときだけ識別子を控える (RemoteParams)・数を進める (ParamStore)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        #expect(AtomicFile.publishJSON(sample, to: url, "見本") == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: facet.path)
    }

    @Test("置けなかったことは、置き場所ごとに 1 度だけ名乗る")
    func namesTheFailureOnlyOnce() throws {
        let facet = try makeFacet()
        let blocked = facet.appendingPathComponent("blocked.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: facet.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: facet.path)
        }

        #expect(AtomicFile.hasWarned(about: blocked) == false)
        _ = AtomicFile.publishJSON(sample, to: blocked, "最初の名乗り")
        #expect(AtomicFile.warning(about: blocked)?.contains("最初の名乗り") == true)

        // 2 度目は黙る。つまみを掴んでいる間は入力のたびにここへ来るので、毎回言うと
        // 標準エラーが流れて他の注意が読めなくなる
        _ = AtomicFile.publishJSON(sample, to: blocked, "二度目の名乗り")
        #expect(AtomicFile.warning(about: blocked)?.contains("二度目") == false)

        // 鍵は置き場所。別の面の失敗は、別に名乗る
        let other = facet.appendingPathComponent("other.json")
        #expect(AtomicFile.hasWarned(about: other) == false)
    }
}
