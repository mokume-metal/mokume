// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 窓口が差し出す道具立て。
///
/// **面を増やすのではなく、既にある区画の往復を包むだけ。** ここに無い能力は
/// 区画を直に読み書きすれば同じように使えるし、逆にここが増えても面は増えない。
struct Tools {
    let facets: Facets
    /// 識別子の作り手。検査から固定できるようにする。
    var makeID: () -> String = { UUID().uuidString.prefix(8).lowercased() }

    /// 一覧。名前と説明と引数の形。
    static let definitions: [[String: Any]] = [
        [
            "name": "observe",
            "description":
                "走っているスケッチの現在のフレームを撮り、絵の場所と内訳 (フレーム番号・時刻・大きさ・絵の要約・走らせている重さ・スケッチが差し出した値・版の刻印) を返す。止まっているスケッチでも最後に描いた絵が返る。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "scale": [
                        "type": "number",
                        "description": "書き出す絵の縮小率 (0 より大きく 1 以下)。省略すると実寸。",
                    ]
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
                "走っているスケッチへ入力の出来事を送る。座標はキャンバスの座標系。種別は mouseDown / mouseUp / mouseMoved / scrolled / keyDown / keyUp。",
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
                "この面の仕様 (要求と応答の形) を返す。引数を省くと一覧、name を渡すとその 1 つ。",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "name": ["type": "string", "description": "仕様の名前 (例: observe-report)。"]
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
        let answer: [String: Any]?
        do {
            answer = try facets.exchange(
                facet: facets.observeFacet, request: request, id: id)
        } catch {
            return ("観測の要求を置けませんでした: \(error)", true)
        }
        guard let report = answer else { return (Facets.notRunning, true) }

        var lines: [String] = []
        if let image = report["image"] as? String {
            lines.append("絵: \(facets.observeFacet.appendingPathComponent(image).path)")
        } else {
            lines.append("絵は採れませんでした")
        }
        lines.append(pretty(report))
        return (lines.joined(separator: "\n\n"), false)
    }

    private func buildStatus() -> (String, Bool) {
        guard let status = facets.read(facets.buildStatus) else {
            return (
                """
                作り直しの記録がありません。見張る道具 (`mokume-cli watch`) がまだ
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
        let answer: [String: Any]?
        do {
            answer = try facets.exchange(
                facet: facets.inputFacet, request: ["id": id, "events": events], id: id)
        } catch {
            return ("入力の要求を置けませんでした: \(error)", true)
        }
        guard let report = answer else { return (Facets.notRunning, true) }
        return (pretty(report), false)
    }

    private func reference(_ arguments: [String: Any]) -> (String, Bool) {
        guard let root = SchemasLocator.directory() else {
            return (
                """
                面の仕様が見つかりません。この道具は依存として解決されたライブラリの
                Schemas/ を読みます。
                """, true
            )
        }
        guard let name = arguments["name"] as? String else {
            let names = SchemasLocator.names(in: root)
            return (
                "仕様の一覧 (name に渡すと中身が返ります):\n" + names.map { "- \($0)" }
                    .joined(separator: "\n"), false)
        }
        guard let text = SchemasLocator.contents(of: name, in: root) else {
            return ("そういう名前の仕様はありません: \(name)", true)
        }
        return (text, false)
    }

    private func pretty(_ object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
            let text = String(data: data, encoding: .utf8)
        else { return "\(object)" }
        return text
    }
}
