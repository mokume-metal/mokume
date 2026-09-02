// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 依存として mokume を引いた消費側の配置を模す。
///
/// **複数の suite が同じものを要る** — 面の仕様の在処を解く検査 (窓口) と、依存が持たない
/// 面を見る検査 ([#647])。片方に private で置くと、もう片方が写しを持ち、SwiftPM が
/// `workspace-state.json` の形を変えた日に 2 箇所を直すことになる。
///
/// [#647]: https://github.com/mokume-metal/mokume/issues/647
enum ConsumerFixture {
    /// 使い捨てのディレクトリ。
    static func makeDirectory(_ label: String = "consumer") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mokume-\(label)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// - Parameters:
    ///   - name: 依存の `packageRef.name`。取り違えの検査から変える
    ///   - local: パスで指した依存 (実体は作業ディレクトリの外) を模すなら `true`
    ///   - facets: 依存が持つ面の応答の仕様 (`observe` なら `observe-report.schema.json`)。
    ///     **選べる形にしてある** — 面は版によって増えるので、古い版を模すには一部だけを
    ///     置く必要がある (#647)
    static func make(
        name: String = "mokume", local: Bool = false, facets: [String] = ["observe"]
    ) throws -> (work: URL, schemas: URL) {
        let work = try makeDirectory("consumer")
        let package = try local
            ? makeDirectory("dependency")
            : work.appendingPathComponent(".build/checkouts/mokume", isDirectory: true)
        let schemas = package.appendingPathComponent("Schemas", isDirectory: true)
        try FileManager.default.createDirectory(at: schemas, withIntermediateDirectories: true)
        for facet in facets {
            // **仕様の名前は一覧が名乗る。** 組み立てると、応答を持たない一方通行の面
            // (`viewport`) がどの版でも「持たない」側に落ちる (#703)
            let name = StartupReads.all.first { $0.key == facet }?.schemaName ?? "\(facet)-report"
            try Data(#"{"$id":"\#(name)"}"#.utf8)
                .write(to: schemas.appendingPathComponent("\(name).schema.json"))
        }

        // 実測した形 (version 7)。パスで指したものは絶対パスがそのまま載る
        let state = local
            ? "{\"name\":\"fileSystem\",\"path\":\"\(package.path)\"}"
            : "{\"name\":\"sourceControlCheckout\",\"checkoutState\":{\"revision\":\"0000\"}}"
        let document = """
            {"object":{"artifacts":[],"dependencies":[{"basedOn":null,\
            "packageRef":{"identity":"\(local ? package.lastPathComponent : name)",\
            "kind":"\(local ? "fileSystem" : "remoteSourceControl")",\
            "location":"https://example.com/\(name).git","name":"\(name)"},\
            "state":\(state),"subpath":"mokume"}],"prebuilts":[]},"version":7}
            """
        let build = work.appendingPathComponent(".build", isDirectory: true)
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: true)
        try Data(document.utf8).write(to: build.appendingPathComponent("workspace-state.json"))
        return (work, schemas)
    }
}
