// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 窓口が差し出す道具立て。
///
/// **面を増やすのではなく、既にある区画の往復を包むだけ。** ここに無い能力は
/// 区画を直に読み書きすれば同じように使えるし、逆にここが増えても面は増えない。
struct Tools {
    /// 公開 API の一覧を指す名前。面の仕様と同じ入口 (`reference`) に並べる。
    static let apiDocument = "api"

    /// スケッチとやりとりする区画。基準は `MOKUME_WORK_DIR` が決める (#331)。
    let facets: Facets
    /// スケッチのパッケージの場所。**区画とは別の軸**で、SwiftPM に尋ねるときはこちらを
    /// 使う — `Package.swift` も `.build/` も、区画が動いてもここに留まる。
    let packageDirectory: URL
    /// 公開 API の一覧の在処。
    var apiList: APIListLocator
    /// 識別子の作り手。検査から固定できるようにする。
    var makeID: () -> String = { UUID().uuidString.prefix(8).lowercased() }

    /// 既定では 2 つの軸は重なる (区画の基準がパッケージの場所と同じ)。
    init(
        facets: Facets, packageDirectory: URL? = nil, apiList: APIListLocator? = nil,
        makeID: @escaping () -> String = { UUID().uuidString.prefix(8).lowercased() }
    ) {
        let package = packageDirectory ?? facets.directory
        self.facets = facets
        self.packageDirectory = package
        self.apiList = apiList ?? APIListLocator(directory: package)
        self.makeID = makeID
    }

