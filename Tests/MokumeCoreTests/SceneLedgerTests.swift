// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Testing

@testable import MokumeCore

/// 代表シーンの絵が、台帳に記録した時点から**変わっていない**ことを見る。
///
/// ## 何を見て、何を見ないか
///
/// 見るのは退行だけである。**新しい絵が正しいかは判定できない** — 台帳の行は
/// 「誰かがこの絵を見て正しいと認めた」という記録でしかない。絵の正しさは目が
/// 判定し、ここは「触っていない絵が動いていないか」だけを受け持つ ([ADR-0019] 決定 1)。
///
/// 役割は**ゲートではなく可視化**である。共通部分を触った変更が他の絵まで変えたとき、
/// それが台帳の差分の行として現れ、レビューする目が「この変更でなぜこの絵が変わるのか」
/// を問えるようにする ([ADR-0019] 決定 3)。
///
/// ## 指紋の取り方
///
/// **出力段を通した 8 bit の画素**から取る ([ADR-0011] 決定 6 の量子化点)。作業空間の
/// 半精度の生値では取らない — 視覚的に等価な最下位ビットの揺れで落ちるため。
///
/// **PNG のバイトからも取らない。** 画像の符号化器の版に依存させると、絵が 1 画素も
/// 変わっていないのに OS の更新で台帳が全滅する。
///
/// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
@Suite(
    "代表シーンの台帳",
    .enabled(
        if: RenderDevice.isAvailable,
        "この世代のコマンド構造に対応した GPU が無い実行環境ではスキップする")
)
struct SceneLedgerTests {
    @Test("台帳に記録した絵が変わっていない", arguments: Scene.allCases)
    func sceneMatchesLedger(_ scene: Scene) throws {
        let ledger = try Ledger.load()
        let digest = try Self.fingerprint(of: scene)

        guard let recorded = ledger[scene.rawValue] else {
            Issue.record(
                """
                シーン \(scene.rawValue) が台帳に無い。
                新しいシーンなら、次の 1 行を \(Ledger.relativePath) へ足す:

                    \(scene.rawValue) \(digest)

                足す前に、そのシーンの絵を目で見て正しいことを確かめる — 台帳の行は
                「この絵を正しいと認めた」という記録であって、正しさの根拠ではない。
                絵は次で書き出せる:

                    MOKUME_LEDGER_DUMP_DIR=/tmp/scenes swift test --filter SceneLedger
                """)
            return
        }

        if digest == recorded { return }

        // 不一致。もう一度描いて「絵が変わった」と「決定論が壊れた」を切り分ける。
        // 切り分けずに報告すると、台帳を書き換えてはいけない場面で書き換えられる
        let again = try Self.fingerprint(of: scene)
        if again == digest {
            Issue.record(
                """
                シーン \(scene.rawValue) の絵が変わった。
                (同じシーンを 2 回描いた結果は一致するので、決定論は効いている)

                意図した変更なら、\(Ledger.relativePath) の行を次へ書き換え、
                before / after を PR の証跡に載せる:

                    \(scene.rawValue) \(digest)

                意図していないなら、この変更が触った共通部分が他の絵まで変えている。
                台帳は先に書き換えず、なぜ変わったかを先に調べる。
                """)
        } else {
            Issue.record(
                """
                シーン \(scene.rawValue) が、同じ入力から違う絵を出している (決定論が壊れている)。
                1 回目 \(digest) / 2 回目 \(again)

                **台帳を書き換えてはならない。** 台帳は「変わっていないこと」しか見られないので、
                同じ絵が出ない状態では何も守れない。先に決定論を直す。
                """)
        }
    }

    /// シーンを描いて、出力段を通した 8 bit の画素から指紋を取る。
    ///
    /// `MOKUME_LEDGER_DUMP_DIR` が指してあれば、そこへ絵も書き出す。台帳へ行を足す・
    /// 書き換えるときは**絵を目で見る**必要があり (台帳の行はそれを認めた記録なので)、
    /// その手段を機構自身が持つ。既定では 1 枚も書かない。
    static func fingerprint(of scene: Scene) throws -> String {
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: scene.size.width, height: scene.size.height)
        let canvas = try Canvas(target: target, gpu: gpu)
        try canvas.draw { scene.draw(on: canvas) }
        let image = try target.encodeForDisplay()

        if let dir = ProcessInfo.processInfo.environment["MOKUME_LEDGER_DUMP_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(scene.rawValue).png")
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
            try target.writePNG(to: url)
        }

        return SHA256.hash(data: Data(image.bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - シーン

/// 台帳に載せる代表シーン。
///
/// **いま描ける道具だけで組む。** 道具が増えるたびにシーンを足す — 描けるものが
/// 増えても台帳が古いままだと、新しい経路の退行は誰も見ないことになる。
enum Scene: String, CaseIterable, Sendable {
    /// 図形をひととおり並べたもの。
    case shapes
    /// 変換を積んで同じ図形を置いたもの。
    case transforms
    /// 太さを変えた線。
    case strokes

    var size: (width: Int, height: Int) { (128, 128) }

    func draw(on canvas: Canvas) {
        switch self {
        case .shapes:
            canvas.background(.display(red: 0.08, green: 0.09, blue: 0.12))
            canvas.fill(.display(red: 0.95, green: 0.35, blue: 0.2))
            canvas.rect(12, 12, 40, 28)
            canvas.fill(.display(red: 0.3, green: 0.7, blue: 0.95))
            canvas.circle(88, 40, 44)
            canvas.stroke(.display(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.line(12, 96, 116, 72)

        case .transforms:
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.1))
            canvas.fill(.display(red: 0.9, green: 0.8, blue: 0.2))
            for step in 0..<4 {
                canvas.push()
                canvas.translate(24 + Float(step) * 24, 64)
                canvas.rotate(Float(step) * 0.4)
                canvas.scale(1 + Float(step) * 0.2, 1)
                canvas.rect(-8, -8, 16, 16)
                canvas.pop()
            }

        case .strokes:
            canvas.background(.display(red: 1, green: 1, blue: 1))
            canvas.stroke(.display(red: 0.1, green: 0.1, blue: 0.1))
            for step in 0..<5 {
                canvas.strokeWeight(Float(step) * 2 + 1)
                let y = 16 + Float(step) * 24
                canvas.line(16, y, 112, y)
            }
        }
    }
}

// MARK: - 台帳

/// シーンの指紋を記録したテキスト。
///
/// リポジトリの中にテキストで置くので、**差分として読める** — 台帳の行が動いたことが
/// PR に現れるのがこの機構の目的なので、置き場と形式はそこから決まる
/// ([ADR-0019] 決定 3)。画像の実体は置かない ([ADR-0001] 原則 7)。
///
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
/// [ADR-0019]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0019-drawing-verification.md
enum Ledger {
    static let relativePath = "Tests/MokumeCoreTests/scene-ledger.txt"

    static var url: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("scene-ledger.txt")
    }

    /// シーン名 → 指紋。`#` で始まる行と空行は読み飛ばす。
    static func load() throws -> [String: String] {
        let text = try String(contentsOf: url, encoding: .utf8)
        var entries: [String: String] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }
            let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
            guard parts.count == 2 else { continue }
            entries[String(parts[0])] = String(parts[1])
        }
        return entries
    }
}
