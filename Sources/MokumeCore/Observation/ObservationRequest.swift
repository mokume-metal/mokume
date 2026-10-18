// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から置かれる観測の要求。
///
/// 形の正典は `Schemas/observe-request.schema.json`。**知らない鍵は読まず、要求は失敗させない**
/// ([ADR-0018] 決定 3) ので、書き手が新しい鍵を足しても古い実装は壊れない。ただし黙って捨てず、
/// 応答の `warnings` で名乗る (``unknownKeysWarning``・[#2392])。
///
/// **省略できる欄 (`scale`・`count`・`every`・`time`) の `null` は、省略と同じに読む** ([#2392])。
/// `time: null` は「時刻なし」で、断らない。型の違う値 (`"5"`・`true`) は省略として通さない。
///
/// ## 同じ時刻で比較する
///
/// `time: 3` を指定すると、3秒目を1枚描き直して撮る。色を編集して保存した後も、
/// 新しいidで同じ秒を指定すれば同じ構図で比べられる。秒はFloatに丸める。
/// **画面とdrawの副作用は残る。** deltaTimeは0、frameCountは1進み、次は元の時計へ戻る。
/// 状態の巻き戻しではなく、時刻と他の入力から絵が決まる作品向けである。
/// noLoopは停止を保つ。外部pause、録画中、count/everyが1以外なら理由を返す。
/// 指定フレーム内でのbeginRecordも断る。通常観測はtimeを省く。
/// 応答にappliedTimeがあり、目録と同じ秒かを必ず確認する。旧版はtimeを無視することがある。
///
/// ## 間隔はフレーム数で数える
///
/// ``every`` は秒ではなくフレームで数える。秒で指定しても結局はフレームへ丸めることに
/// なるためで、数えるのは**実際に描けたフレーム**である。
///
/// **撮れた枚の時刻の間隔は揃わない。** 観測を受けるのは `mokume run` / `watch` が
/// 走らせているスケッチで、その入口は実時計を渡す (`SketchApplication` が
/// ``Clock/wallClock`` で組む) — 撮っている間は絵の書き出しでフレームが重くなるので、
/// 間隔は描けた速さのぶんだけ伸び縮みする。**並べるには応答の目録 (`frames`) の各行の
/// `time` を読む**。枚数のまま並べると、黙って速さの狂った動きができる ([#1285])。
///
/// 時計をフレーム番号から導く経路 (``SketchRuntime`` を直接組む検査・ヘッドレス) では
/// 間隔も揃い、同じスケッチを 2 回走らせれば同じ列が返る。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
/// [#1285]: https://github.com/mokume-metal/mokume/issues/1285
/// [#2392]: https://github.com/mokume-metal/mokume/issues/2392
public struct ObservationRequest: ExchangeRequest, Equatable, Sendable {
    /// 撮れる枚数の上限。60fps で 2 秒ぶん。
    ///
    /// 撮った絵は 1 枚ずつ区画へ書き出されるので、際限なく頼めるとディスクが埋まる。
    /// 動きが正しいかを見るには十分な長さで切る。
    public static let maximumCount = 120
    /// 間隔の上限 (フレーム)。60fps で 1 秒に 1 枚。
    ///
    /// 間隔が長いほど列が返るまでの待ちが伸びる。読み手の待ちが尽きると、応答は
    /// 後から書かれるのに読み手だけが諦めた状態になる。
    public static let maximumEvery = 60
    /// 撮れる枚数の下限。0 枚の列は撮り終わりが来ない。
    ///
    /// `package` に開くのは、MCP の窓口が範囲を名乗るときに手で書かず、ここから引くため
    /// (上限の定数と同じく、写した数は動かした日に古びる)。
    package static let minimumCount = 1
    /// 間隔の下限 (フレーム)。毎フレーム撮るより詰めることはできない。
    package static let minimumEvery = 1
    /// 縮小率の上限 (実寸)。拡大はしない。下は 0 を含まない (0 以下は実寸に倒す)。
    static let maximumScale: Double = 1

    /// この要求の識別子。応答はこれを echo する。
    public let id: String
    /// 書き出す画像の縮小率 (1 = 実寸)。
    public let scale: Double
    /// 撮る枚数。
    public let count: Int
    /// 何フレームおきに撮るか。
    public let every: Int
    /// 指定した秒で1枚描き直す。省略時は直近の絵を読むだけ。
    /// `deltaTime` は0、番号は1進む。画面と `draw()` の副作用は残り、巻き戻しではない。
    public let time: Double?
    /// 要求にあった、この版が読まない鍵 (名前順)。
    package let unknownKeys: [String]

    /// JSON の数として読めても、時刻として使えない要求は応答で断る。
    var timeWarning: String? {
        guard let time else { return nil }
        guard time.isFinite, time >= 0, time <= Double(Float.greatestFiniteMagnitude) else {
            return "time must be finite, non-negative seconds within the Float range"
        }
        guard count == 1, every == 1 else {
            return "A specified time requires count=1 and every=1"
        }
        return nil
    }

