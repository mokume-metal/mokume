// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import simd

/// 粒 1 つぶんの状態。
///
/// **GPU 側の同名の構造体と一致していなければならない**
/// (`Shaders/Computations/Particles.metal`)。ずれても例外は出ず、絵が「それらしく」
/// 壊れるだけなので、**一致は GPU 自身に自分の見ている配置を書かせて確かめる**
/// (`ParticleTests` の「配置」) — 大きさを手で書いた定数と突き合わせる形は、
/// 両側の手書きが同時にずれたときに黙って通る。
///
/// 全部が `Float` なのは詰め物を作らないためである。3 成分の組を混ぜると、CPU 側と
/// GPU 側で境界の揃え方が変わりうる。
struct Particle {
    var x: Float = 0
    var y: Float = 0
    var z: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var vz: Float = 0
    /// 残りの寿命 (秒)。**0 以下なら死んでいる。**
    var life: Float = 0
    /// 生まれたときの寿命。
    var span: Float = 0
    /// 大きさ (1 辺の長さ)。
    var size: Float = 0
    /// 塗り。**乗算済み** ([ADR-0012] — 作業空間は乗算済みで運ぶ)。
    ///
    /// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-alpha-semantics.md
    var red: Float = 0
    var green: Float = 0
    var blue: Float = 0
    var alpha: Float = 0
    /// 粒ごとの個体差。揺らぎが粒ごとに違う向きを向くための種。
    var seed: Float = 0
}

/// 端数を繰り越しながら、1 フレームに出す数を決める。
///
/// **繰り越さないと、低いレートで 1 個も出なくなる。** 毎秒 0.5 個を 60 分の 1 秒ずつ
/// 数えると毎回 0.008 個で、切り捨てれば永久に 0 である。しかも**単発の検査では出ない** —
/// 数百フレーム回して初めて「出るはずの数が出ていない」が見える。
struct EmissionCadence {
    /// まだ出していない端数の、``per`` 倍。
    ///
    /// **倍精度で貯める。** 単精度だと 60 分の 1 秒を数百回足す間に誤差が積もり、
    /// 10 秒で 5 個出るはずのものが 4 個になる — 繰り越しを入れた意味が消える。
    ///
    /// **フレーム番号から導く時計では、「rate × 枚数」の単位で貯め、fps で割り切る**
    /// ([#1640])。1/fps 秒を足し合わせる形は、どの精度でも整数のわずか下 (1 個不足) か
    /// わずか上 (1 個超過) に落ちる組がある — 単精度の秒では fps 25・50・100 などで毎秒
    /// 1 個少なく、倍精度の秒に丸めの遊びを足す形では `rate: 71.563` を fps 120 で 6206 枚
    /// 回したところで 1 個多かった。`rate` は `Float` で、足すのはその値そのもの (倍精度で
    /// 厳密) なので、累計は ⌊rate·n ÷ fps⌋ に丸めなしで一致する。
    ///
    /// [#1640]: https://github.com/mokume-metal/mokume/issues/1640
    private(set) var carried: Double = 0
    /// ``carried`` が何分の 1 個を単位にしているか。秒で数えるときは 1、フレーム番号から
    /// 導く時計では fps。
    private var per = 1

    /// この 1 フレームで出す数。`limit` を超えるぶんは繰り越さずに捨てる。
    mutating func take(rate: Float, over step: FrameStep, upTo limit: Int) -> Int {
        guard rate > 0, rate.isFinite, limit > 0 else { return 0 }
        let amount: Double
        let unit: Int
        switch step {
        case .frame(let perSecond):
            guard perSecond > 0 else { return 0 }
            (amount, unit) = (Double(rate), perSecond)
        case .seconds(let seconds):
            guard seconds > 0, seconds.isFinite else { return 0 }
            (amount, unit) = (Double(rate) * seconds, 1)
        }
        // 数え方が替わったら (直に回す面の刻みを差し替えたときなど)、貯めた端数を新しい
        // 単位へ移す。**同じ時計で回している間は起きない**
        if unit != per {
            carried = carried / Double(per) * Double(unit)
            per = unit
        }
        carried += amount
        let whole = Self.wholeUnits(carried, per: per)
        guard whole >= 1 else { return 0 }
        guard whole < Double(limit) else {
            // **貯めたぶんを捨てる。** 捨てないと、容量を超える注文が続いたときに
            // 端数が際限なく積もり、レートを下げても出続ける
            carried = 0
            return limit
        }
        carried -= whole * Double(per)
        return Int(whole)
    }

    /// ⌊`value` ÷ `per`⌋。**割り算の丸めを掛け算で確かめ直す** — 商は整数の近くで上へ
    /// 丸まりうるが、整数と `per` の積は倍精度で厳密なので、比べれば正しい側へ戻せる。
    /// `per` が 1 なら `value` の切り捨てそのもの。
    private static func wholeUnits(_ value: Double, per: Int) -> Double {
        let divisor = Double(per)
        var whole = (value / divisor).rounded(.down)
        if whole * divisor > value {
            whole -= 1
        } else if (whole + 1) * divisor <= value {
            whole += 1
        }
        return whole
    }
}

