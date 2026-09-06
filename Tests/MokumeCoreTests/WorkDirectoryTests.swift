// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// やりとりの置き場を組み立てる口と、そこに在るかを見る口 (#988)。GPU は要らない。
///
/// **判定を 1 本にしたので、境界もここ 1 箇所で押さえる。** かつては同じ 3 行が 5 箇所に
/// あり、「ファイルが在るだけでは真にしない」を検める検査はどこにも無かった — `ObjCBool`
/// の受け渡しは書き間違えると常に `false` になるので、割れても静かに壊れる。
@Suite("やりとりの置き場")
struct WorkDirectoryTests {
    /// 使い捨ての場所。**作らない** — 在るかどうかは検査の側が決める。
    private func temporaryPath(_ tag: String, isDirectory: Bool = true) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-\(tag)-\(UUID().uuidString)", isDirectory: isDirectory)
    }

    @Test("在るディレクトリは真、無い場所は偽")
    func seesDirectories() throws {
        let directory = temporaryPath("presence")
        #expect(WorkDirectory.directoryExists(at: directory) == false)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        #expect(WorkDirectory.directoryExists(at: directory))
    }

    @Test("同じ名前のファイルを「在る」と読まない")
    func doesNotMistakeAFileForADirectory() throws {
        // 区画は必ずディレクトリである。ファイルを在ると読むと、要求を置けないまま
        // 待ちに入ることになり、症状は「触っても応えない」としか出ない
        let path = temporaryPath("file", isDirectory: false)
        try Data("not a directory".utf8).write(to: path)
        #expect(WorkDirectory.directoryExists(at: path) == false)
    }

    @Test("区画の中の綴りは、要求と応答で 1 つずつ")
    func spellsTheExchangeFilesOnce() {
        let facet = WorkDirectory.facet("observe", under: URL(fileURLWithPath: "/tmp/sketch"))
        #expect(
            WorkDirectory.requestURL(under: facet).path
                == "/tmp/sketch/.mokume/observe/request.json")
        #expect(
            WorkDirectory.reportURL(under: facet).path
                == "/tmp/sketch/.mokume/observe/report.json")
    }
}