    public init(id: String, scale: Double = 1, count: Int = 1, every: Int = 1, time: Double? = nil) {
        self.id = id
        self.scale = scale
        self.count = count
        self.every = every
        self.time = time
        self.unknownKeys = []
    }

    /// 範囲の端で丸めた縮小率・枚数・間隔、そして丸めたことを伝えることわり。
    ///
    /// **黙って切り詰めない。** 頼んだ枚数と返った枚数が違うことに応答から気付けないと、
    /// 読み手は「動きが途中で止まった」と「範囲の端で切られた」を区別できない。縮小率も
    /// 同じで、範囲の外を黙って実寸に倒すと、読み手は頼んだ大きさの絵だと信じる ([#1814])。
    /// ことわりは**切った端を名乗る** — 上で切れば上限を、下 (0・負) で切れば下限を言う。
    /// どちらの端でも上限を名乗っていたので、読み手は切られた理由を取り違えた ([#1699])。
    ///
    /// 切るのは要求を解いた後の別の段にしてある — 要求そのものは書き手が置いたままの
    /// 値を保ち、応答の `id` と並べて「何を頼み、何が返ったか」を突き合わせられる。
    /// **頼みの範囲を見るのはここ 1 か所である。** 撮る側 (`SketchRuntime`) は丸めた値
    /// だけを使う。MCP の窓口も、待つ長さを見積もるのにこれを呼び、範囲を写さない
    /// (`package` に開くのはそのため。[#2045])。
    ///
    /// [#1699]: https://github.com/mokume-metal/mokume/issues/1699
    /// [#1814]: https://github.com/mokume-metal/mokume/issues/1814
    /// [#2045]: https://github.com/mokume-metal/mokume/issues/2045
    package func clamped() -> (scale: Double, count: Int, every: Int, warnings: [String]) {
        var warnings: [String] = []
        if let unknownKeysWarning { warnings.append(unknownKeysWarning) }
        let scale = Self.clampScale(self.scale)
        if let reason = scale.reason {
            warnings.append("The scale went from \(self.scale) to \(scale.value) (\(reason))")
        }
        let count = Self.clamp(self.count, into: Self.minimumCount...Self.maximumCount)
        if let bound = count.bound {
            warnings.append(
                "The number of shots went from \(self.count) to \(count.value) (\(bound))")
        }
        let every = Self.clamp(self.every, into: Self.minimumEvery...Self.maximumEvery)
        if let bound = every.bound {
            warnings.append(
                "The interval went from \(self.every) to \(every.value) frames (\(bound))")
        }
        return (scale.value, count.value, every.value, warnings)
    }

    /// 範囲へ丸めた値と、丸めたなら切った端を名乗る括弧の中身。範囲の中なら `nil`。
    private static func clamp(_ value: Int, into range: ClosedRange<Int>)
        -> (value: Int, bound: String?)
    {
        if value > range.upperBound { return (range.upperBound, "the ceiling is \(range.upperBound)") }
        if value < range.lowerBound { return (range.lowerBound, "the floor is \(range.lowerBound)") }
        return (value, nil)
    }

    /// 範囲 `(0, 1]` へ丸めた縮小率と、丸めたならその理由。範囲の中なら `nil`。
    ///
    /// **下の外は下限へ寄せず、実寸に倒す。** 0 を含まない範囲には寄せる先の端が無く、
    /// 限りなく小さい絵を返すより、実寸を返して倒したことを言うほうが読み手に役立つ。
    /// 数でない値 (公開の `init` からは置ける) も同じ扱いにする。
    private static func clampScale(_ value: Double) -> (value: Double, reason: String?) {
        if value > maximumScale { return (maximumScale, "the ceiling is \(maximumScale)") }
        guard value > 0 else {
            return (maximumScale, "a scale must be above 0, so full size was used")
        }
        return (value, nil)
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, scale, count, every, time
    }