/// たくさんの粒。
///
/// 使い方は ``Sketch/makeParticles(count:)`` にある。
///
/// ## 置き場はすべて数の並び
///
/// 状態・描画へ渡す置き場所・毎フレームの指定・生存数を数える段・描く引数を、**既にある
/// ``Numbers`` として持つ**。粒のために新しい置き場の仕組みを作らないので、計算の段の
/// 同期も、書き込みを描き切りが届ける控え (#749) もそのまま効く ([ADR-0023] 決定 3 —
/// 同期の話を 2 つ持たない)。
///
/// ## 描く個数は GPU が決める
///
/// 死んだ粒の枠を頂点段に通さないよう、生きている粒だけを**枠の番号順に**詰めて置き、
/// 個数は indirect draw の引数として GPU が書く ([#760])。詰める順序を固定するのは、
/// 半透明の粒が奥行きつきで描かれるためで、順序が動けば重なりが動いて絵が動く。
/// 順位は並列スキャン (prefix sum) で求める — 結果が実行順に依らないので、同じ入力
/// からは同じ絵が出る。段の数は容量から決まり、1 段が 256 倍を数える。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [#760]: https://github.com/mokume-metal/mokume/issues/760
public final class Particles {
    /// 同時に持てる粒の数。
    public let capacity: Int

    /// 1 回に渡せる力の数。
    static let maximumForces = 8
    /// 指定の置き場の頭。**並びの正本はここ** — 読む側は
    /// `Shaders/Computations/Particles.metal` の冒頭にある。
    ///
    ///   [0…15] いまの変換 (4x4) / [16] 1 フレームの長さ / [17] フレーム番号 /
    ///   [18] 効かせる力の数 / [19] スキャンの段の数 / [20] 描く頂点の頭 /
    ///   [21] 描く頂点の数 / [22…26] 段 0…4 の置き場の頭 /
    ///   [27…35] 視点の枠 (横・上・手前を 3 つずつ。``Camera/basis``) / [36…39] 予備 /
    ///   [40…] 力 (1 つ ``Force/slotCount`` 個)
    ///
    /// [19…26] の整数は `UInt32` のビット列として置く (`Float` に直すと 2^24 を超えた
    /// ところで丸まる)。
    static let headerFloats = 40
    /// 視点の枠の頭。
    static let basisOffset = 27
    /// スキャンの区画の大きさ。**GPU 側の `MOKUME_PARTICLE_BLOCK` と一致していなければ
    /// ならない** (一致は `ParticleTests` の「配置」が見る)。
    static let scanBlock = 256
    /// 段の置き場の頭を渡せる数 (段 0…4)。256^4 = 2^32 個までの粒を数えられる —
    /// `UInt32` で数える上限と同じところで尽きる。
    static let maximumLevels = 5
    /// 描く引数の長さ (`MTLDrawPrimitivesIndirectArguments` の 4 語)。
    static let argumentFloats = 4

    /// 粒の状態。
    let state: Numbers
    /// 1 回の ``Canvas/particles(_:)`` が書き、読む置き場の組 ([#1651])。
    ///
    /// **組は呼び出しごとに要る。** 描き切りは控えを計算より先に 1 度だけ届け、計算をすべて
    /// 描画より先に流す ([ADR-0023] の「描く前に GPU で計算し」)。群で 1 組だと、同じ描き切りの
    /// 中で 2 回呼んだとき、1 回目の計算も 2 回目の指定を読み、1 回目の列も 2 回目の計算が
    /// 書いた置き場所で描かれる — 1 回目の雲が消え、1 回目の前に積んだ力も効かない。
    ///
    /// 状態 (``state``) と段 (``levels``) は分けない。2 回目は 1 回目が進めた状態を読んで
    /// 重ねて進めるもので、段は 2 回目の旗が 1 回目の進めの後に口を切るので取り合わない。
    ///
    /// [#1651]: https://github.com/mokume-metal/mokume/issues/1651
    struct Draw {
        /// 毎回の指定 (変換と力)。
        let parameters: Numbers
        /// 描画へ渡す置き場所の並び。``SolidInstance`` と同じ並びを数として持つ。
        /// **先頭から生存数ぶんだけが意味を持つ。**
        let instances: Numbers
        /// 描く引数 (`MTLDrawPrimitivesIndirectArguments` と同じ並び)。GPU が書き、描く側が
        /// そのまま indirect draw に渡す。**CPU は読まない。**
        let arguments: Numbers
    }

    /// 置き場の組。**先頭は作るときに確保し**、2 つ目からは、まだ読まれていない組しか無い
    /// ときに 1 つずつ足す (``claimDraw(by:)``)。足した組は手放さずに使い回すので、並びは
    /// 1 回の描き切りの中で呼んだ最多の回数までしか伸びない。1 回ずつ呼ぶスケッチは先頭だけを使う。
    ///
    /// **検査が読む。**
    private(set) var draws: [Draw]
    /// 組ごとに、最後に使った面と、そのときの面の描き切りの印 (``Canvas/settleMark``)。
    /// 印が変わった組は、書いた指定を読む計算も、置き場所を読む列も投入か破棄を済ませている。
    private var claims: [(canvas: Weak<Canvas>, mark: Canvas.SettleMark)?]

