// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// **約束を述語で書き、入力は seed つきで生成して探させる** ための小さな道具 (#3207 の提案 1・#3216)。
///
/// 検査は「1 件の Bug に 1 本の固定の例」の形だと、直した入力の 1 点しか見ない。ここでは入力の
/// 座標 (``ProbeAxis``) を範囲で書き、case ごとの seed から値を作って述語に渡す。赤になったら、
/// 赤のまま保てる限り単純な値へ縮めて (shrinking)、seed と縮めた入力を名乗る。
///
/// パッケージの依存は足さない (Foundation だけ)。`Testing` にも依らず、赤の文を返すだけにする —
/// 判定 (`#expect`) は呼ぶ側の検査が持つ。
///
/// ## seed
///
/// - PR・queue では **固定の seed** で回す (#3207 の判断 2)。土台の seed は `key` から導くので、
///   同じ木では毎回同じ入力になり、関係の無い PR が赤くならない
/// - 環境変数 (無ければ上の既定):
///   - `MOKUME_PROBE_SEED=0x…` — どの ``Probe/run(_:suite:key:axes:cases:shrinkSteps:check:)`` も、
///     その seed の 1 件だけを走らせる。赤の文面が名乗る seed を渡せば、同じ入力の同じ赤を再現する
///     (`--filter` で検査を絞って使う)
///   - `MOKUME_PROBE_FRESH=1` — 土台の seed を実行ごとに新しくする (定期の検査だけが立てる)
///   - `MOKUME_PROBE_SCALE=<n>` — 件数を n 倍する (定期の検査だけが立てる)
///
/// ## 帰属の表
///
/// `suite` は `Tests/probe-catalog.tsv` に載っていなければならない (#3207 の K2)。載っていない
/// suite から呼ぶと、述語を回す前に赤の文を返す。表は、どの提案の検査が何を見つけ・何を殺したかを
/// 後から記録だけで引くためにある (#3221 が読む)。
public nonisolated enum Probe {
    /// 生成した入力を述語に渡した結末。
    public enum Outcome: Sendable, Equatable {
        /// 約束が成り立った。
        case pass
        /// この入力は約束の外で、見ない (数えるだけ)。
        case skip
        /// 約束が破れた。文は何がどう外れたか。
        case fail(String)
    }

    /// 1 回の ``run(_:suite:key:axes:cases:shrinkSteps:check:)`` の結果。
    public struct Report: Sendable {
        /// 赤の文面 (K1 の形)。緑なら `nil`。
        public let failure: String?
        /// 述語が `pass` か `fail` を返した件数。
        public let ran: Int
        /// 述語が `skip` を返した件数。
        public let skipped: Int
    }

    /// `axes` の範囲から `cases` 件の入力を作って `check` に渡し、最初に赤になった入力を縮めて名乗る。
    ///
    /// - Parameters:
    ///   - name: 提案の名 (`Tests/probe-catalog.tsv` の 2 列目)。赤の文面の先頭に `[name seed=…]` で出る
    ///   - suite: 呼ぶ検査の suite の型名 (表の 1 列目)
    ///   - key: 土台の seed を導く文字列。同じ suite の中で口ごとに入力を変えたいときに口の名を渡す
    ///   - shrinkSteps: 縮めるときに述語を呼び直す回数の上限 (GPU の描き直しの回数を縛る)
    public static func run(
        _ name: String, suite: String, key: String, axes: [ProbeAxis], cases: Int, shrinkSteps: Int = 40,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        check: (ProbeInput) throws -> Outcome
    ) rethrows -> Report {
        if let missing = ProbeCatalog.missing(suite: suite, name: name) {
            return Report(failure: "[\(name)] \(missing)", ran: 0, skipped: 0)
        }
        let plan = ProbePlan(key: key, cases: cases, environment: environment)
        var ran = 0
        var skipped = 0
        for seed in plan.seeds {
            let input = ProbeInput(axes: axes, seed: seed)
            switch try check(input) {
            case .pass: ran += 1
            case .skip: skipped += 1
            case .fail(let message):
                ran += 1
                let (shrunk, shrunkMessage) = try shrink(input, message: message, steps: shrinkSteps, check: check)
                var text = "[\(name) seed=\(ProbeSeed.format(seed))] \(shrunk): \(shrunkMessage)"
                if shrunk.values != input.values { text += " (縮める前: \(input): \(message))" }
                if plan.isFresh { text += " (土台の seed \(ProbeSeed.format(plan.base)) は実行ごとに新しい)" }
                return Report(failure: text, ran: ran, skipped: skipped)
            }
        }
        return Report(failure: nil, ran: ran, skipped: skipped)
    }

    /// 赤の入力を、赤のまま保てる限り単純な値へ寄せる。
    ///
    /// 座標ごとに ``ProbeAxis/simplerValues(than:)`` の順 (単純な値から近づく順・丸め) に試し、赤のまま (`fail`)
    /// なら受け入れる。1 巡して何も動かなくなるか、`steps` 回呼んだら止める。`skip` は赤ではない —
    /// 約束の外へ縮めて「破れた」と名乗らないためである。
    static func shrink(
        _ input: ProbeInput, message: String, steps: Int, check: (ProbeInput) throws -> Outcome
    ) rethrows -> (ProbeInput, String) {
        var current = input
        var currentMessage = message
        var budget = steps
        var moved = true
        while moved, budget > 0 {
            moved = false
            for index in current.axes.indices {
                for candidate in current.axes[index].simplerValues(than: current.values[index]) {
                    guard budget > 0 else { return (current, currentMessage) }
                    budget -= 1
                    let trial = current.replacing(index, with: candidate)
                    if case .fail(let text) = try check(trial) {
                        current = trial
                        currentMessage = text
                        moved = true
                        break
                    }
                }
            }
        }
        return (current, currentMessage)
    }
}

