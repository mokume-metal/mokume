// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 文字列と表を URL から読む (#2470)。JSON・XML (#2070) と同じ決まりで、名前が `http://` か
/// `https://` で始まれば URL から読む。走っているスケッチも GPU も要らない。
///
/// **URL は外へ出ない。** 応答は ``CannedResponses`` が予約済みの `.test` の名前で返す。
@Suite("文字列と表を URL から読む")
struct DataFromURLTests {
    final class Bare: Sketch {
        init() {}
        func draw() {}
    }

    private static let sheet = "date,high,low\n2025-01-01,8.5,1.5\n2025-01-02,10,2\n"

    // MARK: - 表

    @Test("loadTable は URL から表を読む。見出しを使えば名前で引ける")
    func loadTableFromURL() throws {
        let url = CannedResponses.serve(Self.sheet)
        let table = try Bare().loadTable(url, header: true)
        #expect(table.rows.count == 2)
        #expect(table.rows[0].getFloat("high") == 8.5)
        #expect(table.rows[1].getFloat("low") == 2)
    }

    @Test("requestTable は loadTable と同じ表を返す")
    func requestTableFromURL() async throws {
        let url = CannedResponses.serve(Self.sheet)
        let sketch = Bare()
        let waited = try sketch.loadTable(url, header: true)
        let requested = try await sketch.requestTable(url, header: true)
        #expect(requested.rows.count == waited.rows.count)
        #expect(requested.rows[1].getFloat("high") == waited.rows[1].getFloat("high"))
        // 見出しを使わなければ、最初の行も値の行
        #expect(try await sketch.requestTable(url).rows.count == 3)
    }

    /// 表計算の道具が書く CSV は、先頭の BOM と CRLF が付くことがある。ファイルと URL で読み方を分けない。
    @Test("URL の本文も、ファイルと同じ決まりで読む (BOM と CRLF)")
    func urlBodyIsReadLikeAFile() async throws {
        let body = "\u{FEFF}date,high\r\n2025-01-01,8.5\r\n"
        let url = CannedResponses.serve(body)
        let table = try Bare().loadTable(url, header: true)
        #expect(table.rows.count == 1)
        #expect(table.rows[0].getFloat("high") == 8.5, "BOM が見出しの頭に混ざっている")
        #expect(try await Bare().requestTable(url, header: true).rows.count == 1)
    }

    @Test("壊れた CSV は、URL を名乗って malformed で投げる")
    func brokenCSVNamesTheURL() async {
        let url = CannedResponses.serve("a,b\n1,2,3\n")
        let failure = #expect(throws: DataFailure.self) { try Bare().loadTable(url, header: true) }
        guard case .malformed(let named, _, _) = failure else {
            Issue.record("malformed で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        await #expect(throws: failure!) { try await Bare().requestTable(url, header: true) }
    }

    // MARK: - 文字列

    @Test("loadStrings と requestStrings は URL から行を読む。最後の改行は行を作らない")
    func stringsFromURL() async throws {
        let url = CannedResponses.serve("first\r\n\r\nthird\r\n")
        let sketch = Bare()
        #expect(try sketch.loadStrings(url) == ["first", "", "third"])
        #expect(try await sketch.requestStrings(url) == ["first", "", "third"])
    }

    // MARK: - 届かないとき

    /// 404 の本文 (多くは HTML の案内) を読まず、届かなかったものとして投げる。JSON と同じ。
    @Test("2xx でない状態は、4 つの口とも unreachable で投げる")
    func badStatusIsUnreachableOnEveryDoor() async {
        let url = CannedResponses.serve("a,b\n1,2\n", status: 404)
        let failure = #expect(throws: DataFailure.self) { try Bare().loadTable(url, header: true) }
        guard case .unreachable(let named, let reason) = failure else {
            Issue.record("unreachable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        #expect(reason.contains("404"))
        #expect(throws: failure!) { try Bare().loadStrings(url) }
        await #expect(throws: failure!) { try await Bare().requestTable(url, header: true) }
        await #expect(throws: failure!) { try await Bare().requestStrings(url) }
    }

    @Test("繋がらない URL は unreachable で投げる")
    func connectionFailureIsUnreachable() async {
        let url = CannedResponses.serve(.fail(.cannotConnectToHost))
        let failure = #expect(throws: DataFailure.self) { try Bare().loadStrings(url) }
        guard case .unreachable(let named, _) = failure else {
            Issue.record("unreachable で投げていない: \(String(describing: failure))")
            return
        }
        #expect(named == url)
        await #expect(throws: failure!) { try await Bare().requestStrings(url) }
    }

    @Test("UTF-8 でない本文は、URL を名乗って unreadable で投げる")
    func nonUTF8BodyIsUnreadable() async {
        let url = CannedResponses.serve(.answer(status: 200, body: Data([0x61, 0xFF, 0x0A])))
        #expect(throws: DataFailure.unreadable(path: url)) { try Bare().loadTable(url) }
        await #expect(throws: DataFailure.unreadable(path: url)) { try await Bare().requestStrings(url) }
    }

    @Test("URL として組めない綴りは unreachable で投げる")
    func unusableURL() {
        let expected = DataFailure.unreachable(url: "https://", reason: "this is not a URL that can be requested")
        #expect(throws: expected) { try Bare().loadTable("https://") }
        #expect(throws: expected) { try Bare().loadStrings("https://") }
    }

    // MARK: - ファイルのまま

    @Test("http でも https でもない綴りは、これまでどおりファイルの名前として探す")
    func otherSchemesAreStillFileNames() {
        let name = "ftp://canned.test/\(UUID().uuidString).csv"
        let expected = DataFailure.notFound(path: name, searched: ImageFile.candidates(for: name).map(\.path))
        #expect(throws: expected) { try Bare().loadTable(name) }
        #expect(throws: expected) { try Bare().loadStrings(name) }
    }

    @Test("ファイルを読む道は変わらない")
    func filesAreStillRead() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-data-url-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("t.csv").path
        try Data(Self.sheet.utf8).write(to: URL(fileURLWithPath: path))
        #expect(try Bare().loadTable(path, header: true).rows.count == 2)
        #expect(try await Bare().requestStrings(path).count == 3)
    }
}
