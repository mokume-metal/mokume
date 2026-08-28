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
    /// 図形をひととおり。
    case primitives
    /// 同じ引数を 4 通りの読み方で置いたもの。
    case origins
    /// 線の端の形 3 通りを、太さを振って並べたもの。
    case caps
    /// 折れ目の形 3 通り。
    case joins
    /// 混ぜ方 10 通りを、同じ下地の上に並べたもの。
    case blends
    /// 自由に並べた頂点・曲線・穴・切り抜き。
    case freeform
    /// 書体・大きさ・整列・行送りを振った文字。
    ///
    /// **このシーンだけは、この環境が持つ書体の字形に依る。** 環境の更新で字形が
    /// 変われば、絵は変わっていなくてもこの行は動く。土台の書体には版の変わりにくい
    /// ものを選んであるが、覆えない字の引き当て先までは選べない。
    case text
    /// 矩形へ流し込んだ文字と、取り出した輪郭。
    ///
    /// ``text`` と同じく、この環境が持つ書体の字形に依る。
    case textFlow
    /// 作った絵を、等倍・引き伸ばし・切り出し・色掛けで置いたもの。
    case images
    /// 描いた図形を画素として読み、書き換えて戻したもの。
    case pixels
    /// 保持した形を並べ、組にしたものを置いたもの。
    case retainedShapes

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

        case .primitives:
            canvas.background(.display(red: 0.07, green: 0.07, blue: 0.09))
            canvas.fill(.display(red: 0.95, green: 0.45, blue: 0.3))
            canvas.square(10, 10, 32)
            canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.5))
            canvas.triangle(60, 10, 88, 42, 52, 42)
            canvas.fill(.display(red: 0.35, green: 0.6, blue: 0.95))
            canvas.quad(96, 10, 120, 18, 118, 42, 94, 34)
            canvas.fill(.display(red: 0.95, green: 0.85, blue: 0.35))
            canvas.ellipse(30, 78, 44, 28)
            canvas.fill(.display(red: 0.8, green: 0.4, blue: 0.85))
            canvas.arc(84, 78, 44, 44, 0, .pi * 1.25)
            canvas.stroke(.display(red: 1, green: 1, blue: 1))
            for step in 0..<5 {
                canvas.strokeWeight(Float(step) * 2 + 2)
                canvas.point(20 + Float(step) * 22, 114)
            }

        case .origins:
            // 同じ 4 つの数を、4 通りの読み方で置く。読み方が場所と大きさを決める
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.12))
            let modes: [(ShapeMode, LinearRGBA)] = [
                (.corner, .display(red: 0.95, green: 0.4, blue: 0.3)),
                (.corners, .display(red: 0.4, green: 0.85, blue: 0.5)),
                (.center, .display(red: 0.35, green: 0.6, blue: 0.95)),
                (.radius, .display(red: 0.95, green: 0.85, blue: 0.35)),
            ]
            for (index, entry) in modes.enumerated() {
                canvas.push()
                canvas.translate(Float(index % 2) * 64, Float(index / 2) * 64)
                canvas.fill(entry.1)
                canvas.rectMode(entry.0)
                canvas.rect(20, 20, 30, 24)
                canvas.pop()
            }

        case .caps:
            // 端の形 3 通り × 太さ 3 段階。右端を揃えてあるので、伸び方の違いが並ぶ
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.12))
            canvas.stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
            let caps: [StrokeCap] = [.square, .project, .round]
            canvas.strokeWeight(18)
            for (row, cap) in caps.enumerated() {
                canvas.strokeCap(cap)
                // 左右の端を揃えてあるので、伸び方の違いがそのまま長さの差になる
                canvas.line(32, 24 + Float(row) * 40, 96, 24 + Float(row) * 40)
            }

        case .freeform:
            canvas.background(.display(red: 0.08, green: 0.08, blue: 0.1))
            // 左上: 深くへこんだ形 (扇状に分けるとはみ出す形)
            canvas.fill(.display(red: 0.95, green: 0.45, blue: 0.3))
            canvas.stroke(.display(red: 1, green: 1, blue: 1))
            canvas.strokeWeight(2)
            canvas.beginShape()
            canvas.vertex(6, 6)
            canvas.vertex(32, 40)
            canvas.vertex(58, 6)
            canvas.vertex(58, 58)
            canvas.vertex(6, 58)
            canvas.endShape(.close)

            // 右上: 穴の開いた形
            canvas.push()
            canvas.translate(64, 0)
            canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.5))
            canvas.beginShape()
            canvas.vertex(6, 6)
            canvas.vertex(58, 6)
            canvas.vertex(58, 58)
            canvas.vertex(6, 58)
            canvas.beginContour()
            canvas.vertex(20, 20)
            canvas.vertex(20, 44)
            canvas.vertex(44, 44)
            canvas.vertex(44, 20)
            canvas.endContour()
            canvas.endShape(.close)
            canvas.pop()

            // 左下: 曲線
            canvas.push()
            canvas.translate(0, 64)
            canvas.noFill()
            canvas.stroke(.display(red: 0.95, green: 0.85, blue: 0.35))
            canvas.strokeWeight(4)
            canvas.beginShape()
            canvas.vertex(6, 54)
            canvas.bezierVertex(6, 6, 58, 6, 58, 54)
            canvas.endShape()
            canvas.pop()

            // 右下: 切り抜いた中にだけ描かれる
            canvas.push()
            canvas.translate(64, 64)
            canvas.clip(76, 76, 40, 40)
            canvas.noStroke()
            canvas.fill(.display(red: 0.35, green: 0.6, blue: 0.95))
            canvas.circle(32, 32, 56)
            canvas.pop()
            canvas.noClip()

        case .blends:
            // 下地は横 3 帯。その上に、同じ色を混ぜ方だけ変えて重ねる
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.12))
            canvas.noStroke()
            let bands: [LinearRGBA] = [
                .display(red: 0.85, green: 0.25, blue: 0.2),
                .display(red: 0.2, green: 0.55, blue: 0.85),
                .display(red: 0.9, green: 0.85, blue: 0.3),
            ]
            for (index, band) in bands.enumerated() {
                canvas.fill(band)
                canvas.rect(0, Float(index) * 43, 128, 43)
            }
            let overlay = LinearRGBA.display(red: 0.5, green: 0.9, blue: 0.6, alpha: 0.85)
            for (index, mode) in BlendMode.allCases.enumerated() {
                canvas.blendMode(mode)
                canvas.fill(overlay)
                canvas.rect(
                    Float(index % 5) * 25 + 3, Float(index / 5) * 62 + 4, 20, 56)
            }

        case .text:
            canvas.background(.display(red: 0.08, green: 0.08, blue: 0.1))
            canvas.textFont("Helvetica")

            // 基準線を引いてから、その上に字を置く — 図形と字が同じ列に並ぶ
            canvas.stroke(.display(red: 0.3, green: 0.35, blue: 0.45))
            canvas.strokeWeight(1)
            canvas.line(6, 40, 122, 40)
            canvas.noStroke()
            canvas.fill(.display(red: 0.95, green: 0.85, blue: 0.35))
            canvas.textSize(28)
            canvas.text("Agj", 6, 40)

            canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.95))
            canvas.textSize(16)
            canvas.textAlign(.center)
            canvas.text("mokume", 64, 62)

            canvas.textAlign(.left, .top)
            canvas.textStyle(.bold)
            canvas.textLeading(20)
            canvas.fill(.display(red: 0.95, green: 0.45, blue: 0.3))
            canvas.text("two\nlines", 6, 72)

            // 欧文の書体が覆えない字は、環境の別の書体から引く
            canvas.textStyle(.normal)
            canvas.textAlign(.right, .bottom)
            canvas.textSize(24)
            canvas.fill(.display(red: 0.5, green: 0.9, blue: 0.6))
            canvas.text("あ", 122, 122)

        case .textFlow:
            canvas.background(.display(red: 0.08, green: 0.08, blue: 0.1))
            canvas.textFont("Helvetica")
            canvas.textSize(13)

            // 流し込む矩形を先に描いてから、その中へ流す
            canvas.noFill()
            canvas.stroke(.display(red: 0.3, green: 0.35, blue: 0.45))
            canvas.strokeWeight(1)
            canvas.rect(6, 6, 76, 56)
            canvas.noStroke()
            canvas.fill(.display(red: 0.85, green: 0.9, blue: 0.95))
            let flow = canvas.text(
                "the grain of wood shows where it grew", 6, 6, 76, 56)

            // 入りきらなかった続きは、右の細い段へ文字の切れ目で折って流す
            canvas.textWrap(.character)
            canvas.fill(.display(red: 0.5, green: 0.9, blue: 0.6))
            canvas.text(flow.remainder, 88, 6, 34, 56)

            // 輪郭は線でなぞる。塗った字と同じ場所・同じ字間に出る
            canvas.noFill()
            canvas.stroke(.display(red: 0.95, green: 0.6, blue: 0.3))
            canvas.strokeWeight(1)
            canvas.textSize(30)
            for contour in canvas.textOutline("mo", 8, 108) {
                canvas.beginShape()
                for point in contour.points { canvas.vertex(point.x, point.y) }
                canvas.endShape(.close)
            }
            canvas.noStroke()
            canvas.fill(.display(red: 0.95, green: 0.85, blue: 0.35))
            canvas.text("ku", 8 + canvas.textWidth("mo"), 108)

        case .images:
            canvas.background(.display(red: 0.08, green: 0.08, blue: 0.1))
            // 元の絵はその場で作る。ファイルを置かずに済み、絵は毎回同じになる
            guard let source = try? canvas.createImage(8, 8) else { return }
            for y in 0..<8 {
                for x in 0..<8 {
                    let checker = (x / 2 + y / 2) % 2 == 0
                    source.set(
                        x, y,
                        .display(
                            red: checker ? 0.95 : 0.15, green: Float(x) / 7,
                            blue: Float(y) / 7))
                }
            }

            // 等倍・引き伸ばし
            canvas.image(source, 6, 6)
            canvas.image(source, 24, 6, 40, 40)

            // 切り出し (右下の 4x4 だけ)
            canvas.image(source, 74, 6, 40, 40, 4, 4, 4, 4)

            // 色掛け。白は何も変えないので、掛けた側だけが変わる
            canvas.tint(.display(red: 1, green: 0.5, blue: 0.5, alpha: 0.8))
            canvas.image(source, 6, 54, 52, 52)
            canvas.noTint()

            // 図形と重ねる。画像の面を図形が読んでいないことが絵に出る
            canvas.noStroke()
            canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.95, alpha: 0.7))
            canvas.rect(66, 54, 52, 52)
            canvas.image(source, 78, 66, 28, 28)

        case .pixels:
            // 図形を描いてから、その画素を読んで書き換える。**読みと書きが同じ
            // フレームの中で起きる**ので、待つ場所が 1 つであることもここに載る
            canvas.background(.display(red: 0.06, green: 0.07, blue: 0.09))
            canvas.noStroke()
            canvas.fill(LinearRGBA(straightRed: 0.95, green: 0.45, blue: 0.2, alpha: 0.8))
            canvas.circle(48, 48, 64)
            canvas.fill(LinearRGBA(straightRed: 0.2, green: 0.7, blue: 0.95, alpha: 0.6))
            canvas.rect(56, 56, 56, 56)

            // 左半分は読んだ値をそのまま書き戻す (変わらないはず)。右半分は
            // 赤と青を入れ替える (変わるはず)。同じ絵の中に両方置く
            for y in 0..<128 {
                for x in 0..<128 {
                    let color = canvas.get(x, y)
                    canvas.set(
                        x, y,
                        x < 64
                            ? color
                            : LinearRGBA(
                                premultipliedRed: color.blue, green: color.green,
                                blue: color.red, alpha: color.alpha))
                }
            }

        case .retainedShapes:
            canvas.background(.display(red: 0.07, green: 0.08, blue: 0.1))

            // 組み立ての中で色を決める。置くときの塗りは効かない
            let leaf = canvas.createShape {
                canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.45))
                canvas.stroke(.display(red: 0.12, green: 0.35, blue: 0.2))
                canvas.strokeWeight(2)
                canvas.beginShape()
                canvas.vertex(0, -14)
                canvas.bezierVertex(10, -9, 10, 9, 0, 14)
                canvas.bezierVertex(-10, 9, -10, -9, 0, -14)
                canvas.endShape(.close)
            }
            let berry = canvas.createShape {
                canvas.noStroke()
                canvas.fill(.display(red: 0.95, green: 0.35, blue: 0.4))
                canvas.circle(0, 0, 9)
            }

            // 上段: 1 枚ずつ置く。**置く前に塗りを変えても形の色は変わらない**
            canvas.fill(.display(red: 0, green: 0, blue: 1))
            for index in 0..<4 {
                canvas.push()
                canvas.translate(22 + Float(index) * 28, 28)
                canvas.rotate(Float(index) * 0.35)
                canvas.shape(leaf)
                canvas.pop()
            }

            // 下段: 組にしたものを 1 回で置く
            let branch = Shape.group(
                (0..<6).map { index in
                    canvas.createShape {
                        canvas.push()
                        canvas.translate(Float(index) * 19, Float(index % 2) * 14)
                        canvas.shape(index % 2 == 0 ? leaf : berry)
                        canvas.pop()
                    }
                })
            canvas.shape(branch, 16, 76)

        case .joins:
            // 折れ目の形 3 通り。閉じた形の角に効くことを見るので三角形で描く
            canvas.background(.display(red: 0.1, green: 0.1, blue: 0.12))
            canvas.noFill()
            canvas.stroke(.display(red: 0.4, green: 0.85, blue: 0.95))
            canvas.strokeWeight(10)
            let joins: [StrokeJoin] = [.miter, .bevel, .round]
            for (index, join) in joins.enumerated() {
                canvas.push()
                canvas.translate(Float(index) * 40 + 4, 34)
                canvas.strokeJoin(join)
                canvas.triangle(18, 0, 34, 40, 2, 40)
                canvas.pop()
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
