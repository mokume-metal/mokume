// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import mokume

/// つまみの面の応答 (`.mokume/params/report.json`) を、スマホのページへ配る形にする。
///
/// **どのつまみを出すかは、窓と同じ 1 か所の対応表 (`KnobKind.forDeclaration`) で決める**
/// (ADR-0030 決定 8)。ページの JS は渡された種類どおりに並べるだけで、対応表を持たない —
/// 持たせると、窓とスマホで同じ宣言が違うつまみになりうる。
nonisolated enum RemoteKnobs {
    /// スケッチの様子。ページはこれでつまみを触れるかを決める。
    enum State: String, Encodable, Sendable {
        /// 応答を読めていて、子が走っている。
        case running
        /// `watch` が作り直している。つまみは触れない。
        case rebuilding
        /// まだ応答が無い (子が起きる前)。
        case waiting
    }

    /// ページへ配る 1 件。
    struct Payload: Encodable, Equatable, Sendable {
        var state: State
        /// 応答の改訂番号。読めていなければ `nil`。
        var revision: Int?
        /// 応答が echo した要求の識別子。ページは、これが変わったときだけ `clamped` と `rejected` を出す。
        var id: String?
        var knobs: [Knob]
        /// 読めずに飛ばした宣言の 1 行ずつ。
        var skipped: [String]
        /// 範囲へ収めた書き込み (`"size"`)。
        var clamped: [String]
        /// 断られた書き込み (`"size: unknownName"`)。
        var rejected: [String]

        static func waiting(_ state: State = .waiting) -> Payload {
            Payload(state: state, revision: nil, id: nil, knobs: [], skipped: [], clamped: [], rejected: [])
        }
    }

    /// つまみ 1 つ。
    struct Knob: Encodable, Equatable, Sendable {
        let name: String
        /// 面の型の名前 (`float`・`color` など)。書き戻すときにそのまま付ける。
        let type: String
        /// 並べ方: `slider`・`steppedSlider`・`toggle`・`color`・`components`・`choice`・`none`。
        let kind: String
        let value: WireValue
        var min: Double?
        var max: Double?
        var step: Double?
        /// `components` の成分の数。
        var count: Int?
        var choices: [String]?
        /// `none` の理由 (窓に添えるのと同じ 1 行)。
        var note: String?
    }

    /// ページへ渡す値。色は欄に出す `#rrggbb` と不透明度に分ける。
    enum WireValue: Encodable, Equatable, Sendable {
        case number(Double)
        case bool(Bool)
        case string(String)
        case components([Double])
        case color(hex: String, alpha: Double)

        func encode(to encoder: any Encoder) throws {
            switch self {
            case .number(let number):
                var container = encoder.singleValueContainer()
                // 非有限の数は JSON に書けない。宣言が非有限なら面に出ないので、ここに来るのは値だけ
                try container.encode(number.isFinite ? number : 0)
            case .bool(let flag):
                var container = encoder.singleValueContainer()
                try container.encode(flag)
            case .string(let text):
                var container = encoder.singleValueContainer()
                try container.encode(text)
            case .components(let numbers):
                var container = encoder.singleValueContainer()
                try container.encode(numbers.map { $0.isFinite ? $0 : 0 })
            case .color(let hex, let alpha):
                var container = encoder.container(keyedBy: ColorKeys.self)
                try container.encode(hex, forKey: .hex)
                try container.encode(alpha.isFinite ? alpha : 1, forKey: .alpha)
            }
        }

        private enum ColorKeys: String, CodingKey { case hex, alpha }

        init(_ value: ParamValue) {
            switch value {
            case .float(let number): self = .number(number)
            case .int(let number): self = .number(Double(number))
            case .bool(let flag): self = .bool(flag)
            case .string(let text): self = .string(text)
            case .color(let color): self = .color(hex: RemoteColor.hex(of: color), alpha: Double(color.alpha))
            case .vector2(let vector): self = .components([Double(vector.x), Double(vector.y)])
            case .vector3(let vector): self = .components([Double(vector.x), Double(vector.y), Double(vector.z)])
            }
        }
    }

    /// 面の応答のうち、ページに要るところ。**宣言は 1 件ずつ緩く読む** — 窓と同じ読み方
    /// (`RemoteParams.Reading`) で、1 件が読めないだけで全部のつまみが消えないようにする。
    struct Report: Decodable {
        let revision: Int?
        let id: String?
        let params: [RemoteParams.Reading]
        let clamped: [String]
        let rejected: [String]

        private enum CodingKeys: String, CodingKey { case revision, id, params, clamped, rejected }
        private struct Named: Decodable { let name: String }
        private struct Refused: Decodable {
            let name: String
            let reason: String
        }

        init(from decoder: any Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            revision = try? container.decode(Int.self, forKey: .revision)
            id = try? container.decode(String.self, forKey: .id)
            params = try container.decode([RemoteParams.Reading].self, forKey: .params)
            clamped = ((try? container.decode([Named].self, forKey: .clamped)) ?? []).map(\.name)
            rejected = ((try? container.decode([Refused].self, forKey: .rejected)) ?? []).map {
                "\($0.name): \($0.reason)"
            }
        }
    }

    /// 応答を読んで、配る形にする。外枠が読めなければ `nil` (前の状態を保つのは呼ぶ側)。
    static func payload(from data: Data, state: State = .running) -> Payload? {
        guard let report = try? JSONDecoder().decode(Report.self, from: data) else { return nil }
        var knobs: [Knob] = []
        var skipped: [String] = []
        for (index, reading) in report.params.enumerated() {
            switch reading {
            case .declaration(let declaration):
                knobs.append(knob(for: declaration))
            case .unreadable(let name, let reason):
                skipped.append("\(name ?? "entry \(index)"): \(reason)")
            }
        }
        return Payload(
            state: state, revision: report.revision, id: report.id, knobs: knobs, skipped: skipped,
            clamped: report.clamped, rejected: report.rejected)
    }

    /// 宣言 1 件を、つまみ 1 つにする。
    static func knob(for declaration: ParamDeclaration) -> Knob {
        let value = WireValue(declaration.value)
        var knob = Knob(name: declaration.name, type: declaration.typeName, kind: "none", value: value)
        switch KnobKind.forDeclaration(declaration) {
        case .slider(let range, let step):
            knob = Knob(name: knob.name, type: knob.type, kind: "slider", value: value)
            knob.min = range.lowerBound
            knob.max = range.upperBound
            knob.step = step
        case .steppedSlider(let range):
            knob = Knob(name: knob.name, type: knob.type, kind: "steppedSlider", value: value)
            knob.min = range.lowerBound
            knob.max = range.upperBound
            knob.step = 1
        case .toggle:
            knob = Knob(name: knob.name, type: knob.type, kind: "toggle", value: value)
        case .color:
            knob = Knob(name: knob.name, type: knob.type, kind: "color", value: value)
        case .components(let count, let range, let step):
            knob = Knob(name: knob.name, type: knob.type, kind: "components", value: value)
            knob.count = count
            knob.min = range.lowerBound
            knob.max = range.upperBound
            knob.step = step
        case .choice(let choices):
            knob = Knob(name: knob.name, type: knob.type, kind: "choice", value: value)
            knob.choices = choices
        case .none(let reason):
            knob.note = reason.note
        }
        return knob
    }
}