/// 生成する入力の座標の 1 つ。
public nonisolated struct ProbeAxis: Sendable {
    /// 赤の文面で名乗る名前。
    public let name: String
    /// 生成する範囲 (下端を含み、上端を含まない)。
    public let range: Range<Double>
    /// 縮める先の、最も単純な値 (範囲の中に置く)。
    public let simplest: Double
    /// 値をこの刻みに丸める (`nil` なら連続)。刻みは下端から数える。
    public let step: Double?

    public init(_ name: String, _ range: Range<Double>, simplest: Double? = nil, step: Double? = nil) {
        precondition(!range.isEmpty, "\(name) の範囲が空")
        self.name = name
        self.range = range
        self.step = step
        self.simplest = Self.snap(simplest ?? range.lowerBound, range: range, step: step)
    }

    /// `0..<1` の一様な値から、この座標の値を作る。
    func value(at unit: Double) -> Double {
        Self.snap(range.lowerBound + unit * (range.upperBound - range.lowerBound), range: range, step: step)
    }

    /// `value` より単純な候補を、単純な順に並べる (`value` 自身と範囲の外は除く)。
    ///
    /// 最も単純な値から `value` へ向けて、残りの隔たりを半分ずつ詰めた点を並べる (二分探索の形)。
    /// 先頭から試して最初の赤を受け入れるので、1 手で境目の側へ大きく寄り、次の巡で残りを詰める。
    /// 最後に小数 1 桁・2 桁へ丸めた点を足し、名乗る値を読みやすくする。
    func simplerValues(than value: Double) -> [Double] {
        var out: [Double] = []
        let approach = [1.0, 0.5, 0.25, 0.125, 0.0625, 1.0 / 32, 1.0 / 64].map { value + (simplest - value) * $0 }
        for raw in approach + [(value * 10).rounded() / 10, (value * 100).rounded() / 100] {
            let candidate = Self.snap(raw, range: range, step: step)
            if candidate != value, range.contains(candidate), !out.contains(candidate) { out.append(candidate) }
        }
        return out
    }

    private static func snap(_ value: Double, range: Range<Double>, step: Double?) -> Double {
        guard let step else { return value }
        let snapped = range.lowerBound + ((value - range.lowerBound) / step).rounded() * step
        // 刻みに丸めて上端に届いたら、1 刻み戻す (上端は含まない)
        return snapped >= range.upperBound ? snapped - step : snapped
    }
}