    /// 一覧。名前と説明と引数の形。
    static let definitions: [[String: Any]] = [
        [
            "name": "observe",
            "description":
                "走っているスケッチを撮り、絵の場所と内訳 (フレーム番号・時刻・大きさ・絵の要約・走らせている重さ・スケッチが差し出した値・版の刻印) を返す。既定は現在のフレーム 1 枚。count を 2 以上にすると、フレームを止めずに続けて撮り、撮った順の目録が返る — 動きが正しいかは 1 枚では判定できないので、動くものを見るときはこちらを使う。止まっているスケッチでも最後に描いた絵が返る。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "scale": [
                        "type": "number",
                        "description": "書き出す絵の縮小率 (0 より大きく 1 以下)。省略すると実寸。",
                    ],
                    "count": [
                        "type": "integer",
                        "description": "撮る枚数 (1…120)。省略すると 1 枚。",
                    ],
                    "every": [
                        "type": "integer",
                        "description": "何フレームおきに撮るか (1…60)。省略すると毎フレーム。秒ではなくフレームで数えるので、同じスケッチを 2 回走らせれば同じ列が返る。",
                    ],
                ],
            ],
        ],
        [
            "name": "build_status",
            "description":
                "直近の作り直しの結果 (成否・終了コード・出力・分解した所要時間・版の刻印) を返す。絵が変わらない理由を知りたいときに読む。",
            "inputSchema": ["type": "object", "properties": [:]],
        ],
        [
            "name": "input",
            "description":
                "走っているスケッチへ入力の出来事を送る。座標はキャンバスの座標系。種別は mouseDown / mouseUp / mouseMoved / scrolled / keyDown / keyUp。位置の 3 種には x と y、キーの 2 種には code が要る (欠けた 1 件は ignored に数えられ、残りは通る)。button / dx / dy / characters / isRepeat は省略できる。",
            "inputSchema": [
                "type": "object",
                "required": ["events"],
                "properties": [
                    "events": [
                        "type": "array",
                        "description": "送る出来事の並び。1 回にいくつでも入れられる。",
                        "items": ["type": "object"],
                    ]
                ],
            ],
        ],
        [
            "name": "reference",
            "description":
                "窓口が配る文書を返す。引数を省くと一覧、name を渡すとその 1 つ。name に api を渡すと、いま依存している版の公開 API (どんな型と関数があり、どう呼ぶか)。ほかは面の仕様 (要求と応答の形)。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": [
                        "type": "string",
                        "description": "文書の名前 (例: api, observe-report)。",
                    ]
                ],
            ],
        ],
    ]

    /// 道具を呼ぶ。
    func call(_ name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        switch name {
        case "observe": observe(arguments)
        case "build_status": buildStatus()
        case "input": sendInput(arguments)
        case "reference": reference(arguments)
        default: ("知らない道具です: \(name)", true)
        }
    }

    private func observe(_ arguments: [String: Any]) -> (String, Bool) {
        let id = makeID()
        var request: [String: Any] = ["id": id]
        if let scale = arguments["scale"] as? Double { request["scale"] = scale }
        let count = max(1, arguments["count"] as? Int ?? 1)
        let every = max(1, arguments["every"] as? Int ?? 1)
        if count > 1 { request["count"] = count }
        if every > 1 { request["every"] = every }
        // 区画の有無は **要求を置く前**に控える — exchange は待つ前に自分で作るので、
        // 後から見ても分からなくなる (#227)
        let existed = facets.hasFacet(facets.observeFacet)
        let answer: [String: Any]?
        do {
            answer = try facets.exchange(
                facet: facets.observeFacet, request: request, id: id,
                extraWait: Self.extraWait(count: count, every: every))
        } catch {
            return ("観測の要求を置けませんでした: \(error)", true)
        }
        guard let report = answer else {
            return (Facets.notRunning(facet: facets.observeFacet, existed: existed), true)
        }

        var lines: [String] = []
        let frames = (report["frames"] as? [[String: Any]]) ?? []
        let names = frames.compactMap { $0["image"] as? String }
        if names.isEmpty {
            lines.append("絵は採れませんでした")
        } else if names.count == 1 {
            lines.append("絵: \(facets.observeFacet.appendingPathComponent(names[0]).path)")
        } else {
            // 何枚あるかを先に言う。頼んだ枚数と食い違っていたら、そこで気付ける
            lines.append(
                """
                絵 \(names.count) 枚: \(facets.observeFacet.path)/
                  \(names.joined(separator: " "))
                """)
        }
        lines.append(pretty(report))
        return (lines.joined(separator: "\n\n"), false)
    }

    /// 列を撮り終えるまでにかかるぶん、待ちに足す時間。
    ///
    /// 撮り終えるまでにフレームが `(count - 1) * every + 1` 枚ぶん進む。**足さないと、
    /// 応答は後から正しく書かれるのに読み手だけが諦めた状態**になり、次の要求が
    /// その古い目録を掴む。
    ///
    /// フレームレートは分からないので、遅い側 (30fps) を見込んで換算する。
    static func extraWait(count: Int, every: Int) -> TimeInterval {
        Double((count - 1) * every + 1) / 30
    }

    private func buildStatus() -> (String, Bool) {
        guard let status = facets.read(facets.buildStatus) else {
            return (
                """
                作り直しの記録がありません。見張る道具 (`\(Command.name) watch`) がまだ
                走っていないか、一度も作り直していません。
                """, true
            )
        }
        return (pretty(status), false)
    }

    private func sendInput(_ arguments: [String: Any]) -> (String, Bool) {
        guard let events = arguments["events"] as? [[String: Any]] else {
            return ("events に出来事の並びが要ります", true)
        }
        let id = makeID()
        let existed = facets.hasFacet(facets.inputFacet)
        let answer: [String: Any]?
        do {
            answer = try facets.exchange(
                facet: facets.inputFacet, request: ["id": id, "events": events], id: id)
        } catch {
            return ("入力の要求を置けませんでした: \(error)", true)
        }
        guard let report = answer else {
            return (Facets.notRunning(facet: facets.inputFacet, existed: existed), true)
        }
        return (pretty(report), false)
    }

    private func reference(_ arguments: [String: Any]) -> (String, Bool) {
        let name = arguments["name"] as? String
        // 公開 API は面の仕様と出所が違う (版ごとの資産) が、**入口は 1 つに保つ**
        if name == Self.apiDocument { return apiReference() }

        let root = SchemasLocator.directory(workDirectory: packageDirectory)
        guard let name else { return (catalog(schemas: root), false) }
        guard let root else { return (schemasMissing(), true) }
        guard let text = SchemasLocator.contents(of: name, in: root) else {
            return ("そういう名前の文書はありません: \(name)", true)
        }
        return (text, false)
    }

    /// 配っているものの一覧。
    func catalog(schemas root: URL?) -> String {
        var lines = [
            "窓口が配る文書 (name に渡すと中身が返ります):",
            "",
            "公開 API:",
            "- \(Self.apiDocument) — いま依存している版の公開 API の一覧",
            "",
            "面の仕様:",
        ]
        if let root {
            lines += SchemasLocator.names(in: root).map { "- \($0)" }
        } else {
            lines.append(schemasMissing())
        }
        return lines.joined(separator: "\n")
    }

    /// 公開 API の一覧。**どこから得たかを添える。**
    private func apiReference() -> (String, Bool) {
        do {
            let found = try apiList.read()
            return ("出所: \(found.source.text)\n\n\(found.text)", false)
        } catch let missing as APIListLocator.Missing {
            return (missing.advice, true)
        } catch {
            return ("公開 API の一覧を読めませんでした: \(error)", true)
        }
    }

    /// 面の仕様が見つからないときの答え。**どこを見たかまで書く。**
    func schemasMissing() -> String {
        let searched = SchemasLocator.candidates(workDirectory: packageDirectory)
            .map { "- \($0.path)" }.joined(separator: "\n")
        return """
            面の仕様が見つかりません。次の場所を見ました:

            \(searched)

            mokume を依存として引いているなら、そのディレクトリで一度 `swift build` を
            打つと実体が置かれ、そこから読めるようになります。窓口を別のディレクトリで
            立てているなら、スケッチのディレクトリを渡してください
            (`\(Command.name) mcp <ディレクトリ>`)。
            """
    }

    private func pretty(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "\(object)" }
        return text
    }
}
