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
    @Test("台帳に記録した絵が変わっていない", arguments: Take.all)
    func sceneMatchesLedger(_ take: Take) throws {
        let ledger = try Ledger.load()
        let digest = try Self.fingerprint(of: take)

        guard let recorded = ledger[take.name] else {
            Issue.record(
                """
                シーン \(take.name) が台帳に無い。
                新しいシーンなら、次の 1 行を \(Ledger.relativePath) へ足す:

                    \(take.name) \(digest)

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
        let again = try Self.fingerprint(of: take)
        if again == digest {
            Issue.record(
                """
                シーン \(take.name) の絵が変わった。
                (同じシーンを 2 回描いた結果は一致するので、決定論は効いている)

                意図した変更なら、\(Ledger.relativePath) の行を次へ書き換え、
                before / after を PR の証跡に載せる:

                    \(take.name) \(digest)

                意図していないなら、この変更が触った共通部分が他の絵まで変えている。
                台帳は先に書き換えず、なぜ変わったかを先に調べる。

                **この失敗が同時に何行も出ているなら**、出力段の手前 (効果・拡大・
                明るさの写し方) を触っている。ADR-0023 決定 6 の 4 手で扱う —
                2 回描いて一致することを先に確かめ / 動いた行の絵だけを before /
                after で見て / まとめて書き換え、なぜ全部動くのかを PR 本文に
                1 度だけ書く / 意図しない行が 1 つでも混ざっていたら書き換えない。
                """)
        } else {
            Issue.record(
                """
                シーン \(take.name) が、同じ入力から違う絵を出している (決定論が壊れている)。
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
    static func fingerprint(of take: Take) throws -> String {
        try fingerprint(of: take, without: nil)
    }

    /// 同じ行を、要素を 1 つ抜いて取り直す。**検出力の測定に使う。**
    ///
    /// 拡大だけは描き場所の作り方に効く (描く細かさを出す細かさに揃えると、
    /// 埋める仕事そのものが無くなる) ので、canvas を組み立てる時点で抜く。
    static func fingerprint(of take: Take, without suppressed: Scene.Ingredient?) throws -> String {
        let scene = take.scene
        let gpu = try RenderDevice()
        let target = try RenderTarget(gpu: gpu, width: scene.size.width, height: scene.size.height)
        let canvas = try Canvas(
            output: target, gpu: gpu,
            pixelDensity: suppressed == .upscale ? 1 : scene.pixelDensity,
            upscale: scene.upscale)
        // **時点まで進めてから取る。** 時点を持たないシーンは 1 度描いた結果で、
        // いままでと 1 ビットも変わらない (ADR-0023 決定 6)
        let session = try scene.session(on: canvas, without: suppressed)
        for _ in 0..<(take.moment ?? 1) { try canvas.draw { session() } }
        let image = try target.encodeForDisplay()

        if let dir = ProcessInfo.processInfo.environment["MOKUME_LEDGER_DUMP_DIR"] {
            let url = URL(fileURLWithPath: dir).appendingPathComponent("\(take.name).png")
            try? FileManager.default.createDirectory(
                at: URL(fileURLWithPath: dir), withIntermediateDirectories: true)
            try target.writePNG(to: url)
        }

        return SHA256.hash(data: Data(image.bytes)).map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - 台帳の行

/// 台帳の 1 行が指すもの。
///
/// **時点を書かない行はいままでと同じ意味**である (絵を 1 度描いた結果)。時点を持つのは
/// 「動きそのものが正しさ」であるシーンだけで、どの時点を載せるかはシーンが決める。
/// 全フレームは載せない — 台帳は退行を見せる装置であって、記録装置ではない
/// ([ADR-0023] 決定 6)。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
struct Take: Sendable, CustomStringConvertible {
    let scene: Scene
    /// 何フレーム進めた時点か。`nil` なら 1 度描いた結果。
    let moment: Int?

    var name: String { moment.map { "\(scene.rawValue)@\($0)" } ?? scene.rawValue }
    var description: String { name }

    nonisolated static var all: [Take] {
        Scene.allCases.flatMap { scene in
            scene.moments.isEmpty
                ? [Take(scene: scene, moment: nil)]
                : scene.moments.map { Take(scene: scene, moment: $0) }
        }
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
    /// 直前の頂点を使い回す読み方。**同じ点の並びを帯と扇で読み分けてある** —
    /// 畳み方が動けば、平面の 2 枚と立体の 1 枚のどれかが必ず動く。
    case reusedVertices
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
    /// 同じ種の揺らぎを、CPU の `noise()` と断片の `mokume_noise()` で並べたもの。
    ///
    /// **上下が同じ模様になる**ことがこのシーンの中身で、片方だけ動けば行が動く。
    /// 値そのものの一致は `NoiseParityTests` が細かく見るので、ここが受け持つのは
    /// 「触っていないのに模様が変わっていないか」だけである。
    case noise
    /// 基本の立体を並べ、回して奥行きが出る向きに置いたもの。
    case solids
    /// 光を当てた立体。底上げの光・向きを持つ光・広がりを持つ光を並べたもの。
    case lighting
    /// 頂点を並べて作った立体。穴・頂点ごとの色・線と点・書いた面の向きを並べたもの。
    case customSolids
    /// 奥行きを持つ折れ線の輪郭。端の形と折れ目の形を組で振ったもの。
    ///
    /// **平面の ``caps`` / ``joins`` に対する立体側の対。** あちらは `line()` と
    /// `triangle()` なので平面の経路を通り、`Canvas+Solid.swift` の折れ目と
    /// `appendSolidSquare` にはどのシーンも届いていなかった
    /// ([#890](https://github.com/mokume-metal/mokume/issues/890))。
    ///
    /// **その覆いの上で、端と折れ目の規則を平面と 1 本に畳んだ**
    /// (`Canvas+Outline.swift` の `strokeRing`・
    /// [#891](https://github.com/mokume-metal/mokume/issues/891))。このシーンが動けば、
    /// 畳んだ骨か立体側の差し込み点のどちらかが壊れている。
    case solidStrokes
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
    /// 焼いた絵を貼った平面の図形。輪郭・字・色掛けとの効き分けを並べたもの。
    case texturedShapes
    /// 焼いた絵を貼った立体。組み込みの形の展開と、自分で書いた読み取り位置。
    case texturedSolids
    /// 焼いた絵を貼った読み込みモデル。**作者の書いた展開と、展開を持たないモデルの
    /// 倒れ先を並べてある** — 片方だけが動いても行が動く。
    case texturedModel
    /// 形自身の座標から模様を作った立体。**同じ形を 2 つ、違う角度で置いてある** —
    /// 模様が形について回っていることが 1 枚で読める。
    case surfaceShader
    /// 名前で渡した 2 枚の面を掛け合わせた塗り。**平面と立体に同じ断片が効いている** —
    /// 片方だけ面が届かなくなれば行が動く ([#407](https://github.com/mokume-metal/mokume/issues/407))。
    case surfacesShader
    /// 粒が力を受けて飛ぶ。**時点を持つ最初のシーン。**
    case particles
    /// 計算が書いた数をそのまま絵にしたもの。**時点を持つ** — 場が時間で動くので、
    /// 1 枚では計算が毎フレーム走っていることまでは読めない。
    ///
    /// 計算を 2 本繋いである (場を書く → その場を読んで縁を立てる)。**同じ並びに
    /// 触れる計算どうし**なので口が切れ、切れ目が無ければ縁のほうが書き終わる前の
    /// 場を読む ([#388])。上下に並べた 2 枚は同じ場の前後で、片方だけが動いても行が動く。
    ///
    /// [#388]: https://github.com/mokume-metal/mokume/issues/388
    case field
    /// 描いた絵に効果を重ねたもの。
    case effects
    /// **描く細かさを半分にして拡大したもの。** 斜めと曲がりが多いので、拡大の質が出る。
    case upscaled
    /// 同じ絵を、時間方向の拡大で重ねたもの。**時点を持つ** — 重なるほど落ち着く。
    case upscaledOverTime
    /// 利用者が持つ描き場所に跡を積み上げ、画面へ置いたもの。**時点を持つ** —
    /// 消さずに描き続けた結果そのものが正しさなので、1 枚では判定できない。
    case layered

    var size: (width: Int, height: Int) { (128, 128) }

    /// 描く細かさ。拡大のシーンだけが 1 より小さい。
    nonisolated var pixelDensity: Float {
        switch self {
        case .upscaled, .upscaledOverTime: 0.5
        default: 1
        }
    }

    /// 細かさの間の埋め方。
    nonisolated var upscale: Upscale {
        self == .upscaledOverTime ? .temporal : .spatial
    }
    /// 年輪を掛ける断片。**形自身の座標**から作るので、形を回しても模様は形に留まる。
    /// 縞と同じく `in.color` を掛けるので、陰影はそのまま残る。
    static let grain = """
        float4 paint(Fragment in, Values values) {
            float2 across = in.shapePosition.xz * float2(1.0, 2.4);
            float rings = 0.5 + 0.5 * sin(length(across) * values.pitch);
            float3 tint = mix(values.early.rgb, values.late.rgb, rings);
            return float4(tint * in.color.rgb, in.color.a);
        }
        """

    /// 名前で渡した 2 枚の面を掛け合わせる断片 ([#407])。
    ///
    /// **2 枚は別の使われ方をする** — 木目は色として、汚しは濃さとして効く。片方だけが
    /// 届かなくなったときに、絵の変わり方が違うので読み分けられる。
    ///
    /// [#407]: https://github.com/mokume-metal/mokume/issues/407
    static let blended = """
        float4 paint(Fragment in, Values values, Surfaces surfaces) {
            float4 wood = mokume_sample(surfaces.grain, in.place * values.tiling);
            float dirt = mokume_sample(surfaces.smudge, in.place).r;
            return float4(
                wood.rgb * mix(1.0, dirt, values.amount) * in.color.rgb, in.color.a);
        }
        """

    /// 汚しの絵。**その場で焼く**ので毎回同じで、木目とは別の形にしてある
    /// (掛け合わせた結果から、どちらが効いているかを読み分けるため)。
    static func makeSmudge(on canvas: Canvas) -> Image? {
        guard let image = try? canvas.createImage(32, 32) else { return nil }
        for y in 0..<32 {
            for x in 0..<32 {
                // 斜めに流れる帯。木目 (縦縞) と重ならない向きにする
                let band = 0.5 + 0.5 * sin(Float(x + y) * 0.35)
                let level = min(1, 0.35 + band * 0.65)
                image.set(x, y, .display(red: level, green: level, blue: level))
            }
        }
        return image
    }

    /// 縞を掛ける断片。**光を通したあとの色**が `in.color` に入っているので、
    /// 掛けるだけで陰影が残る。
    static let stripes = """
        float4 paint(Fragment in, Values values) {
            float stripe = 0.55 + 0.45 * sin(in.position.y * values.pitch);
            return float4(in.color.rgb * stripe, in.color.a);
        }
        """


    /// 貼るための絵。**その場で焼く**ので、ファイルを置かずに済み、毎回同じ絵になる。
    ///
    /// 縞と格子を重ねてある — 上下・左右のどちらが逆になっても絵が変わる形にしないと、
    /// 向きの退行が台帳の行に出ない。
    static func makeGrain(on canvas: Canvas) -> Image? {
        guard let image = try? canvas.createImage(32, 32) else { return nil }
        for y in 0..<32 {
            for x in 0..<32 {
                let ring = 0.5 + 0.5 * sin(Float(x) * 0.9 + Float(y) * 0.12)
                // 上の 4 行だけ明るくして、上下が分かるようにする
                let top: Float = y < 4 ? 0.6 : 0
                // 左の 4 列だけ赤みを足して、左右が分かるようにする
                let left: Float = x < 4 ? 0.5 : 0
                image.set(
                    x, y,
                    .display(
                        red: min(1, 0.35 + ring * 0.45 + top + left),
                        green: min(1, 0.22 + ring * 0.35 + top),
                        blue: min(1, 0.12 + ring * 0.2 + top)))
            }
        }
        return image
    }

    /// シーンから 1 つだけ抜いて描くための名前。**潰したときに絵が動くかを測るのに使う。**
    ///
    /// 2 つの群からなる。**質感の指定**は値を既定へ潰すもので、**段**はその仕事ごと
    /// 外すものである。潰し方は違うが、測っていることは同じ「この行はこれを写しているか」
    /// なので、名前の置き場を 2 つに割らない。
    enum Ingredient: CaseIterable, Sendable {
        // 質感の指定
        case shininess
        case metalness
        case ambient
        case emissive
        // 段
        /// 描き終えた絵に重ねる効果。
        case effects
        /// 描く細かさと出す細かさの差を埋める仕事。
        case upscale
        /// 粒に効かせる力。
        case force
        /// 描く前に走る計算。
        case compute

        /// 質感の指定だけ。``MaterialTests`` が引数に使う。
        nonisolated static var materialAspects: [Ingredient] {
            [.shininess, .metalness, .ambient, .emissive]
        }

        /// 段だけ。**外すと絵が変わるはずの行**を、この要素自身が知っている。
        nonisolated static var stages: [Ingredient] { [.effects, .upscale, .force, .compute] }

        /// この要素を写しているはずの台帳の行。
        nonisolated var takes: [Take] {
            switch self {
            case .effects: [Take(scene: .effects, moment: nil)]
            case .upscale:
                [Take(scene: .upscaled, moment: nil)]
                    + Scene.upscaledOverTime.moments.map { Take(scene: .upscaledOverTime, moment: $0) }
            case .force: Scene.particles.moments.map { Take(scene: .particles, moment: $0) }
            case .compute: Scene.field.moments.map { Take(scene: .field, moment: $0) }
            default: []
            }
        }
    }

    func draw(on canvas: Canvas) { draw(on: canvas, without: nil) }

    /// 台帳に載せる時点 (何フレーム進めたところか)。**空なら 1 度描いた結果。**
    nonisolated var moments: [Int] {
        switch self {
        // 粒は**動きそのものが正しさ**なので、1 枚では判定できない。出始めと、
        // 寿命が一巡したあとの 2 点を見る
        case .particles: [12, 48]
        // 時間方向の拡大は**重ねた回数が絵を決める**ので、1 枚では判定できない。
        // 揺らしが一巡した直後と、そのあと落ち着いた頃の 2 点を見る
        case .upscaledOverTime: [8, 32]
        // 描き場所は**消さずに積み上げる**ので、跡が伸びたところと、一周して
        // 重なり始めたところの 2 点を見る
        case .layered: [6, 20]
        // 計算が書く場は**時刻から決まる**ので、位相の違う 2 点を見る。1 点だけだと、
        // 計算が初回しか走っていなくても気付けない
        case .field: [6, 30]
        default: []
        }
    }

    /// 1 回ぶんの走らせ方。
    ///
    /// **フレームをまたいで持つものがあるシーンは、ここで作る。** 毎フレーム作り直すと
    /// 動きが進まず、しかも絵は出るので気付けない。
    func session(on canvas: Canvas) throws -> () -> Void {
        try session(on: canvas, without: nil)
    }

    /// 1 回ぶんの走らせ方を、要素を 1 つ抜いて組み立てる。
    ///
    /// **抜くのは進め方のほう**である。粒の力のように、1 枚の絵ではなくフレームの
    /// 進み方に効くものは ``draw(on:without:)`` では抜けない。
    func session(on canvas: Canvas, without suppressed: Ingredient?) throws -> () -> Void {
        switch self {
        case .particles:
            // 種を決めて引くので、何度走らせても同じ列が出る
            var randomness = Randomness(seed: 20_260_830)
            let dust = try canvas.makeParticles(count: 2000)
            return {
                canvas.background(.display(red: 0.04, green: 0.05, blue: 0.08))
                canvas.emit(
                    dust, from: .point(64, 116), rate: 900, speed: 70...150,
                    angle: (-2.4)...(-0.75), life: 0.5...1.2, size: 2...5,
                    color: .linear(red: 1, green: 0.72, blue: 0.35), using: &randomness)
                // 潰したときは力を 1 つも効かせない。**出た向きのまま飛ぶ**
                if suppressed != .force {
                    canvas.force(dust, [.gravity(0, 240), .drag(0.2)])
                }
                canvas.particles(dust)
            }
        case .field:
            // 場は 32 x 32。**位置と時刻だけから決まる**ので、前フレームの値は読まない —
            // 読ませると、単独で描いた N と 0 から進めた N が食い違い、列が揃わなくなる
            let cells = 32
            let heat = try canvas.makeNumbers(count: cells * cells)
            let banded = try canvas.makeNumbers(count: cells * cells)
            // **計算を頼まなかったときの値**を置く。潰したときの絵が「平らな場」として
            // 出るので、行が動いたことがそのまま読める
            heat.fill(0)
            banded.fill(0)
            let stir = try canvas.makeComputation(
                """
                kernel void stir(device float *field [[buffer(0)]],
                                 constant Values &values [[buffer(MOKUME_VALUES)]],
                                 uint2 id [[thread_position_in_grid]])
                {
                    uint cells = uint(values.cells);
                    float2 place = (float2(id) + 0.5) / values.cells;
                    float wave = sin(place.x * 7.0 + values.time * 4.5)
                        + cos(place.y * 5.0 - values.time * 3.0);
                    field[id.y * cells + id.x] = 0.5 + 0.25 * wave;
                }
                """,
                name: "stir", values: ["cells": .number(Float(cells)), "time": 0])
            // **1 本目が書いた並びを読んで、段に落とす。** 触れる計算どうしなので口が
            // 切れ、切れ目が無ければ書き終わる前の場を読む ([#388])。段に落とすのは
            // なめらかな場との違いが 1 枚で読めるからで、縞の位置がそのまま場の等高線になる
            let band = try canvas.makeComputation(
                """
                kernel void band(device const float *field [[buffer(0)]],
                                 device float *out [[buffer(1)]],
                                 constant Values &values [[buffer(MOKUME_VALUES)]],
                                 uint2 id [[thread_position_in_grid]])
                {
                    uint cells = uint(values.cells);
                    float here = saturate(field[id.y * cells + id.x]);
                    out[id.y * cells + id.x] = min(floor(here * 6.0), 5.0) / 5.0;
                }
                """,
                name: "band", values: ["cells": .number(Float(cells))])
            // 並びを絵にする塗り。**どの矩形のどこを読むか**は値で渡すので、同じ塗りで
            // 場の前後を並べられる
            let show = try canvas.makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    uint cells = uint(values.cells);
                    float2 place = (in.position - values.origin) / values.span * values.cells;
                    uint2 cell = uint2(clamp(place, float2(0.0), float2(values.cells - 0.001)));
                    float level = in.numbers[cell.y * cells + cell.x];
                    return float4(mix(values.cool.rgb, values.warm.rgb, level), 1.0);
                }
                """,
                values: [
                    "cells": .number(Float(cells)),
                    "origin": .pair(0, 0),
                    "span": .pair(128, 88),
                    "cool": .color(.display(red: 0.05, green: 0.09, blue: 0.28)),
                    "warm": .color(.display(red: 1, green: 0.72, blue: 0.3)),
                ])
            var step = 0
            return {
                // **秒で送る。** 時点がそのまま位相になるので、台帳の 2 点は別の場になる
                stir.set("time", .number(Float(step) / 60))
                step += 1
                // 潰したときは 1 本も頼まない。**並びは置いたときの値のまま**である
                if suppressed != .compute {
                    canvas.compute(stir, over: cells, by: cells, writes: [heat])
                    canvas.compute(band, over: cells, by: cells, reads: [heat], writes: [banded])
                }
                canvas.background(.display(red: 0.04, green: 0.05, blue: 0.08))
                // **塗りの指定はフレームをまたいで残る。** `noFill()` が残っていると、
                // 矩形を置いても絵が出ないのに例外も出ない
                canvas.noStroke()
                canvas.fill(.display(red: 1, green: 1, blue: 1))

                // 上: 段に落とした場 (2 本目の結果)
                canvas.numbers(banded)
                canvas.shader(show)
                show.set("origin", .pair(0, 0))
                show.set("span", .pair(128, 88))
                canvas.rect(0, 0, 128, 88)

                // 下: 素の場 (1 本目の結果)。**同じ場の前後を並べてある**ので、
                // 片方だけが動いても行が動く
                show.set("origin", .pair(0, 92))
                show.set("span", .pair(128, 36))
                canvas.numbers(heat)
                canvas.rect(0, 92, 128, 36)

                canvas.resetShader()
                canvas.resetNumbers()
            }
        case .layered:
            // **描き場所はフレームをまたいで持つ。** 毎フレーム作り直すと跡が
            // 積み上がらず、しかも絵は出るので気付けない
            let trail = try canvas.createGraphics(96, 96)
            var step = 0
            return {
                canvas.background(.display(red: 0.05, green: 0.06, blue: 0.09))
                // 描き場所は消さない。前のフレームの上に描き足す
                trail.beginDraw()
                trail.noStroke()
                let angle = Float(step) * 0.42
                trail.fill(.display(red: 1, green: 0.6, blue: 0.25, alpha: 0.85))
                trail.circle(48 + cos(angle) * 32, 48 + sin(angle) * 32, 16)
                trail.endDraw()
                step += 1
                canvas.image(trail, 16, 16)
                // 画面側にも描いて、**置いた絵と同じ 1 枚に混ざる**ことを見せる
                canvas.noStroke()
                canvas.fill(.display(red: 0.3, green: 0.8, blue: 1, alpha: 0.45))
                canvas.circle(64, 64, 52)
            }
        default:
            return { self.draw(on: canvas, without: suppressed) }
        }
    }

    /// 質感の指定を 1 つだけ既定へ潰して描く。
    ///
    /// **検出力の測定に使う** — 潰しても絵が動かない指定があれば、その代表シーンは
    /// その質感を写していないということになる ([ADR-0019] 決定 4)。
    func draw(on canvas: Canvas, without suppressed: Ingredient?) {
        switch self {
        case .particles, .layered, .field:
            // **1 枚では描けないシーン。** フレームをまたいで持つものがあるので、
            // 走らせ方は `session(on:)` が持つ
            break
        case .effects: drawEffects(on: canvas, without: suppressed)
        case .upscaled, .upscaledOverTime: drawUpscaled(on: canvas)
        case .shapes: drawShapes(on: canvas)
        case .transforms: drawTransforms(on: canvas)
        case .strokes: drawStrokes(on: canvas)
        case .primitives: drawPrimitives(on: canvas)
        case .origins: drawOrigins(on: canvas)
        case .caps: drawCaps(on: canvas)
        case .freeform: drawFreeform(on: canvas)
        case .reusedVertices: drawReusedVertices(on: canvas)
        case .blends: drawBlends(on: canvas)
        case .text: drawText(on: canvas)
        case .textFlow: drawTextFlow(on: canvas)
        case .images: drawImages(on: canvas)
        case .pixels: drawPixels(on: canvas)
        case .retainedShapes: drawRetainedShapes(on: canvas)
        case .userShader: drawUserShader(on: canvas)
        case .noise: drawNoise(on: canvas)
        case .joins: drawJoins(on: canvas)
        case .solids: drawSolids(on: canvas)
        case .lighting: drawLighting(on: canvas)
        case .materials: drawMaterials(on: canvas, without: suppressed)
        case .surroundings: drawSurroundings(on: canvas)
        case .shadows: drawShadows(on: canvas)
        case .models: drawModels(on: canvas)
        case .texturedShapes: drawTexturedShapes(on: canvas)
        case .texturedSolids: drawTexturedSolids(on: canvas)
        case .texturedModel: drawTexturedModel(on: canvas)
        case .solidShader: drawSolidShader(on: canvas)
        case .surfaceShader: drawSurfaceShader(on: canvas)
        case .surfacesShader: drawSurfacesShader(on: canvas)
        case .customSolids: drawCustomSolids(on: canvas)
        case .solidStrokes: drawSolidStrokes(on: canvas)
        case .viewpoints: drawViewpoints(on: canvas)
        }
    }

    private func drawEffects(on canvas: Canvas, without suppressed: Ingredient?) {
        canvas.background(.display(red: 0.03, green: 0.04, blue: 0.07))
        canvas.noStroke()
        canvas.fill(.display(red: 1, green: 0.85, blue: 0.35))
        canvas.circle(44, 46, 46)
        canvas.fill(.display(red: 0.25, green: 0.55, blue: 1))
        canvas.rect(58, 62, 52, 44)
        canvas.fill(.display(red: 1, green: 0.3, blue: 0.45))
        canvas.rect(14, 92, 40, 14)
        // **並びの順にかかる。** にじみ → 色ずれ → 周辺減光。
        // 潰したときは 1 段も掛けない (段そのものを外す)
        if suppressed != .effects {
            canvas.effects([
                .bloom(amount: 0.8, threshold: 0.35, radius: 10),
                .fringe(amount: 0.7),
                .vignette(amount: 0.65),
            ])
        }
    }

    private func drawUpscaled(on canvas: Canvas) {
        // 斜め・曲がり・細い線を混ぜる。**低い細かさでいちばん崩れる**ものを置いて、
        // 拡大が何をしているかが 1 枚で読めるようにする
        canvas.background(.display(red: 0.05, green: 0.06, blue: 0.09))
        canvas.noStroke()
        canvas.fill(.display(red: 1, green: 0.8, blue: 0.3))
        canvas.circle(44, 48, 56)
        canvas.stroke(.display(red: 0.3, green: 0.8, blue: 1))
        canvas.strokeWeight(2)
        for step in 0..<6 {
            canvas.line(8, 100 + Float(step), 120, 64 + Float(step) * 6)
        }
        canvas.noStroke()
        canvas.fill(.display(red: 1, green: 0.35, blue: 0.45))
        for step in 0..<10 {
            canvas.rect(10 + Float(step) * 12, 12, 3, 22)
        }
    }

    private func drawShapes(on canvas: Canvas) {
        canvas.background(.display(red: 0.08, green: 0.09, blue: 0.12))
        canvas.fill(.display(red: 0.95, green: 0.35, blue: 0.2))
        canvas.rect(12, 12, 40, 28)
        canvas.fill(.display(red: 0.3, green: 0.7, blue: 0.95))
        canvas.circle(88, 40, 44)
        canvas.stroke(.display(red: 1, green: 1, blue: 1))
        canvas.strokeWeight(2)
        canvas.line(12, 96, 116, 72)
    }

    private func drawTransforms(on canvas: Canvas) {
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
    }

    private func drawStrokes(on canvas: Canvas) {
        canvas.background(.display(red: 1, green: 1, blue: 1))
        canvas.stroke(.display(red: 0.1, green: 0.1, blue: 0.1))
        for step in 0..<5 {
            canvas.strokeWeight(Float(step) * 2 + 1)
            let y = 16 + Float(step) * 24
            canvas.line(16, y, 112, y)
        }
    }

    private func drawPrimitives(on canvas: Canvas) {
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
    }

    private func drawOrigins(on canvas: Canvas) {
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
    }

    private func drawCaps(on canvas: Canvas) {
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
    }

    private func drawFreeform(on canvas: Canvas) {
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
    }

    private func drawReusedVertices(on canvas: Canvas) {
        canvas.background(.display(red: 0.08, green: 0.08, blue: 0.1))
        // 切れ目が見えるよう、下地と同じ色の線で 1 枚ずつ区切る
        canvas.stroke(.display(red: 0.08, green: 0.08, blue: 0.1))
        canvas.strokeWeight(2)

        // 上段: 帯。上下に交互に置いた 6 点が 4 枚になる
        canvas.fill(.display(red: 0.95, green: 0.45, blue: 0.3))
        canvas.beginShape(.triangleStrip)
        for step in 0..<6 {
            canvas.vertex(8 + Float(step) * 22, step.isMultiple(of: 2) ? 6 : 40)
        }
        canvas.endShape()

        // 中段: 扇。左端の 1 点をすべての三角形が共有する
        canvas.fill(.display(red: 0.4, green: 0.85, blue: 0.5))
        canvas.beginShape(.triangleFan)
        canvas.vertex(8, 84)
        for step in 0..<5 {
            canvas.vertex(40 + Float(step) * 20, 48 + Float(step) * 9)
        }
        canvas.endShape()

        // 下段: 立体の帯。**書かなかった面の向きが形から求まる** — 巻きが揃って
        // いないと、内側の頂点で打ち消し合って光を受けなくなる
        canvas.lights()
        canvas.noStroke()
        canvas.fill(.display(red: 0.95, green: 0.85, blue: 0.35))
        canvas.push()
        canvas.translate(64, 106, 0)
        canvas.rotateX(0.5)
        canvas.beginShape(.triangleStrip)
        for step in 0..<6 {
            let across = -50 + Float(step) * 20
            canvas.vertex(across, step.isMultiple(of: 2) ? -16 : 16, step.isMultiple(of: 2) ? 18 : -18)
        }
        canvas.endShape()
        canvas.pop()
    }

    private func drawBlends(on canvas: Canvas) {
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
    }

    private func drawText(on canvas: Canvas) {
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
    }

    private func drawTextFlow(on canvas: Canvas) {
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
    }

    private func drawImages(on canvas: Canvas) {
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
    }

    private func drawPixels(on canvas: Canvas) {
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
    }

    private func drawRetainedShapes(on canvas: Canvas) {
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

        // 中段: 組にしたものを 1 回で置く
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

        drawRetainedShapeBands(on: canvas)
    }

    /// 下段: **断片も形の中に焼き付く** ([#788])。組み立ての間だけ塗りを効かせ、
    /// 置くときには外してある — それでも記録した塗りで出る。面だけ差し替えた
    /// 2 枚を組にしてあるので、畳まれていれば左右が同じ色になる。
    ///
    /// 上の 2 段とは持ち物を分け合わないので、ここだけ切り出してある。
    ///
    /// [#788]: https://github.com/mokume-metal/mokume/issues/788
    private func drawRetainedShapeBands(on canvas: Canvas) {
        guard let warm = try? canvas.createImage(4, 4),
            let cool = try? canvas.createImage(4, 4)
        else { return }
        warm.fill(.display(red: 1, green: 0.72, blue: 0.3))
        cool.fill(.display(red: 0.35, green: 0.75, blue: 1))
        guard
            let tone = try? canvas.makeShader(
                """
                float4 paint(Fragment in, Values values, Surfaces surfaces) {
                    float wave = 0.55 + 0.45 * sin(in.place.x * 26.0);
                    return float4(mokume_sample(surfaces.tone, in.place).rgb * wave, 1.0);
                }
                """,
                surfaces: ["tone": .image(warm)])
        else { return }

        canvas.noStroke()
        // 断片が落ちていれば、この塗り (青) がそのまま出る
        canvas.fill(.display(red: 0.1, green: 0.15, blue: 0.9))
        canvas.shader(tone)
        let warmBand = canvas.createShape { canvas.rect(0, 0, 46, 16) }
        tone.set("tone", .image(cool))
        let coolBand = canvas.createShape { canvas.rect(50, 0, 46, 16) }
        canvas.resetShader()
        canvas.shape(Shape.group([warmBand, coolBand]), 16, 106)
    }

    private func drawUserShader(on canvas: Canvas) {
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
    }

    private func drawNoise(on canvas: Canvas) {
        // 種は 1 度だけ置く。**CPU 側と断片側の両方に効く**
        canvas.noiseSeed(20260829)
        canvas.noiseDetail(4, 0.5)
        canvas.background(.display(red: 0.07, green: 0.07, blue: 0.09))
        canvas.noStroke()

        // 上: CPU の揺らぎを 4 画素ごとに引いて置く
        for row in 0..<15 {
            for column in 0..<32 {
                let level = canvas.noise(Float(column) * 0.25, Float(row) * 0.25)
                // **線形のまま置く。** 断片が返すのも線形なので、`display` を
                // 通すと上下で色の空間が食い違い、同じ模様に見えなくなる
                canvas.fill(
                    LinearRGBA(
                        premultipliedRed: level, green: level * 0.7, blue: 1 - level,
                        alpha: 1))
                canvas.rect(Float(column) * 4, Float(row) * 4, 4, 4)
            }
        }

        // 下: 同じ座標を断片から引く。**種も細かさも値として渡していない**
        guard
            let field = try? canvas.makeShader(
                """
                float4 paint(Fragment in, Values values) {
                    float2 p = (in.position - values.origin) * 0.0625;
                    float level = mokume_noise(in, p);
                    return float4(level, level * 0.7, 1.0 - level, 1.0);
                }
                """,
                values: ["origin": .pair(0, 68)])
        else { return }
        canvas.shader(field)
        canvas.rect(0, 68, 128, 60)
        canvas.resetShader()
    }

    private func drawJoins(on canvas: Canvas) {
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

    private func drawSolids(on canvas: Canvas) {
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
    }

    private func drawLighting(on canvas: Canvas) {
        canvas.background(.display(red: 0.05, green: 0.05, blue: 0.07))
        // 底上げ + 斜め上から差す光。縦軸は下向きなので、上から差す光の向きは +y
        canvas.ambientLight(.linear(red: 0.18, green: 0.18, blue: 0.22))
        canvas.directionalLight(.linear(red: 0.9, green: 0.85, blue: 0.75), -0.45, 0.8, -0.4)
        // 手前の右下から当てる差し色
        canvas.pointLight(.linear(red: 0.25, green: 0.4, blue: 0.9), 120, 110, 90)

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
    }

    private func drawMaterials(on canvas: Canvas, without suppressed: Ingredient?) {
        // 上の列が非金属、下の列が金属。左から右へ、粗い面から滑らかな面へ
        canvas.background(.display(red: 0.04, green: 0.05, blue: 0.07))
        canvas.ambientLight(.linear(red: 0.16, green: 0.16, blue: 0.18))
        canvas.directionalLight(
            .linear(red: 0.7, green: 0.68, blue: 0.62), -0.35, 0.5, -0.8)
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
                ? .linear(red: 0, green: 0, blue: 0)
                : .display(red: 0.55, green: 0.25, blue: 0.1))
        canvas.push()
        canvas.translate(38, 106, 0)
        canvas.rotateX(0.5)
        canvas.rotateY(0.7)
        canvas.box(30)
        canvas.pop()

        canvas.emissive(.linear(red: 0, green: 0, blue: 0))
        canvas.ambient(
            suppressed == .ambient
                ? .linear(red: 1, green: 1, blue: 1)
                : .display(red: 0.2, green: 0.2, blue: 0.25))
        canvas.push()
        canvas.translate(90, 106, 0)
        canvas.rotateX(0.5)
        canvas.rotateY(0.7)
        canvas.box(30)
        canvas.pop()
    }

    private func drawSurroundings(on canvas: Canvas) {
        // 周囲と、斜め上から差す光を 1 つ。**周囲は光に足されるだけ**なので、
        // 非金属は光で陰影が付き、金属は周囲だけで形が出る
        canvas.surroundings(.sky)
        canvas.background(.sky)
        canvas.ambientLight(.linear(red: 0.16, green: 0.16, blue: 0.18))
        canvas.directionalLight(
            .linear(red: 0.6, green: 0.58, blue: 0.5), -0.4, 0.5, -0.75)
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
    }

    private func drawShadows(on canvas: Canvas) {
        canvas.background(.display(red: 0.06, green: 0.07, blue: 0.09))
        // 床が見えるように、少し上から見下ろす
        canvas.camera(64, -46, 205, 64, 74, 0, 0, 1, 0)
        canvas.ambientLight(.linear(red: 0.14, green: 0.14, blue: 0.17))
        canvas.directionalLight(
            .linear(red: 0.85, green: 0.82, blue: 0.72), -0.62, 0.6, -0.5)
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
    }

    private func drawModels(on canvas: Canvas) {
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
    }

    private func drawTexturedShapes(on canvas: Canvas) {
        canvas.background(.display(red: 0.08, green: 0.08, blue: 0.1))
        guard let grain = Scene.makeGrain(on: canvas) else { return }
        canvas.texture(grain)

        // 組み込みの図形は囲みの箱から読み取り位置が決まる
        canvas.noStroke()
        canvas.rect(6, 6, 52, 40)
        canvas.circle(92, 26, 40)

        // 輪郭には貼られない — 縁だけが線の色で出る
        canvas.stroke(.display(red: 1, green: 0.9, blue: 0.4))
        canvas.strokeWeight(3)
        canvas.rect(6, 54, 52, 40)

        // 塗りが色掛けになる
        canvas.noStroke()
        canvas.fill(.display(red: 0.4, green: 0.8, blue: 1))
        canvas.rect(66, 54, 52, 40)

        // 自分で書いた読み取り位置 (絵の左半分だけを引き伸ばす)
        canvas.fill(.display(red: 1, green: 1, blue: 1))
        canvas.beginShape()
        canvas.vertex(6, 100, 0, 0)
        canvas.vertex(118, 100, Float(grain.width) / 2, 0)
        canvas.vertex(118, 122, Float(grain.width) / 2, Float(grain.height))
        canvas.vertex(6, 122, 0, Float(grain.height))
        canvas.endShape(.close)

        // 外せば、そのあとの図形は貼られない
        canvas.noTexture()
        canvas.fill(.display(red: 0.95, green: 0.4, blue: 0.45))
        canvas.rect(6, 48, 112, 4)
    }

    private func drawTexturedSolids(on canvas: Canvas) {
        canvas.background(.display(red: 0.05, green: 0.06, blue: 0.08))
        canvas.lights()
        canvas.noStroke()
        guard let grain = Scene.makeGrain(on: canvas) else { return }
        canvas.texture(grain)

        // 箱は 6 面それぞれに 1 枚。光を通した色に掛かるので陰影が残る
        canvas.push()
        canvas.translate(36, 40, 0)
        canvas.rotateX(0.5)
        canvas.rotateY(0.7)
        canvas.box(42)
        canvas.pop()

        // 球は経度と緯度に巻く
        canvas.push()
        canvas.translate(94, 42, 0)
        canvas.sphere(24)
        canvas.pop()

        // 自分で並べた立体に読み取り位置を書く
        canvas.push()
        canvas.translate(64, 96, 0)
        canvas.rotateX(0.7)
        canvas.beginShape()
        canvas.vertex(-48, -18, 0, 0, 0)
        canvas.vertex(48, -18, 0, Float(grain.width), 0)
        canvas.vertex(48, 18, 0, Float(grain.width), Float(grain.height))
        canvas.vertex(-48, 18, 0, 0, Float(grain.height))
        canvas.endShape(.close)
        canvas.pop()
    }

    private func drawTexturedModel(on canvas: Canvas) {
        // **読み込んだモデルに絵を貼る。** 左は作者の展開を持つ板 (絵の一部だけを
        // 使う)、右は展開を持たない四角錐 (囲みの箱へ倒れて絵の全面を使う)。
        // 倒れ先しか無かった頃は、左も全面を使っていた ([#406](https://github.com/mokume-metal/mokume/issues/406))
        canvas.background(.display(red: 0.05, green: 0.06, blue: 0.08))
        canvas.lights()
        canvas.noStroke()
        guard let grain = Scene.makeGrain(on: canvas),
            let unwrapped = try? canvas.loadModel(ModelFixture.unwrapped),
            let pyramid = try? canvas.loadModel(ModelFixture.pyramid)
        else { return }
        canvas.texture(grain)

        canvas.fill(.display(red: 1, green: 1, blue: 1))
        canvas.push()
        canvas.translate(36, 62, 0)
        canvas.rotateY(0.5)
        canvas.scale(0.62, 0.62, 0.62)
        canvas.model(unwrapped)
        canvas.pop()

        canvas.push()
        canvas.translate(94, 66, 0)
        canvas.rotateY(0.7)
        canvas.scale(0.62, 0.62, 0.62)
        canvas.model(pyramid)
        canvas.pop()
    }

    private func drawSolidShader(on canvas: Canvas) {
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
    }

    private func drawSurfaceShader(on canvas: Canvas) {
        // **同じ形・同じ断片を、違う角度で 2 つ。** 模様が形について回っていれば、
        // 板の傾きに合わせて年輪も傾く。画面に貼り付いていれば、2 つとも同じ向きの
        // 縞になる ([#367](https://github.com/mokume-metal/mokume/issues/367))
        canvas.background(.display(red: 0.06, green: 0.07, blue: 0.09))
        canvas.lights()
        canvas.directionalLight(.display(red: 1, green: 0.95, blue: 0.88), -0.4, 0.7, -0.6)
        canvas.noStroke()
        guard
            let painted = try? canvas.makeShader(
                Scene.grain,
                values: [
                    "pitch": 0.35,
                    "early": .color(.display(red: 0.82, green: 0.64, blue: 0.44)),
                    "late": .color(.display(red: 0.46, green: 0.30, blue: 0.18)),
                ])
        else { return }

        canvas.shader(painted)
        canvas.fill(.display(red: 1, green: 1, blue: 1))
        for (index, spin) in [Float(0), 1.1].enumerated() {
            canvas.push()
            canvas.translate(64, 34 + Float(index) * 60, 0)
            canvas.rotateX(0.55)
            canvas.rotateY(spin)
            canvas.box(78, 10, 46)
            canvas.pop()
        }

        // 組み込みの塗りへ戻すと、模様は消える
        canvas.resetShader()
        canvas.fill(.display(red: 0.9, green: 0.45, blue: 0.35))
        canvas.rect(0, 62, 128, 4)
    }

    private func drawSurfacesShader(on canvas: Canvas) {
        // **平面と立体に同じ断片を効かせる。** 名前で渡した 2 枚 (木目と汚し) が
        // どちらの経路でも届いていることが、1 枚で読める
        canvas.background(.display(red: 0.06, green: 0.07, blue: 0.09))
        canvas.noStroke()
        guard
            let grain = Scene.makeGrain(on: canvas),
            let smudge = Scene.makeSmudge(on: canvas),
            let painted = try? canvas.makeShader(
                Scene.blended,
                values: ["amount": 0.85, "tiling": .pair(2, 2)],
                surfaces: ["grain": .image(grain), "smudge": .image(smudge)])
        else { return }

        canvas.shader(painted)
        canvas.fill(.display(red: 1, green: 1, blue: 1))
        canvas.rect(8, 8, 112, 44)

        // 同じ断片のまま立体へ。光を通した色に掛かるので、陰影は残る
        canvas.lights()
        canvas.directionalLight(.display(red: 1, green: 0.95, blue: 0.88), -0.4, 0.7, -0.6)
        canvas.push()
        canvas.translate(64, 88, 0)
        canvas.rotateX(0.5)
        canvas.rotateY(0.7)
        canvas.box(76, 30, 46)
        canvas.pop()

        // 組み込みの塗りへ戻すと、掛け合わせが消える
        canvas.resetShader()
        canvas.fill(.display(red: 0.9, green: 0.45, blue: 0.35))
        canvas.rect(8, 56, 112, 4)
    }

    private func drawCustomSolids(on canvas: Canvas) {
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
    }

    private func drawSolidStrokes(on canvas: Canvas) {
        // **奥行きを持つ折れ線の輪郭。** 平面の caps / joins は line() と triangle() で
        // 平面の経路に乗るので、立体側の端と折れ目はどのシーンも通っていなかった (#890)
        canvas.background(.display(red: 0.09, green: 0.1, blue: 0.13))
        canvas.noFill()
        canvas.strokeWeight(9)

        // 端と折れ目を**組で**振る。3 本で cap 3 種・join 3 種がすべて通る
        let styles: [(cap: StrokeCap, join: StrokeJoin, tint: (Float, Float, Float))] = [
            (.round, .miter, (0.95, 0.85, 0.35)),
            (.square, .bevel, (0.4, 0.85, 0.95)),
            (.project, .round, (0.95, 0.5, 0.6)),
        ]
        for (index, style) in styles.enumerated() {
            canvas.push()
            canvas.translate(30, 26 + Float(index) * 38, 0)
            canvas.rotateY(0.5)
            canvas.strokeCap(style.cap)
            canvas.strokeJoin(style.join)
            canvas.stroke(
                .display(red: style.tint.0, green: style.tint.1, blue: style.tint.2))
            // **中間の頂点があるので折れ目が効く。** 奥行きを振ってあるので、
            // 横向きが視線から出ていることも絵に現れる
            canvas.beginShape()
            canvas.vertex(0, 0, -14)
            canvas.vertex(34, -18, 8)
            canvas.vertex(68, 6, -8)
            canvas.endShape()
            canvas.pop()
        }
    }

    private func drawViewpoints(on canvas: Canvas) {
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