/// 生成した入力 1 件。座標の名前で値を引く。
public nonisolated struct ProbeInput: Sendable, CustomStringConvertible {
    public let axes: [ProbeAxis]
    public let values: [Double]

    init(axes: [ProbeAxis], seed: UInt64) {
        var random = ProbeRandom(seed: seed)
        self.axes = axes
        self.values = axes.map { $0.value(at: random.nextUnit()) }
    }

    init(axes: [ProbeAxis], values: [Double]) {
        self.axes = axes
        self.values = values
    }

    /// 名前の座標の値。無い名前は検査の書き誤りなので落とす。
    public subscript(_ name: String) -> Double {
        guard let index = axes.firstIndex(where: { $0.name == name }) else {
            preconditionFailure("座標 \(name) は無い (\(axes.map(\.name)))")
        }
        return values[index]
    }

    /// `Float` で引く (描く口の多くが `Float` を受ける)。
    public func float(_ name: String) -> Float { Float(self[name]) }

    func replacing(_ index: Int, with value: Double) -> ProbeInput {
        var values = values
        values[index] = value
        return ProbeInput(axes: axes, values: values)
    }

    public var description: String {
        zip(axes, values).map { "\($0.name)=\(ProbeSeed.shortest($1))" }.joined(separator: " ")
    }
}

/// SplitMix64。seed から決まった列を出す (標準の乱数は seed を取れない)。
public nonisolated struct ProbeRandom: RandomNumberGenerator, Sendable {
    private var state: UInt64

    public init(seed: UInt64) { state = seed }

    public mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// `0..<1` の一様な値 (上位 53 bit から作る)。
    public mutating func nextUnit() -> Double { Double(next() >> 11) / Double(1 << 53) }
}

/// 実行ごとの seed の並べ方 (環境変数の読み方はここだけ)。
nonisolated struct ProbePlan {
    let base: UInt64
    let isFresh: Bool
    let seeds: [UInt64]

    init(key: String, cases: Int, environment: [String: String]) {
        isFresh = environment["MOKUME_PROBE_FRESH"] == "1"
        base = isFresh ? UInt64.random(in: .min ... .max) : ProbeSeed.hash(key)
        if let given = environment["MOKUME_PROBE_SEED"].flatMap(ProbeSeed.parse) {
            seeds = [given]
            return
        }
        let scale = environment["MOKUME_PROBE_SCALE"].flatMap { Int($0) }.map { max(1, $0) } ?? 1
        var random = ProbeRandom(seed: base)
        seeds = (0..<(cases * scale)).map { _ in random.next() }
    }
}

nonisolated enum ProbeSeed {
    /// FNV-1a (64 bit)。`String.hashValue` は実行ごとに変わるので使えない。
    static func hash(_ text: String) -> UInt64 {
        var value: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { value = (value ^ UInt64(byte)) &* 0x100_0000_01b3 }
        return value
    }

    static func format(_ seed: UInt64) -> String { "0x" + String(seed, radix: 16) }

    static func parse(_ text: String) -> UInt64? {
        let digits = text.hasPrefix("0x") ? String(text.dropFirst(2)) : text
        return UInt64(digits, radix: 16)
    }

    /// 読み返せる最短の表記 (赤の文面を短く保つ)。
    static func shortest(_ value: Double) -> String {
        for digits in 1...6 {
            let text = String(format: "%.\(digits)f", value)
            if abs(Double(text)! - value) < 1e-9 { return text }
        }
        return "\(value)"
    }
}