    /// 先頭の組の置き場所。
    var instances: Numbers { draws[0].instances }
    /// 先頭の組の指定。
    var parameters: Numbers { draws[0].parameters }
    /// 生存数を数える段の置き場。段 k は ``levelLengths`` の k 番目の長さで、
    /// ``levelOffsets`` の位置から並ぶ。**最上段は 1 個で、それが生存数。**
    let levels: Numbers
    /// 段ごとの頭 [長さ, 読む段の頭, 書く段の頭]。**作るときに 1 度書く。**
    let levelHeaders: [Numbers]
    /// 先頭の組の描く引数。
    var arguments: Numbers { draws[0].arguments }
    /// 段ごとの長さ。先頭が容量、末尾が 1。
    let levelLengths: [Int]
    /// 段ごとの、``levels`` の中での頭。
    let levelOffsets: [Int]
    /// 粒 1 つを描く形。**保持した形をそのまま使う**ので、粒だけ別の頂点経路を持たない。
    let quad: Shape
    /// 生き残る粒に旗を立てる計算。
    let flag: Computation
    /// 旗を数える 1 段ぶんの計算。段の数だけ積む。
    let scan: Computation
    /// 1 フレーム進めて、生き残る粒を詰めて置く計算。
    let update: Computation

    /// 1 フレームに積む計算の数。旗 1 + 段の数 + 進める 1。
    var dispatchCount: Int { 2 + scanCount }
    /// スキャンの段の数。容量 1 なら 0 (旗そのものが生存数)。
    var scanCount: Int { levelLengths.count - 1 }

    /// 段ごとの長さ。**容量から一意に決まる** — 256 で割り上げて 1 になるまで重ねる。
    static func levelLengths(capacity: Int) -> [Int] {
        // `max(1, …)` は、`makeParticles` が 1 未満を断っているので届かない (#1642)。段を
        // 1 つは残す守りとして残す (0 を渡しても段が空にならないことを ParticleTests が見る)
        var lengths = [max(1, capacity)]
        while let last = lengths.last, last > 1 {
            lengths.append((last + scanBlock - 1) / scanBlock)
        }
        return lengths
    }

    /// 次に書き込む枠。**環状に回る。**
    ///
    /// **検査が読む。**
    private(set) var cursor = 0
    /// 端数の繰り越し。**そのフレームで何回目の `emit` か**で分けて持つ ([#1468])。
    ///
    /// 1 つにすると、1 つの粒へ何か所から出したときに噴き口どうしが端数を取り合い、
    /// 先に呼んだ側から 1 個も出ないことがある — 毎秒 15 個を 30 fps で 2 か所なら、
    /// 1 か所目が 0.5 を足して 0 個、2 か所目が 1 に届いて 1 個、を毎フレーム繰り返す。
    /// 呼んだ順で分けるので、同じ 1 行 (`for` の中) から何度呼んでも分かれ、1 か所から
    /// 出す使い方はいままでと同じ 1 つ目を引いて数が変わらない。
    ///
    /// **呼ぶ順や回数がフレームごとに変わると、1 個未満の端数が別の噴き口へ移りうる**
    /// (条件付きで出す噴き口があるとき)。移るのは入れ替わるたびに 1 個未満で、毎フレーム
    /// 取り合うことはない。並びは縮めない — 噴き口の数ぶんしか伸びない。
    ///
    /// [#1468]: https://github.com/mokume-metal/mokume/issues/1468
    private var cadences: [EmissionCadence] = []
    /// 呼んだ順を数えているフレーム (面の `Canvas.framesDrawn`)。変わったら数え直す。
    private var cadenceFrame: Int?
    /// `cadenceFrame` のフレームで、これまでに数えた `emit` の回数。
    private var emitsThisFrame = 0
    /// 枠ごとの「いつまで生きるか」。
    ///
    /// **CPU だけが読む。** 寿命を配ったのは CPU なので、GPU から読み戻さなくても
    /// 「まだ生きている粒を上書きした」が分かる。
    private var deadline: [Float]
    /// この フレームで積まれた力。**進めるときに空になる。**
    private var pendingForces: [Force] = []

    /// 1 度だけ言う注意の種類。仕組みは ``WarningLog`` が持つ ([#734])。
    ///
    /// [#734]: https://github.com/mokume-metal/mokume/issues/734
    enum Warning: Hashable {
        /// まだ生きている粒を上書きした。
        case overwrite
        /// 効かせられる数を超えた力を渡された。
        case tooManyForces
        /// 引く力の弱まり始める距離に、受け取れない値が渡された。
        case badWeakeningDistance
        /// 数でない値・無限を成分に持つ力を渡された ([#1623])。
        ///
        /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
        case unacceptableForce
        /// `emit` の引数に数でない値・無限が渡された ([#1623])。
        ///
        /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
        case unacceptableEmission
        /// 減速に負の値が渡された ([#1623] の反証)。
        ///
        /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
        case negativeDrag
        /// `emit` の `rate` に負の値が渡され、0 として扱った ([#1698])。
        ///
        /// **引数ごとに鍵を分ける** (#1698 の反証 9)。共有すると、先に言った引数が後の引数の
        /// 書き間違いを黙らせる。どれも ``unacceptableEmission`` とも分ける — あちらは 1 個も
        /// 出さず、こちらは 0 として扱って出す。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case negativeRate
        /// `emit` の `life` の下端が負で、引いた値の 0 より下を 0 として扱った。分ける理由は
        /// ``negativeRate``。
        case negativeLife
        /// `emit` の `size` の下端が負で、引いた値の 0 より下を 0 として扱った。分ける理由は
        /// ``negativeRate``。
        case negativeSize
        /// `emit` の `from` (円・球) の半径が負で、絶対値として扱った ([#1698] の反証 7)。
        /// 分ける理由は ``negativeRate``。
        ///
        /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
        case negativeRadius
        /// 同じ描き切りの中で 2 回目以降に呼ばれたが、その呼び出しの置き場を足せなかった
        /// ([#1651])。
        ///
        /// [#1651]: https://github.com/mokume-metal/mokume/issues/1651
        case drawUnavailable
    }

