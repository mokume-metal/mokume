// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// 窓口が差し出す道具立て。
///
/// **面を増やすのではなく、既にある区画の往復を包むだけ。** ここに無い能力は
/// 区画を直に読み書きすれば同じように使えるし、逆にここが増えても面は増えない。
struct Tools {
    /// 公開 API の一覧を指す名前。面の仕様と同じ入口 (`reference`) に並べる。
    static let apiDocument = "api"
    /// 起動の瞬間に決まるものの一覧を指す名前。
    ///
    /// **道具を増やさず、既にある入口の責務を広げる** (ADR-0008 決定 5)。応えないときの
    /// 案内はここを名指すので、一覧へ辿り着く経路が窓口の中で閉じる (#380)。
    static let startupDocument = "startup"

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

    /// 差し出す道具。
    ///
    /// **綴りの正典はここ 1 つ。** かつては道具の名前が一覧の定義と ``call(_:arguments:)``
    /// の `switch` に別々の文字列リテラルで並んでいて、対応を保つ機械が居なかった
    /// ([#814](https://github.com/mokume-metal/mokume/issues/814))。いまは道具を足すと
    /// 定義と呼び出しの両方が**コンパイラに問われる**。
    enum ToolName: String, CaseIterable {
        case observe
        case buildStatus = "build_status"
        case input
        case reference

        /// 名前と説明と引数の形。一覧 (`tools/list`) はこれを並べたものである。
        var definition: [String: Any] {
            ["name": rawValue, "description": description, "inputSchema": inputSchema]
        }

        var description: String {
            switch self {
            case .observe:
                "Take a shot of the running sketch. Returns where the image is, along with a breakdown (frame number, time, size, a summary of the image, how hard it is working, the values the sketch exposed, and the source stamp). One shot of the current frame by default. Set count to 2 or more to take shots in succession without stopping the frames, and a catalogue in the order taken comes back — one frame cannot tell you whether motion is right, so use this for anything that moves. A stopped sketch still returns the last frame it drew."
            case .buildStatus:
                "Return the result of the most recent build (whether it passed, the exit code, the output, a breakdown of how long it took, and the source stamp). Read this when you want to know why the drawing did not change."
            case .input:
                "Send input events to the running sketch. Coordinates are in the canvas coordinate system. The types are mouseDown / mouseUp / mouseMoved / scrolled / keyDown / keyUp. The three positional types need x and y; the two key types need code (the macOS virtual key code: 49 = Space, 0 = A, 126 = up arrow). An event missing one is counted in ignored and the rest still go through. button / dx / dy / characters / isRepeat can be left out."
            case .reference:
                "Return a document this interface serves. With no argument you get the list; pass name for one of them. Pass api for the public API of the version currently depended on (which types and functions exist, and how to call them). Pass startup for the things decided the moment a process starts (the ones that have no effect while it runs). The rest are surface specs (the shape of requests and replies)."
            }
        }

