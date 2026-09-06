// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// つまみの脇と数字の欄に出す表記。
enum KnobText {
    /// 測れていないことの表し方。**0 と書かない** ([ADR-0030] 決定 7) — 測れた 0 と
    /// 区別が付かなくなる。綴りをここ 1 つに持ち、窓の中で表明の形を揃える。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    static let notMeasured = "—"

    /// 測れた数を書く。**測れていなければ ``notMeasured``。**
    static func measurement(_ value: Double?, fractionDigits: Int = 1) -> String {
        guard let value else { return notMeasured }
        return value.formatted(.number.precision(.fractionLength(fractionDigits)))
    }

    /// 数字の欄に並ぶもの。**組み立ては純関数**にして、窓を立てずに検められるようにする。
    ///
    /// 進めた枚数と時刻は常に測れている (どちらも数え上げなので)。速さとフレーム時間は
    /// 起動直後と止めている間は測れていないので、**同じ 1 つの綴り**で欠測を表す。
    ///
    /// **数字そのものが届いていないこともある。** 走っているのが別のプロセスのときは、
    /// まだ 1 枚も来ていない・もう来なくなった、が起きる (``RemoteTempo``)。そのときは
    /// 枚数と時刻まで欠測なので、**4 つとも同じ綴りで出す** — 進んでいない相手の枚数を
    /// 0 と書けば、「1 枚目を描いたところ」と区別が付かなくなる。
    static func numbers(_ numbers: FrameNumbers?) -> [(label: String, value: String)] {
        guard let numbers else {
            return ["fps", "ms", "frame", "t"].map { (label: $0, value: notMeasured) }
        }
        return [
            ("fps", measurement(numbers.frameRate)),
            ("ms", measurement(numbers.frameTimeMs)),
            ("frame", String(numbers.frameCount)),
            ("t", measurement(numbers.time, fractionDigits: 2)),
        ]
    }

    /// 値を 1 行で。**桁を揃える** — 引いている最中に幅が伸び縮みすると読みにくい。
    static func value(of value: ParamValue) -> String {
        switch value {
        case .float(let number): number.formatted(.number.precision(.fractionLength(2)))
        case .int(let number): String(number)
        case .bool(let flag): flag ? "true" : "false"
        case .string(let text): text
        case .color(let value):
            // 出口の境界を通してから綴る ([ADR-0011] 決定 3)。作業空間の成分は線形で
            // アルファを乗算済みなので、そのまま 255 倍すると転送関数のぶんだけずれ、
            // **窓の綴りをコードへ写すと別の色になる** (#746)
            "#" + [red(value), green(value), blue(value)]
                .map { String(format: "%02X", Int(min(max($0, 0), 255).rounded())) }
                .joined()
        case .vector2(let vector): Self.pair(vector.x, vector.y)
        case .vector3(let vector): Self.pair(vector.x, vector.y, vector.z)
        }
    }

    private static func pair(_ numbers: Float...) -> String {
        numbers.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: ", ")
    }
}