    /// 言った注意の控え。**検査が読む。**
    private(set) var warnings = WarningLog<Warning>()

    /// まだ言っていなければ、その注意を 1 度だけ言う。
    private func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }

    init(
        capacity: Int, state: Numbers, instances: Numbers, parameters: Numbers,
        levels: Numbers, levelHeaders: [Numbers], arguments: Numbers, levelLengths: [Int],
        quad: Shape, flag: Computation, scan: Computation, update: Computation
    ) {
        self.capacity = capacity
        self.state = state
        self.draws = [Draw(parameters: parameters, instances: instances, arguments: arguments)]
        self.claims = [nil]
        self.levels = levels
        self.levelHeaders = levelHeaders
        self.levelLengths = levelLengths
        var offsets: [Int] = []
        var offset = 0
        for length in levelLengths {
            offsets.append(offset)
            offset += length
        }
        self.levelOffsets = offsets
        self.quad = quad
        self.flag = flag
        self.scan = scan
        self.update = update
        self.deadline = Array(repeating: -.greatestFiniteMagnitude, count: capacity)

        // 段の頭は容量から決まるので、**ここで 1 度だけ書く**。控えに積まれ、最初の
        // 描き切りが計算より前に届ける
        for (level, header) in levelHeaders.enumerated() {
            header.set([
                Float(bitPattern: UInt32(levelLengths[level])),
                Float(bitPattern: UInt32(levelOffsets[level])),
                Float(bitPattern: UInt32(levelOffsets[level + 1])),
                0,
            ])
        }
    }

    /// 力を積む。**上限を超えたぶんは受け取らない** — 進めずに積み続けても際限なく
    /// 増えないようにするため。
    ///
    /// **数でない値・無限を成分に持つ力は、注意を言って積まない** ([#1623]・ADR-0020 決定 5)。
    /// 積むと GPU で、効かせた群の**すべての粒**の速度が数でなくなり、その粒は寿命まで
    /// 描かれない — 1 度渡しただけで、生きている粒が全部消える。断った力は上限の枠を取らず、
    /// 同じ呼び出しに並べた他の力は今までどおり積む。検めるのはここ 1 か所で、GPU へ
    /// 渡す手前 (`write`) には散らさない。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    func add(_ forces: [Force]) {
        for force in forces {
            guard force.numbers.allSatisfy(\.isFinite) else {
                warnUnacceptableForce(force)
                continue
            }
            guard let force = accepted(force) else { continue }
            guard pendingForces.count < Self.maximumForces else {
                return warnTooManyForces(pendingForces.count + 1)
            }
            pendingForces.append(force)
        }
    }

    /// 受け取れる形にした力。受け取らない力は `nil` (ADR-0020 決定 5)。
    ///
    /// - **弱まり始める距離が 0 以下・数でない値・無限なら、注意を言って距離を外す** —
    ///   弱まらない力として効かせる。式へ届かせないのは、0 なら力が消え、負なら向きが
    ///   返り、数でない値なら粒の速度が数でなくなるためである
    /// - **減速の `amount` が負なら、注意を言って積まない** — 減速は「速さは増えない」
    ///   (``Force/drag(_:)``) の約束で、負の値は 1 フレームごとに速度を e^{|amount|·Δt} 倍に
    ///   増やす。30 fps の `drag(-10000)` では 1 フレームで溢れる (#1623 の反証)。0 と
    ///   同じく効かない力として扱う
    private func accepted(_ force: Force) -> Force? {
        switch force {
        case .attract(let x, let y, let z, let strength, let distance?)
        where !(distance.isFinite && distance > 0):
            warnBadWeakeningDistance(distance)
            return .attract(x, y, z, strength: strength)
        case .drag(let amount) where amount < 0:
            warnNegativeDrag(amount)
            return nil
        default:
            return force
        }
    }

    /// いま積んである力の数。面が、フレームで最初に力を積む前の数を控えるのに読む。
    var pendingForceCount: Int { pendingForces.count }

    /// `count` 個目より後に積んだ力を落とす。**捨てたフレームで積んだ力だけを落とす**ための口で
    /// ([#1622])、それより前に積んだ力 (前のフレームで積んで、まだ進めていないもの) は残す —
    /// 力は「次に進めるときにまとめて効く」約束なので、前のフレームの力は捨てたフレームに
    /// 属さない。
    ///
    /// [#1622]: https://github.com/mokume-metal/mokume/issues/1622
    func dropForces(after count: Int) {
        guard pendingForces.count > count else { return }
        pendingForces.removeLast(pendingForces.count - count)
    }

    /// 積まれた力を取り出して空にする。
    func takeForces() -> [Force] {
        defer { pendingForces.removeAll(keepingCapacity: true) }
        return pendingForces
    }

    /// `canvas` のこの呼び出しが使う置き場の組を選ぶ ([#1651])。**まだ読まれていない組は
    /// 使わない** — 空いた組のうち先頭のものを使い、空きが無ければ 1 つ足す。
    ///
    /// 空いているのは、使った面が居なくなったか、使ったときから面の描き切りの印が変わった
    /// 組である。**面をまたいでも効く**: 本体で呼んで組 0 を取った後に描き場所で呼ぶと、組 0 は
    /// 本体の描き切りを待っているので、描き場所は組 1 を使う。控えの登録簿は面をまたいで
    /// 1 つで、どの面の描き切りも全部を届けるが、別の並びなので本体の指定を上書きしない。
    ///
    /// 足すのに失敗したら投げる。何も選ばないので、呼ぶ側は進めも描きもせずに帰る。
    ///
    /// [#1651]: https://github.com/mokume-metal/mokume/issues/1651
    func claimDraw(by canvas: Canvas) throws(RenderFailure) -> Draw {
        let free = claims.firstIndex { claim in
            guard let claim, let owner = claim.canvas.value else { return true }
            return owner.settleMark != claim.mark
        }
        let index: Int
        if let free {
            index = free
        } else {
            if let drawAllocationFailureForTesting { throw drawAllocationFailureForTesting }
            let first = draws[0]
            let gpu = first.parameters.gpu
            draws.append(
                Draw(
                    parameters: try Numbers(gpu: gpu, count: first.parameters.count),
                    instances: try Numbers(gpu: gpu, count: first.instances.count),
                    arguments: try Numbers(gpu: gpu, count: first.arguments.count)))
            claims.append(nil)
            index = draws.count - 1
        }
        claims[index] = (Weak(canvas), canvas.settleMark)
        return draws[index]
    }

    /// 組を足すときに投げる失敗。**検査が差し替える** (確保の失敗は検査の中で起こせない)。
    var drawAllocationFailureForTesting: RenderFailure?

    /// 組を足せなかったことを知らせる。
    func warnDrawUnavailable(_ failure: RenderFailure) {
        warnOnce(
            .drawUnavailable,
            "particles() was called again before the earlier call was drawn, and no room could be "
                + "made for another placement (\(failure.headline)). That call neither advanced nor "
                + "drew the particles; forces added before it take effect in the next call")
    }

    /// この 1 フレームで出す数。`frame` は呼んだ面のフレーム番号で、同じ番号のうちに
    /// 呼ばれた順で繰り越しを引き分ける (`cadences` の説明)。**0 個に終わる呼び出しも
    /// 1 回と数える** — 数えないと、出なかった噴き口の後ろの繰り越しが 1 つずつ前へずれる。
    func count(rate: Float, over step: FrameStep, frame: Int) -> Int {
        if cadenceFrame != frame {
            cadenceFrame = frame
            emitsThisFrame = 0
        }
        let order = emitsThisFrame
        emitsThisFrame += 1
        if order == cadences.count { cadences.append(EmissionCadence()) }
        return cadences[order].take(rate: rate, over: step, upTo: capacity)
    }

    /// 粒を出す受け口。**1 フレームで出す数を決めて (`count(rate:over:frame:)`)、その数を
    /// 置く。**
    ///
    /// **数でない値・無限を受けたら、注意を言って 1 個も出さない** ([#1623]・ADR-0020
    /// 決定 5)。見るのは `rate`・`source` の成分・幅の端・`color` の成分である (幅の端の
    /// 数でない値は、Swift の `...` が幅を作る時点で止めるので届かない)。出してしまうと、
    /// 数でない位置や色の粒が寿命まで枠を塞ぎ、描いた画素を汚しうる。検めるのはここ
    /// 1 か所で、置く手前 (`place`) には散らさない。
    ///
    /// **断った呼び出しも、そのフレームの 1 回と数える** — 数えないと、後ろの噴き口の
    /// 繰り越しが前へずれる (`count(rate:over:frame:)` と同じ理由)。繰り越しには何も足さない。
    ///
    /// [#1623]: https://github.com/mokume-metal/mokume/issues/1623
    func emit(
        rate: Float, over step: FrameStep, frame: Int, from source: Emitter,
        speed: ClosedRange<Float>, angle: ClosedRange<Float>, life: ClosedRange<Float>,
        size: ClosedRange<Float>, color: LinearRGBA?, fill: LinearRGBA, at now: Float,
        using randomness: inout Randomness
    ) {
        if let refused = Self.unacceptable(
            rate: rate, from: source, speed: speed, angle: angle, life: life, size: size,
            color: color, fill: fill)
        {
            _ = count(rate: 0, over: step, frame: frame)
            return warnUnacceptableEmission(
                "\(refused.name) got \(refused.value), which is not a number or is infinite. "
                    + "No particles were emitted from that call")
        }
        warnNegative(rate: rate, from: source, life: life, size: size)
        let count = count(rate: rate, over: step, frame: frame)
        place(
            count, from: source, speed: speed, angle: angle, life: life, size: size,
            color: color ?? fill, at: now, using: &randomness)
    }

    /// 受け取れない `emit` の引数の名前と、渡された値の綴り。どれも受け取れるなら `nil`。
    /// 見る順は引数の並びどおりで、最初の 1 つだけを返す。
    ///
    /// `color` を省いたときは塗り (`fill`) で出すので、塗りを見て**塗りと名指す** — `color`
    /// と言うと、渡していない引数を名乗ることになる (#1623 の反証)。
    private static func unacceptable(
        rate: Float, from source: Emitter, speed: ClosedRange<Float>,
        angle: ClosedRange<Float>, life: ClosedRange<Float>, size: ClosedRange<Float>,
        color: LinearRGBA?, fill: LinearRGBA
    ) -> (name: String, value: String)? {
        func finite(_ range: ClosedRange<Float>) -> Bool {
            range.lowerBound.isFinite && range.upperBound.isFinite
        }
        if !rate.isFinite { return ("rate", "\(rate)") }
        if !source.numbers.allSatisfy(\.isFinite) { return ("from", "\(source)") }
        if !finite(speed) { return ("speed", "\(speed)") }
        if !finite(angle) { return ("angle", "\(angle)") }
        if !finite(life) { return ("life", "\(life)") }
        if !finite(size) { return ("size", "\(size)") }
        let paint = color ?? fill
        // 色の値の受け口と同じ述語で見る (#1706 の反証 8)。塗りは `fill(_:)` が断るので公開の道
        // からは数でなくならないが、`color:` は利用者が直に渡すのでここが受け口である
        if !paint.isFinite {
            let channels = [paint.red, paint.green, paint.blue, paint.alpha]
            let name = color == nil ? "the fill (color was omitted)" : "color"
            return (name, "(\(channels.map { "\($0)" }.joined(separator: ", ")))")
        }
        return nil
    }

    /// 粒を `count` 個置く。
    ///
    /// **待たない。** 状態の並びへの書き込みは控えに積まれ、次の描き切り (か読み戻し) が GPU 側の
    /// コピーで届ける ([#749])。届くのは、書く前に頼んだ計算 (このフレームで先に呼んだ
    /// `particles()` の刻み) の後で、書いた後に頼んだ計算の前である — 書く前に頼んだ計算は、書く口が
    /// 先に投入する ([#1687])。先に投入した計算がまだ同じ並びを読み書きしていても、コピーはそれが
    /// 終わってから走る (計算の最後の口が待たせる) — かつては書く直前に投入済みの全部を待っていて、
    /// 粒を使うフレームでは CPU と GPU が重ならなかった。
    ///
    /// 枠と寿命はここで進む。控えは描き切りが待てなくても捨てずに持ち越す ([#934]) ので、
    /// 進めた枠は必ずいつか書かれる。
    ///
    /// **並びへは、続いた枠をまとめて書く** ([#1748])。粒ごとに書くと、書くたびに汚れ区間の
    /// 畳み込み・世代・控えへの登録を払い、2 万粒で 1.7 ms かかっていた (届けるコピーは
    /// 隣り合う区間が畳まれて元から 1 本)。乱数を引く順・上書きの注意・寿命の控えは粒ごとの
    /// ままなので、書き込まれる値は 1 粒ずつ書いたときと同じである。
    ///
    /// [#749]: https://github.com/mokume-metal/mokume/issues/749
    /// [#934]: https://github.com/mokume-metal/mokume/issues/934
    /// [#1687]: https://github.com/mokume-metal/mokume/issues/1687
    /// [#1748]: https://github.com/mokume-metal/mokume/issues/1748
    private func place(
        _ count: Int, from source: Emitter, speed: ClosedRange<Float>,
        angle: ClosedRange<Float>, life: ClosedRange<Float>, size: ClosedRange<Float>,
        color: LinearRGBA, at now: Float, using randomness: inout Randomness
    ) {
        guard count > 0 else { return }
        // 溜めた粒は枠 `firstSlot` から続いている。書き出したら空にする
        var firstSlot = 0
        defer { flushPlacement(from: firstSlot) }
        for _ in 0..<count {
            let place = source.sample(using: &randomness)
            // **中心と半径が有限でも、足した所が `Float` で溢れることがある** (`.circle(3e38, 0,
            // radius: 3e38)`)。数でない位置の粒は寿命まで枠を塞いで描かれないので、置かない
            // (#1623 の反証)。枠も進めない
            guard all(place .< .infinity) && all(place .> -.infinity) else {
                warnUnacceptableEmission(
                    "from \(source) placed a particle at \(place), outside the range of Float. "
                        + "Particles that land there were not emitted")
                continue
            }
            let slot = cursor % capacity
            cursor += 1
            if deadline[slot] > now { warnOverwrite() }

            let heading = randomness.value(from: angle.lowerBound, to: angle.upperBound)
            let rate = randomness.value(from: speed.lowerBound, to: speed.upperBound)
            let span = max(0, randomness.value(from: life.lowerBound, to: life.upperBound))
            let extent = max(0, randomness.value(from: size.lowerBound, to: size.upperBound))

            // 環を回り込んで先頭へ戻ったら、溜めた区間はそこで切れる。上限に達したときも
            // 書き出す (溜める置き場を容量に比例させない)
            if !placement.isEmpty,
                slot != firstSlot + placement.count || placement.count >= placementChunk
            {
                flushPlacement(from: firstSlot)
            }
            if placement.isEmpty { firstSlot = slot }
            placement.append(
                Particle(
                    x: place.x, y: place.y, z: place.z,
                    vx: cos(heading) * rate, vy: sin(heading) * rate, vz: 0,
                    life: span, span: span, size: extent,
                    red: color.red, green: color.green, blue: color.blue, alpha: color.alpha,
                    seed: randomness.unitValue()))
            deadline[slot] = now + span
        }
    }

    /// 置いた粒を溜める置き場。**フレームをまたいで使い回す** — 空にしても確保は残す。
    private var placement: [Particle] = []

    /// 1 度にまとめて書く粒の数の上限。**検査が 1 に差し替えて、1 粒ずつ書いた物差しを作る。**
    var placementChunk = 1024

    /// 溜めた粒を、枠 `firstSlot` から続く 1 つの区間として状態の並びへ書き、置き場を空にする。
    private func flushPlacement(from firstSlot: Int) {
        guard !placement.isEmpty else { return }
        let floats = Self.particleFloats
        // **区間を丸ごと書く** (`Numbers.write` の約束)。粒は全部が `Float` なので
        // 詰め物が無く、並びの 1 区画がそのまま粒 1 つになる
        state.write(at: firstSlot * floats, count: placement.count * floats) { target in
            placement.withUnsafeBytes { raw in
                _ = target.update(fromContentsOf: raw.bindMemory(to: Float.self))
            }
        }
        placement.removeAll(keepingCapacity: true)
    }

    /// 粒 1 つが並びの中で占める数。
    static let particleFloats = MemoryLayout<Particle>.stride / MemoryLayout<Float>.stride

    /// この 1 フレームの指定を置く。
    ///
    /// **数値も同じ置き場から渡す。** 計算に値を渡す口 (`Values`) を使うと、値を渡さない
    /// 形で組み立てるビルド時のシェーダ検査から外れてしまう — 組み込みの計算こそ、
    /// 走らせる前に壊れていることが分かってほしい。
    ///
    /// `vertexStart` / `vertexCount` は描く側が四角を置いた区間で、GPU がそのまま描く引数へ
    /// 写す。参照の経路 (CPU が置く) では使われないので 0 でよい。
    ///
    /// `basis` は視点の枠 (``Camera/basis``) で、GPU が板をそれに沿って置く。
    ///
    /// **待たない。** 粒を置くのと同じく控えに積み、描き切りが届ける (#749)。
    func write(
        into draw: Draw, transform: simd_float4x4, basis: simd_float3x3, step: Float, frame: Int,
        forces: [Force], vertexStart: Int, vertexCount: Int
    ) {
        if forces.count > Self.maximumForces { warnTooManyForces(forces.count) }
        let used = min(forces.count, Self.maximumForces)
        // 読まれるのは頭と、効かせる数ぶんの力だけ。**書く区間はそこまでで、全部を書く**
        draw.parameters.write(at: 0, count: Self.headerFloats + used * Force.slotCount) { values in
            for column in 0..<4 {
                let vector = transform[column]
                for row in 0..<4 { values[column * 4 + row] = vector[row] }
            }
            values[16] = step
            values[17] = Float(frame)
            values[18] = Float(used)
            // 整数は **ビット列のまま**置く (上の `headerFloats` の理由)
            values[19] = Float(bitPattern: UInt32(scanCount))
            values[20] = Float(bitPattern: UInt32(clamping: vertexStart))
            values[21] = Float(bitPattern: UInt32(clamping: vertexCount))
            for slot in 0..<Self.maximumLevels {
                let offset = slot < levelOffsets.count ? levelOffsets[slot] : 0
                values[22 + slot] = Float(bitPattern: UInt32(offset))
            }
            for column in 0..<3 {
                let vector = basis[column]
                for row in 0..<3 { values[Self.basisOffset + column * 3 + row] = vector[row] }
            }
            for index in (Self.basisOffset + 9)..<Self.headerFloats { values[index] = 0 }
            for (index, force) in forces.prefix(used).enumerated() {
                for (offset, value) in force.packed.enumerated() {
                    values[Self.headerFloats + index * Force.slotCount + offset] = value
                }
            }
        }
    }

    /// 生きている粒の置き場所を、番号の順に作る。**参照の描画経路と検査が使う。**
    ///
    /// GPU の `mokume_particles` と**同じ式**で組む (``billboard(x:y:z:size:transform:basis:)``)。
    func living(
        from values: [Float], transform: simd_float4x4, basis: simd_float3x3
    ) -> [SolidInstance] {
        var places: [SolidInstance] = []
        places.reserveCapacity(capacity / 8)
        values.withUnsafeBytes { raw in
            let slots = raw.bindMemory(to: Particle.self)
            for index in 0..<min(capacity, slots.count) {
                let particle = slots[index]
                guard particle.life > 0 else { continue }
                places.append(
                    SolidInstance(
                        matrix: Self.billboard(
                            x: particle.x, y: particle.y, z: particle.z, size: particle.size,
                            transform: transform, basis: basis),
                        normalMatrix: basis,
                        color: LinearRGBA(
                            premultipliedRed: particle.red, green: particle.green,
                            blue: particle.blue, alpha: particle.alpha)))
            }
        }
        return places
    }

    /// 粒 1 つの板を置く行列。**板は視点の枠に沿う** (#1043)。
    ///
    /// 板の縦横は視点の横・上へ向け、変換からは**各軸の倍率 (列の長さ) だけ**を受け取る。
    /// 変換の回転まで受け取ると、視点を回したときと同じく `rotateY()` で雲ごと回した
    /// ときにも板が横を向いて痩せる。位置だけは変換をそのまま通す。
    ///
    /// 既定の視点では枠が厳密に単位行列で、回さない変換の列の長さも厳密に倍率なので、
    /// 板を軸に沿って置いていた頃と**値が 1 ビットも変わらない**。
    ///
    /// **GPU 側 (`Shaders/Computations/Particles.metal`) と同じ式でなければならない。**
    static func billboard(
        x: Float, y: Float, z: Float, size: Float, transform: simd_float4x4,
        basis: simd_float3x3
    ) -> simd_float4x4 {
        func span(_ column: SIMD4<Float>) -> Float {
            length(SIMD3(column.x, column.y, column.z))
        }
        let center = transform * SIMD4(x, y, z, 1)
        return simd_float4x4(
            SIMD4(basis.columns.0 * (size * span(transform.columns.0)), 0),
            SIMD4(basis.columns.1 * (size * span(transform.columns.1)), 0),
            SIMD4(basis.columns.2 * (size * span(transform.columns.2)), 0),
            center)
    }

    private func warnOverwrite() {
        warnOnce(
            .overwrite,
            "The ring of \(capacity) particle slots came all the way round and overwrote particles "
                + "that were still alive. rate × life is larger than the ring, so raise "
                + "makeParticles(count:), or lower rate or life")
    }

    private func warnTooManyForces(_ count: Int) {
        warnOnce(
            .tooManyForces,
            "At most \(Self.maximumForces) forces can go in one call (\(count) were passed). "
                + "Only the first \(Self.maximumForces) took effect")
    }

    private func warnUnacceptableForce(_ force: Force) {
        warnOnce(
            .unacceptableForce,
            "force(): \(force) has a value that is not a number, or an infinite one. "
                + "That force was left out; the other forces in the call still took effect")
    }

    /// `problem` は受け取れなかった引数の名前で始める (検査が名前を読む)。
    private func warnUnacceptableEmission(_ problem: String) {
        warnOnce(.unacceptableEmission, "emit(): \(problem)")
    }

    /// 0 より小さくならない量に負の値が渡されたことを、引数ごとに初回だけ知らせる ([#1698])。
    ///
    /// **扱いは変えない** — 負の `rate` は 0 個 (`EmissionCadence.take`)、`life`・`size` は
    /// 引いた値の 0 より下を 0 にする (`place`)、円・球の負の半径は絶対値で読む
    /// (`Emitter.sample`)。丸めたことを言わないのは ADR-0020 決定 5 の「警告を出して」に反する
    /// ので、知らせだけを足す。文面の形は面の ``Canvas/warnRounded(_:_:_:takes:passed:used:)``
    /// と揃える。
    ///
    /// [#1698]: https://github.com/mokume-metal/mokume/issues/1698
    private func warnNegative(
        rate: Float, from source: Emitter, life: ClosedRange<Float>, size: ClosedRange<Float>
    ) {
        // 毎フレーム呼ばれる口なので、並びを組まずに 1 つずつ見る
        if rate < 0 {
            warnOnce(
                .negativeRate, "emit(): rate takes 0 or more, but \(rate) was passed, so 0 was used")
        }
        switch source {
        case .circle(_, _, let radius) where radius < 0, .sphere(_, _, _, let radius) where radius < 0:
            warnOnce(
                .negativeRadius,
                "emit(): the radius of from takes 0 or more, but \(source) was passed, so "
                    + "\(-radius) was used")
        default: break
        }
        func partBelowZero(_ name: String, _ range: ClosedRange<Float>) -> String {
            "emit(): \(name) takes 0 or more, but \(range) was passed, so the part below 0 was "
                + "used as 0"
        }
        if life.lowerBound < 0 { warnOnce(.negativeLife, partBelowZero("life", life)) }
        if size.lowerBound < 0 { warnOnce(.negativeSize, partBelowZero("size", size)) }
    }

    private func warnNegativeDrag(_ amount: Float) {
        warnOnce(
            .negativeDrag,
            "drag: amount takes 0 or more (\(amount) was passed), because drag never speeds "
                + "a particle up. That drag was left out")
    }

    private func warnBadWeakeningDistance(_ distance: Float) {
        warnOnce(
            .badWeakeningDistance,
            "attract / repel: weakeningBeyond takes a distance larger than 0 (\(distance) was passed). "
                + "The pull was applied at full strength at every distance instead")
    }
}