        var inputSchema: [String: Any] {
            switch self {
            case .observe:
                [
                    "type": "object",
                    "properties": [
                        "scale": [
                            "type": "number",
                            "exclusiveMinimum": 0,
                            "maximum": 1,
                            "description": "How far to scale the written image down (above 0, up to 1). Omit for full size.",
                        ],
                        "count": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": ObservationRequest.maximumCount,
                            "description":
                                "How many shots to take (1…\(ObservationRequest.maximumCount)). Omit for one.",
                        ],
                        "every": [
                            "type": "integer",
                            "minimum": 1,
                            "maximum": ObservationRequest.maximumEvery,
                            "description":
                                "Take a shot every N frames (1…\(ObservationRequest.maximumEvery)). Omit to take every frame. Counted in frames rather than seconds, so running the same sketch twice returns the same series.",
                        ],
                    ],
                ]
            case .buildStatus:
                ["type": "object", "properties": [:]]
            case .input:
                [
                    "type": "object",
                    "required": ["events"],
                    "properties": [
                        "events": [
                            "type": "array",
                            "description": "The events to send. Any number of them in one call.",
                            "items": ["type": "object"],
                        ]
                    ],
                ]
            case .reference:
                [
                    "type": "object",
                    "properties": [
                        "name": [
                            "type": "string",
                            "description": "The document's name (for example api, startup, observe-report).",
                        ]
                    ],
                ]
            }
        }
    }

    /// 一覧。名前と説明と引数の形。
    static let definitions: [[String: Any]] = ToolName.allCases.map(\.definition)

    /// 道具を呼ぶ。
    func call(_ name: String, arguments: [String: Any]) -> (text: String, isError: Bool) {
        guard let tool = ToolName(rawValue: name) else {
            return ("There is no such tool: \(name)", true)
        }
        switch tool {
        case .observe: return observe(arguments)
        case .buildStatus: return buildStatus()
        case .input: return sendInput(arguments)
        case .reference: return reference(arguments)
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
        let report: [String: Any]
        switch roundTrip(
            facet: facets.observeFacet, entry: StartupReads.observe, request: request, id: id,
            extraWait: Self.extraWait(count: count, every: every))
        {
        case .refused(let text): return (text, true)
        case .answered(let answer): report = answer
        }

        var lines: [String] = []
        let frames = (report["frames"] as? [[String: Any]]) ?? []
        var names = frames.compactMap { $0["image"] as? String }
        // **目録が無ければ単数形へ落ちる。** 目録 (#408) を書かない版のライブラリと繋がる
        // ことは避けられない — 作品は再現のために版を固定してコミットし、道具は独立に
        // 新しくなる。落ちなければ、絵が在るのに「採れませんでした」と答えることになる
        // (#635)。**判定は形から行う** — 目録を足したとき schemaVersion は据え置かれたので、
        // 版を名乗る値では新旧を分けられない (ADR-0018 決定 5 の追補)
        let manifestMissing = names.isEmpty
        if manifestMissing, let single = report["image"] as? String { names = [single] }

        if names.isEmpty {
            lines.append("No image could be taken")
        } else if names.count == 1 {
            lines.append("Image: \(facets.observeFacet.appendingPathComponent(names[0]).path)")
        } else {
            // 何枚あるかを先に言う。頼んだ枚数と食い違っていたら、そこで気付ける
            lines.append(
                """
                Images (\(names.count)): \(facets.observeFacet.path)/
                  \(names.joined(separator: " "))
                """)
        }
        // **黙って寛容にはしない。** 目録は面の仕様が要求しているもの (ADR-0018 決定 4) で、
        // 無いまま読めたのは読み手が補ったからである。補ったことは読み手が名乗る
        if manifestMissing, !names.isEmpty {
            lines.append(Self.manifestMissingNote(count: count))
        }
        lines.append(pretty(report))
        return (lines.joined(separator: "\n\n"), false)
    }

    /// 目録を書かない書き手と繋がったときに添える。
    ///
    /// **頼んだ枚数が返らないときは、そちらを先に言う。** 絵が 1 枚返っている以上、読み手は
    /// 成功と受け取る — 続けて撮ることは目録を書く版でしか成立しないので、黙っていると
    /// 「動きを見た」と誤って判断される (#635)。
    static func manifestMissingNote(count: Int) -> String {
        let cause = """
            This reply has no catalogue (frames). The mokume the sketch depends on predates
            the version that added one. The image name was read from the singular image field.
            """
        guard count > 1 else { return cause }
        return """
            \(count) shots were asked for and only one came back. \(cause)
            To take a series, update the sketch's own dependency.
            """
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
            return ("events needs an array of events", true)
        }
        let id = makeID()
        switch roundTrip(
            facet: facets.inputFacet, entry: StartupReads.input,
            request: ["id": id, "events": events], id: id)
        {
        case .refused(let text): return (text, true)
        case .answered(let report): return (pretty(report), false)
        }
    }

    /// 区画へ 1 往復した結果。
    private enum Exchange {
        /// 応答が返った。
        case answered([String: Any])
        /// 返らなかった。**何が起きたのかと、次に何をすればよいか**を持つ。
        case refused(String)
    }

    /// 区画へ要求を置き、応答が返るまで待つ。
    ///
    /// **観測と入力で骨格を 2 度書かない。** 置く → 待つ → 返らなければ「なぜ返らないか」を
    /// 名乗る、という並びは同じで、違うのは区画と要求の中身だけである。2 度書いていたころ、
    /// 片方だけが `existed` を控え忘れる形の間違いが成立していた。
    ///
    /// **区画の有無は要求を置く前に控える。** ``Facets/exchange(facet:request:id:...)`` は
    /// 待つ前に自分で区画を作るので、後から見ても「元から在ったのか」が分からなくなる
    /// ([#227](https://github.com/mokume-metal/mokume/issues/227)) — その区別で案内が
    /// 変わるので、控える場所を間違えると読み手を直らない道へ送る。
    private func roundTrip(
        facet: URL, entry: StartupReads.Entry, request: [String: Any], id: String,
        extraWait: TimeInterval = 0
    ) -> Exchange {
        let existed = facets.hasFacet(facet)
        do {
            guard
                let report = try facets.exchange(
                    facet: facet, request: request, id: id, extraWait: extraWait)
            else {
                return .refused(
                    facets.notRunning(
                        entry, existed: existed, packageDirectory: packageDirectory))
            }
            return .answered(report)
        } catch {
            return .refused(error.message)
        }
    }

    private func reference(_ arguments: [String: Any]) -> (String, Bool) {
        let name = arguments["name"] as? String
        // 公開 API は面の仕様と出所が違う (版ごとの資産) が、**入口は 1 つに保つ**
        if name == Self.apiDocument { return apiReference() }
        if name == Self.startupDocument { return (startupReference(), false) }

        let root = SchemasLocator.directory(workDirectory: packageDirectory)
        guard let name else { return (catalog(schemas: root), false) }
        guard let root else { return (schemasMissing(), true) }
        guard let text = SchemasLocator.contents(of: name, in: root) else {
            return ("There is no document by that name: \(name)", true)
        }
        return (text, false)
    }

    /// 配っているものの一覧。
    func catalog(schemas root: URL?) -> String {
        var lines = [
            "Documents this interface serves (pass one as name to get its contents):",
            "",
            "Public API:",
            "- \(Self.apiDocument) — the public API of the version currently depended on",
            "",
            "Decided at launch:",
            "- \(Self.startupDocument) — what has no effect while a process is running",
            "",
            "Surface specs:",
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
            return ("Source: \(found.source.text)\n\n\(found.text)", false)
        } catch let missing as APIListLocator.Missing {
            return (missing.advice, true)
        } catch {
            return ("Could not read the public API list: \(error)", true)
        }
    }

    /// 起動の瞬間に決まるものの一覧。
    func startupReference() -> String {
        StartupReadsReport.document(
            base: facets.directory, given: facets.workDirectoryGiven,
            package: packageDirectory)
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
