// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から置かれた JSON の数を、型に読んだ結果。
///
/// **型に収まらない数の読み方を、要求の読み手が 1 つの手掛かりで共有する** (#2805)。`JSONDecoder` は
/// 数を型へ読む瞬間に、収まらない数 (`Int` に対する `2.5`・`1e19`、`Double` に対する `1e400`) を
/// `DecodingError` でない内部の誤りで断る。そのまま外へ出ると場所の空の「JSON でない」になり、構文の
/// 誤りと取り違えられる。入れ子の読みの中でも同じ誤りが漏れ出るので、「`DecodingError` でなければ
/// 数が収まらなかった」と読み分ける (``DecodingError/isNumberOverflow(_:)``)。
nonisolated enum WireNumber<Value> {
    /// 鍵が無い・`null` (省略と同じ)。
    case absent
    case value(Value)
    /// 整数 (有限の `Double` にも) 収まらないほど大きな数。`negative` は符号。範囲の外の値であって、
    /// 型の誤りではない — 範囲の丸めは読んだ後の段が決める。
    case overflow(negative: Bool)
    /// 整数に読む鍵に、整数でない数 (`2.5`) が来た。
    case notWhole

    /// 数の字面から、収まらなかった数の姿を読む。字面は応答に写さず、ここで符号と整数かだけを取る。
    ///
    /// Foundation の誤りは `numberIsNotRepresentableInSwift(parsed: "2.5")` と数の字面を持つ。読めない
    /// (形が変わった) ときは `nil` で、呼び手は整数でない数と同じに断る。
    fileprivate static func shape(of error: any Error) -> (negative: Bool, isWhole: Bool)? {
        let text = String(describing: error)
        guard let open = text.range(of: "parsed: \""),
            let close = text[open.upperBound...].firstIndex(of: "\""),
            let number = Double(text[open.upperBound..<close])
        else { return nil }
        // 無限大 (`1e400`) も、整数に収まらない大きな数として、符号だけ見る
        let isWhole = !number.isFinite || number == number.rounded()
        return (number < 0, isWhole)
    }
}

extension KeyedDecodingContainer {
    /// 鍵の数を読む。**収まらない数は誤りにせず、姿を返す** (``WireNumber``)。
    ///
    /// 型の違う値 (`"0.5"`・`true`) は、場所つきの `DecodingError` のまま投げる。
    nonisolated func decodeWireNumber<Number: Decodable>(
        _ type: Number.Type, forKey key: Key
    ) throws -> WireNumber<Number> {
        do {
            guard let value = try decodeIfPresent(type, forKey: key) else { return .absent }
            return .value(value)
        } catch {
            // 型の違う値 (場所つきの `DecodingError`) は、そのまま投げる
            guard DecodingError.isNumberOverflow(error) else { throw error }
            guard let shape = WireNumber<Number>.shape(of: error), shape.isWhole else {
                return .notWhole
            }
            return .overflow(negative: shape.negative)
        }
    }
}

extension WireNumber: Equatable where Value: Equatable {}

extension DecodingError {
    /// 値の読み取りの誤りが、**数が型に収まらなかったこと**か。
    ///
    /// 型の違う値・欠け・成分の数の違いは、どれも `DecodingError` で届く。それ以外が出たら、数が型に
    /// 収まらなかったと読む (`ParameterUnreadableEntryTests`・`WireNumberTests` が固定する)。
    nonisolated static func isNumberOverflow(_ error: any Error) -> Bool {
        !(error is DecodingError)
    }
}
