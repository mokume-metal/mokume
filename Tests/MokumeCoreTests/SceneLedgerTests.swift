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
    /// 利用者が書いた塗りで描いたもの。
    case userShader
    /// 基本の立体を並べ、回して奥行きが出る向きに置いたもの。
    case solids
    /// 光を当てた立体。底上げの光・向きを持つ光・広がりを持つ光を並べたもの。
    case lighting
    /// 頂点を並べて作った立体。穴・頂点ごとの色・線と点・書いた面の向きを並べたもの。
    case customSolids
    /// 同じ立体を、透視・平行・動かした視点の 3 通りで見たもの。
    case viewpoints
    /// 質感を振った立体。粗い/滑らか × 金属/非金属 と、自発光・遮蔽。
    case materials
    /// 周囲を置いた立体。背景と映り込み・金属と非金属。
    case surroundings
    /// 床の上に落ちた影。落とす側と受ける側を分けたもの。
    case shadows
    /// 読み込んだモデルを、そのまま置いたもの。
    case models
    /// 利用者が書いた断片で塗った立体。
    case solidShader

    var size: (width: Int, height: Int) { (128, 128) }
    /// 縞を掛ける断片。**光を通したあとの色**が `in.color` に入っているので、
    /// 掛けるだけで陰影が残る。
    static let stripes = """
        float4 paint(Fragment in, Values values) {
            float stripe = 0.55 + 0.45 * sin(in.position.y * values.pitch);
            return float4(in.color.rgb * stripe, in.color.a);
        }
        """


    /// 質感のうち 1 つ。**潰したときに絵が動くか**を測るために名前で指せる形にする。
    enum MaterialAspect: CaseIterable, Sendable {
        case shininess
        case metalness
        case ambient
        case emissive
    }

    func draw(on canvas: Canvas) { draw(on: canvas, without: nil) }

    /// 質感の指定を 1 つだけ既定へ潰して描く。
    ///
    /// **検出力の測定に使う** — 潰しても絵が動かない指定があれば、その代表シーンは
    /// その質感を写していないということになる ([ADR-0019] 決定 4)。
    func draw(on canvas: Canvas, without suppressed: MaterialAspect?) {
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

        case .userShader:
            canvas.background(.display(red: 0.06, green: 0.07, blue: 0.09))
            canvas.noStroke()

            // 面の中の位置と、渡した値から色を作る断片
            guard
                let stripes = try? canvas.makeShader(
                    """
                    float4 paint(Fragment in, Values values) {
                        float wave = 0.5 + 0.5 * sin(in.place.x * values.density);
                        return float4(values.tint.rgb * wave, 1.0);
                    }
                    """,
                    values: [
                        "density": 40,
                        "tint": .color(.display(red: 1, green: 0.55, blue: 0.25)),
                    ])
            else { return }

            canvas.shader(stripes)
            canvas.rect(0, 0, 128, 40)

            // **値を変えると、そこで区切られる。** 上と下で別の値で描かれる
            stripes.set("density", 12)
            stripes.set("tint", .color(.display(red: 0.35, green: 0.75, blue: 1)))
            canvas.rect(0, 44, 128, 40)

            // 組み込みの塗りへ戻せば、いつもの図形が描ける
            canvas.resetShader()
            canvas.fill(.display(red: 0.9, green: 0.85, blue: 0.3))
            canvas.circle(64, 106, 32)

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

        case .solids:
            canvas.background(.display(red: 0.07, green: 0.07, blue: 0.09))
            // 3 x 2 に並べる。どれも回してあるので、輪郭だけで形が読める
            let places: [(x: Float, y: Float)] = [
                (32, 34), (64, 34), (96, 34), (32, 94), (64, 94), (96, 94),
            ]

            canvas.fill(.display(red: 0.95, green: 0.45, blue: 0.3))
            canvas.push()
            canvas.translate(places[0].x, places[0].y, 0)
            canvas.rotateX(0.5)
            canvas.rotateY(0.7)
            canvas.box(26)
            canvas.pop()

            canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.5))
            canvas.push()
            canvas.translate(places[1].x, places[1].y, 0)
            canvas.sphere(14)
            canvas.pop()

            canvas.fill(.display(red: 0.35, green: 0.6, blue: 0.95))
            canvas.push()
            canvas.translate(places[2].x, places[2].y, 0)
            canvas.rotateX(0.6)
            canvas.plane(30, 24)
            canvas.pop()

            canvas.fill(.display(red: 0.9, green: 0.8, blue: 0.2))
            canvas.push()
            canvas.translate(places[3].x, places[3].y, 0)
            canvas.rotateX(0.5)
            canvas.rotateZ(0.3)
            canvas.cylinder(11, 28)
            canvas.pop()

            canvas.fill(.display(red: 0.85, green: 0.4, blue: 0.75))
            canvas.push()
            canvas.translate(places[4].x, places[4].y, 0)
            canvas.rotateX(0.5)
            canvas.cone(13, 28)
            canvas.pop()

            canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.9))
            canvas.push()
            canvas.translate(places[5].x, places[5].y, 0)
            canvas.rotateX(0.9)
            canvas.torus(13, 5)
            canvas.pop()

        case .lighting:
            canvas.background(.display(red: 0.05, green: 0.05, blue: 0.07))
            // 底上げ + 斜め上から差す光。縦軸は下向きなので、上から差す光の向きは +y
            canvas.ambientLight(.opaque(red: 0.18, green: 0.18, blue: 0.22))
            canvas.directionalLight(.opaque(red: 0.9, green: 0.85, blue: 0.75), -0.45, 0.8, -0.4)
            // 手前の右下から当てる差し色
            canvas.pointLight(.opaque(red: 0.25, green: 0.4, blue: 0.9), 120, 110, 90)

            canvas.fill(.display(red: 0.9, green: 0.9, blue: 0.92))
            canvas.push()
            canvas.translate(38, 44, 0)
            canvas.sphere(24)
            canvas.pop()

            canvas.fill(.display(red: 0.95, green: 0.5, blue: 0.3))
            canvas.push()
            canvas.translate(92, 40, 0)
            canvas.rotateX(0.6)
            canvas.rotateY(0.8)
            canvas.box(38)
            canvas.pop()

            canvas.fill(.display(red: 0.5, green: 0.85, blue: 0.6))
            canvas.push()
            canvas.translate(64, 98, 0)
            canvas.rotateX(1.1)
            canvas.torus(28, 10)
            canvas.pop()

        case .materials:
            // 上の列が非金属、下の列が金属。左から右へ、粗い面から滑らかな面へ
            canvas.background(.display(red: 0.04, green: 0.05, blue: 0.07))
            canvas.ambientLight(.opaque(red: 0.16, green: 0.16, blue: 0.18))
            canvas.directionalLight(
                .opaque(red: 0.7, green: 0.68, blue: 0.62), -0.35, 0.5, -0.8)
            canvas.noStroke()

            let sharpness: [Float] = [3, 24, 160]
            for (column, shininess) in sharpness.enumerated() {
                for (row, metalness) in [Float(0), 1].enumerated() {
                    canvas.fill(.display(red: 0.85, green: 0.78, blue: 0.6))
                    canvas.shininess(suppressed == .shininess ? 0 : shininess)
                    canvas.metalness(suppressed == .metalness ? 0 : metalness)
                    canvas.push()
                    canvas.translate(24 + Float(column) * 40, 30 + Float(row) * 38, 0)
                    canvas.sphere(17)
                    canvas.pop()
                }
            }

            // 左下: 自ら出す光。右下: 周りの光を返さない (物陰のような面)
            canvas.shininess(0)
            canvas.metalness(0)
            canvas.fill(.display(red: 0.3, green: 0.32, blue: 0.4))
            canvas.emissive(
                suppressed == .emissive
                    ? .opaque(red: 0, green: 0, blue: 0)
                    : .display(red: 0.55, green: 0.25, blue: 0.1))
            canvas.push()
            canvas.translate(38, 106, 0)
            canvas.rotateX(0.5)
            canvas.rotateY(0.7)
            canvas.box(30)
            canvas.pop()

            canvas.emissive(.opaque(red: 0, green: 0, blue: 0))
            canvas.ambient(
                suppressed == .ambient
                    ? .opaque(red: 1, green: 1, blue: 1)
                    : .display(red: 0.2, green: 0.2, blue: 0.25))
            canvas.push()
            canvas.translate(90, 106, 0)
            canvas.rotateX(0.5)
            canvas.rotateY(0.7)
            canvas.box(30)
            canvas.pop()

        case .surroundings:
            // 周囲と、斜め上から差す光を 1 つ。**周囲は光に足されるだけ**なので、
            // 非金属は光で陰影が付き、金属は周囲だけで形が出る
            canvas.surroundings(.sky)
            canvas.background(.sky)
            canvas.ambientLight(.opaque(red: 0.16, green: 0.16, blue: 0.18))
            canvas.directionalLight(
                .opaque(red: 0.6, green: 0.58, blue: 0.5), -0.4, 0.5, -0.75)
            canvas.noStroke()

            // 上の列: 非金属 / 粗い金属 / 磨いた金属。金属は上下に染まって形が出る
            let finishes: [(metalness: Float, shininess: Float)] = [
                (0, 40), (1, 0), (1, 140),
            ]
            for (column, finish) in finishes.enumerated() {
                canvas.fill(.display(red: 0.85, green: 0.85, blue: 0.87))
                canvas.metalness(finish.metalness)
                canvas.shininess(finish.shininess)
                canvas.push()
                canvas.translate(24 + Float(column) * 40, 38, 0)
                canvas.sphere(17)
                canvas.pop()
            }

            // 下: 磨いた面を寝かせて置くと、空と地面の境目が映り込む
            canvas.metalness(1)
            canvas.shininess(200)
            canvas.fill(.display(red: 0.8, green: 0.78, blue: 0.72))
            canvas.push()
            canvas.translate(64, 92, 0)
            canvas.rotateX(1.1)
            canvas.box(76, 76, 6)
            canvas.pop()

        case .shadows:
            canvas.background(.display(red: 0.06, green: 0.07, blue: 0.09))
            // 床が見えるように、少し上から見下ろす
            canvas.camera(64, -46, 205, 64, 74, 0, 0, 1, 0)
            canvas.ambientLight(.opaque(red: 0.14, green: 0.14, blue: 0.17))
            canvas.directionalLight(
                .opaque(red: 0.85, green: 0.82, blue: 0.72), -0.62, 0.6, -0.5)
            canvas.shadows(true)
            canvas.noStroke()

            // 床は受けるだけ。落とす側から外しておくと、自分の影が自分に出ない
            canvas.castShadow(false)
            canvas.fill(.display(red: 0.62, green: 0.63, blue: 0.66))
            canvas.push()
            canvas.translate(64, 112, -10)
            canvas.box(190, 8, 190)
            canvas.pop()

            // 置いたものが床へ影を落とす
            canvas.castShadow(true)
            canvas.fill(.display(red: 0.9, green: 0.55, blue: 0.35))
            canvas.push()
            canvas.translate(44, 86, 6)
            canvas.sphere(20)
            canvas.pop()

            canvas.fill(.display(red: 0.45, green: 0.75, blue: 0.95))
            canvas.push()
            canvas.translate(94, 88, -6)
            canvas.rotateY(0.6)
            canvas.box(28)
            canvas.pop()

        case .models:
            // **読み込んで、そのまま置く。** 既定同士が噛み合っていれば、これで見える
            canvas.background(.display(red: 0.05, green: 0.06, blue: 0.08))
            canvas.lights()
            canvas.noStroke()
            guard let model = try? canvas.loadModel(ModelFixture.pyramid) else { return }

            canvas.fill(.display(red: 0.9, green: 0.72, blue: 0.4))
            canvas.push()
            canvas.translate(64, 78, 0)
            canvas.rotateY(0.6)
            canvas.model(model)
            canvas.pop()

            // 同じモデルを小さく 3 つ。**続けて置いても描く回数は増えない**
            canvas.fill(.display(red: 0.5, green: 0.75, blue: 0.95))
            for index in 0..<3 {
                canvas.push()
                canvas.translate(28 + Float(index) * 36, 26, -20)
                canvas.scale(0.3, 0.3, 0.3)
                canvas.rotateY(Float(index) * 0.9)
                canvas.model(model)
                canvas.pop()
            }

        case .solidShader:
            // 平面と立体に**同じ断片**を掛ける。書き分けは要らない
            canvas.background(.display(red: 0.05, green: 0.06, blue: 0.08))
            canvas.lights()
            canvas.noStroke()
            guard let painted = try? canvas.makeShader(Scene.stripes, values: ["pitch": 0.55])
            else { return }

            canvas.shader(painted)
            canvas.fill(.display(red: 0.95, green: 0.65, blue: 0.35))
            canvas.push()
            canvas.translate(40, 44, 0)
            canvas.rotateX(0.5)
            canvas.rotateY(0.7)
            canvas.box(42)
            canvas.pop()

            canvas.fill(.display(red: 0.45, green: 0.8, blue: 0.95))
            canvas.push()
            canvas.translate(92, 48, 0)
            canvas.sphere(24)
            canvas.pop()

            // 同じ断片が平面にも効く (下の帯)
            canvas.fill(.display(red: 0.8, green: 0.85, blue: 0.5))
            canvas.rect(10, 92, 108, 26)

            // 組み込みの塗りへ戻すと、縞が消える
            canvas.resetShader()
            canvas.fill(.display(red: 0.9, green: 0.4, blue: 0.5))
            canvas.rect(10, 82, 108, 6)

        case .customSolids:
            canvas.background(.display(red: 0.05, green: 0.06, blue: 0.08))
            canvas.lights()

            // 穴の開いた面。面の向きは書かずに形から求めさせる
            canvas.noStroke()
            canvas.fill(.display(red: 0.95, green: 0.55, blue: 0.3))
            canvas.push()
            canvas.translate(42, 40, 0)
            canvas.rotateX(0.9)
            canvas.rotateZ(0.3)
            canvas.beginShape()
            for corner in [(-24, -24), (24, -24), (24, 24), (-24, 24)] {
                canvas.vertex(Float(corner.0), Float(corner.1), 0)
            }
            canvas.beginContour()
            for corner in [(-10, -10), (-10, 10), (10, 10), (10, -10)] {
                canvas.vertex(Float(corner.0), Float(corner.1), 0)
            }
            canvas.endContour()
            canvas.endShape(.close)
            canvas.pop()

            // 頂点ごとに色の変わる帯。奥行きを持たせて傾ける
            canvas.push()
            canvas.translate(90, 40, 0)
            canvas.beginShape()
            canvas.fill(.display(red: 0.35, green: 0.6, blue: 0.95))
            canvas.vertex(-20, -22, -22)
            canvas.vertex(20, -22, 14)
            canvas.fill(.display(red: 0.95, green: 0.9, blue: 0.35))
            canvas.vertex(20, 22, 14)
            canvas.vertex(-20, 22, -22)
            canvas.endShape(.close)
            canvas.pop()

            // 線と点。塗りではなく線の色で描かれる
            canvas.fill(.display(red: 0.95, green: 0.2, blue: 0.2))
            canvas.stroke(.display(red: 0.4, green: 0.95, blue: 0.7))
            canvas.strokeWeight(5)
            canvas.beginShape(.lines)
            canvas.vertex(16, 80, -30)
            canvas.vertex(56, 108, 30)
            canvas.vertex(16, 108, 30)
            canvas.vertex(56, 80, -30)
            canvas.endShape()
            canvas.strokeWeight(9)
            canvas.beginShape(.points)
            for step in 0..<4 {
                canvas.vertex(74 + Float(step) * 12, 94, Float(step) * 14 - 30)
            }
            canvas.endShape()

        case .viewpoints:
            canvas.background(.display(red: 0.05, green: 0.06, blue: 0.08))
            canvas.lights()
            canvas.noStroke()

            /// 同じ箱を、手前と奥に 1 つずつ。**投影の違いは、奥のものの大きさに出る**。
            func pair(_ x: Float) {
                canvas.push()
                canvas.translate(x, 26, 0)
                canvas.rotateX(-0.5)
                canvas.rotateY(0.6)
                canvas.box(22)
                canvas.pop()
                canvas.push()
                canvas.translate(x, 62, -150)
                canvas.rotateX(-0.5)
                canvas.rotateY(0.6)
                canvas.box(22)
                canvas.pop()
            }

            // 左は既定の透視投影。奥の箱は小さく、画面の中心へ寄る
            canvas.fill(.display(red: 0.95, green: 0.55, blue: 0.3))
            pair(32)

            // 右は平行投影。同じ 2 つが同じ大きさで、真下に並ぶ
            canvas.ortho()
            canvas.fill(.display(red: 0.35, green: 0.6, blue: 0.95))
            pair(96)

            // 透視へ戻し、視点を右上へ動かす。**動かす前に置いた 4 つは動かない**
            canvas.perspective()
            canvas.camera(150, -10, 150, 64, 64, 0, 0, 1, 0)
            canvas.fill(.display(red: 0.4, green: 0.95, blue: 0.7))
            canvas.push()
            canvas.translate(72, 106, 0)
            canvas.box(26)
            canvas.pop()
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