    /// 整数の鍵を読む。**範囲を越えた大きな数は、符号の側の端へ寄せる** (#2805)。
    ///
    /// `1e19` も 30 桁の整数も `Int.max` も「上限より大きい」ことに変わりはなく、読み終えた後の
    /// ``clamped()`` が範囲へ丸めて警告で名乗る (スキーマの約束。MCP の窓口 `Tools.seriesArgument` が
    /// 同じ値を同じ端へ寄せるのと揃える)。読めない要求にして鍵と理由を名乗るのは、`2.5` のような
    /// **整数でない数**だけである。理由に数の字面は写さない — 桁が多いほど応答の 1 行が伸びてしまう。
    private nonisolated static func integer(
        in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Int? {
        switch try container.decodeWireNumber(Int.self, forKey: key) {
        case .absent: return nil
        case .value(let value): return value
        case .overflow(let negative): return negative ? Int.min : Int.max
        case .notWhole:
            throw DecodingError.typeMismatch(
                Int.self,
                DecodingError.Context(
                    codingPath: [key], debugDescription: "The value is not a whole number"))
        }
    }

    /// 縮小率の鍵を読む。`Double` に収まらない大きな数 (`1e400`) は、符号の側の無限大として読み、
    /// 丸める段が実寸に倒して名乗る。
    private nonisolated static func scale(
        in container: KeyedDecodingContainer<CodingKeys>, forKey key: CodingKeys
    ) throws -> Double? {
        switch try container.decodeWireNumber(Double.self, forKey: key) {
        case .absent: return nil
        case .value(let value): return value
        case .overflow(let negative): return negative ? -.infinity : .infinity
        case .notWhole:
            throw DecodingError.typeMismatch(
                Double.self,
                DecodingError.Context(
                    codingPath: [key], debugDescription: "The value is not a number that fits in Double"))
        }
    }

    /// 要求にあった、読まない鍵 (名前順)。
    ///
    /// **断らず、読まないだけにする** ([ADR-0018] 決定 3「知らないキーは無視する」。新しい書き手が足した
    /// キーを古いスケッチが断らない)。ただし黙って捨てない — `sacle` のような綴りの誤りが、警告なしの
    /// 等倍になる ([#2392])。名乗りは ``unknownKeysWarning`` が応答の `warnings` に載せる。
    private nonisolated static func unknownKeys(in decoder: any Decoder) throws -> [String] {
        let all = try decoder.container(keyedBy: AnyKey.self)
        return all.allKeys.map(\.stringValue)
            .filter { CodingKeys(rawValue: $0) == nil }
            .sorted()
    }

    private struct AnyKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    /// 名乗る名前の数と、1 つあたりの長さの上限。書き手が置いた長さのまま応答へ返さない。
    private nonisolated static let namedKeyLimit = 5
    private nonisolated static let namedKeyLength = 32

    /// 名乗る名前を、上限で切って並べる。
    private nonisolated static func named(_ keys: [String]) -> String {
        let shown = keys.prefix(namedKeyLimit).map { key in
            key.count > namedKeyLength ? "\(key.prefix(namedKeyLength))…" : key
        }
        let rest = keys.count - shown.count
        return shown.joined(separator: ", ") + (rest > 0 ? " and \(rest) more" : "")
    }

    /// 読まなかった鍵を名乗る警告。なければ `nil`。
    var unknownKeysWarning: String? {
        guard !unknownKeys.isEmpty else { return nil }
        let known = CodingKeys.allCases.map(\.rawValue).joined(separator: ", ")
        return "Not read, so the request was taken without them: \(Self.named(unknownKeys)) (the keys read are \(known))"
    }

    /// 読めなかった理由に、知らない鍵の名乗りを添える。**読めない要求の応答にも名乗る** (#2392) —
    /// 型の誤りを直した次の応答で初めて `sacle` が出る、という 2 度手間にしない。場所と元の説明は保つ。
    private nonisolated static func annotated(_ error: DecodingError, naming keys: [String]) -> DecodingError {
        guard !keys.isEmpty else { return error }
        func context(_ context: DecodingError.Context) -> DecodingError.Context {
            .init(
                codingPath: context.codingPath,
                debugDescription: "\(context.debugDescription); keys not read: \(named(keys))",
                underlyingError: context.underlyingError)
        }
        switch error {
        case .typeMismatch(let type, let inner): return .typeMismatch(type, context(inner))
        case .valueNotFound(let type, let inner): return .valueNotFound(type, context(inner))
        case .keyNotFound(let key, let inner): return .keyNotFound(key, context(inner))
        case .dataCorrupted(let inner): return .dataCorrupted(context(inner))
        @unknown default: return error
        }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let unknownKeys = try Self.unknownKeys(in: decoder)
        do {
            self.id = try container.decode(String.self, forKey: .id)
            self.scale = try Self.scale(in: container, forKey: .scale) ?? 1
            self.count = try Self.integer(in: container, forKey: .count) ?? 1
            self.every = try Self.integer(in: container, forKey: .every) ?? 1
        } catch let error as DecodingError {
            throw Self.annotated(error, naming: unknownKeys)
        }
        // **`null` は省略と同じ「時刻なし」** (#2392)。窓口の側は #2393 で揃える。型が違う値は、
        // 「時刻なし」として成功させない。NaNは内部の拒否用で応答には書かない。
        let timeIsGiven = try container.contains(.time) && !container.decodeNil(forKey: .time)
        self.time = timeIsGiven ? (try? container.decode(Double.self, forKey: .time)) ?? .nan : nil
        self.unknownKeys = unknownKeys
    }
}
