// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit
import SwiftUI

/// 窓に重ねる、宣言した値のつまみ。
///
/// **入口はここ 1 つで、型ごとの名前に分けない** ([ADR-0030] 決定 8)。宣言側で型は
/// 決まっているのに呼び出し側で型別の名前を選ばせると、取り違えが実行時にしか出ない。
///
/// ## 窓は値を持たない
///
/// 各行が読むのは正典 (``ParamBox``) そのもので、写しを持たない ([ADR-0013] 決定 3)。
/// 持つと「変わったか」の判定が窓の中に生まれ、触っていないフレームでも「変わった」と
/// 言い続けることになる。書くのも**動かしたときだけ**である。
///
/// 更新は Observation の追跡で成立する ([ADR-0013] 決定 1) — 行の本体が値を読むこと
/// 自体が購読なので、登録も通知も書かない。
///
/// ## 絵には描かない
///
/// この面は SwiftUI の層に立ち、描画の成果物には一切描かない ([ADR-0030] 決定 1)。
/// 重ね方は ``KnobOverlay`` が持つ。
///
/// [ADR-0013]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0013-parameter-model.md
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
struct KnobPanel: View {
    /// 並べる値。並びは宣言した順 (基底の側から)。
    let boxes: [any DeclaredParam]
    /// いまの数字を読む口。**窓は読み手である** ([ADR-0030] 決定 7) — 自分では
    /// 数えず、観測の応答が返すのと同じ集計器を読む。
    ///
    /// **`nil` を返してよい。** 走っているのが別のプロセスのときは「まだ何も届いていない」
    /// 「もう届かなくなった」があり、そのとき数字を出せば嘘になる (``RemoteTempo``)。
    var numbers: (() -> FrameNumbers?)?

    /// 面の横幅。行の折り返しではなく窓の隅に収まる大きさで決める。
    static let width: CGFloat = 260

    var body: some View {
        // **窓より丈が高くなることがある。** 宣言の数は作品が決めるので、収まらない
        // ぶんは巻き取る — はみ出したまま置くと、下のつまみへ手が届かない
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if let numbers {
                    NumbersReadout(read: numbers)
                    // **並ぶものが無ければ仕切らない。** つまみを 1 つも宣言していない
                    // スケッチでも数字は出す (道具の窓に限る — ADR-0032 決定 1) ので、
                    // 何も無い側を仕切る線が残る
                    if !boxes.isEmpty { Divider() }
                }
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                    KnobRow(box: box)
                }
            }
            .padding(12)
            .frame(width: Self.width, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
        // 作品の描画設定は、この面の見え方を変えない (ADR-0030 決定 1)。SwiftUI の
        // 層は自分の色で描く — 混ぜ方も色の解釈も、絵の側の設定とは無関係である
        .controlSize(.small)
        .font(.system(size: 11))
    }
}

/// 走っている速さと時刻。
///
/// **自分の間隔で読み直す。** 数字はフレームごとに変わるが、フレームごとに引き直すと
/// つまみの面が毎フレーム組み直される。読むのは既に数えてある値だけなので、間隔を
/// 落としても数字そのものは正しい。
private struct NumbersReadout: View {
    let read: () -> FrameNumbers?

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.interval)) { _ in
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                ForEach(KnobText.numbers(read()), id: \.label) { cell in
                    VStack(alignment: .leading, spacing: 0) {
                        Text(cell.label)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        Text(cell.value)
                            .monospacedDigit()
                    }
                }
                Spacer(minLength: 0)
            }
        }
    }

    /// 読み直す間隔 (秒)。人が読める速さで足り、これより速くしても読めない。
    private static let interval: Double = 0.5
}

/// 宣言 1 つぶんの行。
private struct KnobRow: View {
    let box: any DeclaredParam

    var body: some View {
        // **ここで正典を読む。** 読むこと自体が購読なので、値が変われば行だけが引き直る
        let declaration = box.declaration
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(declaration.name)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(KnobText.value(of: declaration.value))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            control(for: declaration)
        }
    }

    @ViewBuilder
    private func control(for declaration: ParamDeclaration) -> some View {
        switch KnobKind.forDeclaration(declaration) {
        case .slider(let range):
            Slider(value: KnobBinding.number(box, declaration.value), in: range.lowerBound...range.upperBound)
        case .steppedSlider(let range):
            Slider(
                value: KnobBinding.number(box, declaration.value),
                in: range.lowerBound...range.upperBound, step: 1)
        case .toggle:
            Toggle("", isOn: KnobBinding.flag(box, declaration.value))
                .labelsHidden()
        case .color:
            ColorPicker("", selection: KnobBinding.color(box, declaration.value))
                .labelsHidden()
        case .components(let count, let range):
            VStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    Slider(
                        value: KnobBinding.component(box, declaration.value, at: index),
                        in: range.lowerBound...range.upperBound)
                }
            }
        case .choice(let choices):
            Picker("", selection: KnobBinding.text(box, declaration.value)) {
                ForEach(choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
        case .none(let reason):
            // つまみは出さないが、値と**次に何を書けばよいか**は出す。並びから消すと、
            // 書いたのに効かないのか出していないだけなのかが区別できない
            Text(reason.note)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 正典への結び

/// つまみと正典 (``ParamBox``) を結ぶ。
///
/// **写しを作らない。** `get` はそのつど正典を読み、`set` は正典へ書く。窓の側に値を
/// 置くと、外から書き換えられた値が窓に映らなくなるか、窓の値が毎フレーム書き戻される
/// かのどちらかになる。
///
/// 書き込みは面と同じ入口 (``DeclaredParam/write(_:)``) を通す — 収める規則を窓と面で
/// 2 通り持たない ([ADR-0030] 決定 3)。
///
/// **窓を通した往復の検査もここを通る** ([#517](https://github.com/mokume-metal/mokume/issues/517)
/// 出口条件 1)。``DeclaredParam/write(_:)`` を検査から直接呼ぶと「窓を通した」ことに
/// ならず、ここが写しを持ち始めても緑のままになるので、窓の外へ出してある
/// (同じ理由で ``KnobColor`` と ``KnobText`` も窓の外にある)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
enum KnobBinding {
    /// 数。整数の宣言には整数として書き戻す。
    static func number(_ box: any DeclaredParam, _ current: ParamValue) -> Binding<Double> {
        let isInteger = current.isInteger
        return Binding(
            get: { box.declaration.value.asDouble ?? 0 },
            set: { _ = box.write(isInteger ? .int(Int($0.rounded())) : .float($0)) })
    }

    static func flag(_ box: any DeclaredParam, _ current: ParamValue) -> Binding<Bool> {
        Binding(
            get: { if case .bool(let value) = box.declaration.value { value } else { false } },
            set: { _ = box.write(.bool($0)) })
    }

    static func text(_ box: any DeclaredParam, _ current: ParamValue) -> Binding<String> {
        Binding(
            get: { if case .string(let value) = box.declaration.value { value } else { "" } },
            set: { _ = box.write(.string($0)) })
    }

    /// 組の 1 成分。**他の成分は読み直した値をそのまま置く** — 窓が組を丸ごと持つと、
    /// 外から 1 成分だけ書き換えられたときに古い成分で上書きしてしまう。
    static func component(
        _ box: any DeclaredParam, _ current: ParamValue, at index: Int
    ) -> Binding<Double> {
        Binding(
            get: { Double(box.declaration.value.components?[safe: index] ?? 0) },
            set: { moved in
                guard var components = box.declaration.value.components, index < components.count
                else { return }
                components[index] = Float(moved)
                guard let value = ParamValue(components: components) else { return }
                _ = box.write(value)
            })
    }

    /// 色。**作業空間の値と画面の色の変換は境界の 1 箇所** ([ADR-0011] 決定 3・4) を通す。
    ///
    /// [ADR-0011]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0011-color-model.md
    static func color(_ box: any DeclaredParam, _ current: ParamValue) -> Binding<Color> {
        Binding(
            get: {
                guard case .color(let value) = box.declaration.value else { return .clear }
                return KnobColor.display(of: value)
            },
            set: { _ = box.write(.color(KnobColor.working(of: $0))) })
    }
}

/// 画面の色と作業空間の色を往復させる。
enum KnobColor {
    /// 作業空間の値を、画面で選ぶ色にする。
    ///
    /// 乗算を戻してから符号化する — 作業空間の成分はアルファ乗算済みなので、そのまま
    /// 符号化すると透明な色ほど暗く見える。
    static func display(of value: LinearRGBA) -> Color {
        let alpha = value.alpha
        guard alpha > 0 else { return Color(.displayP3, red: 0, green: 0, blue: 0, opacity: 0) }
        return Color(
            .displayP3,
            red: Double(TransferFunction.encode(value.red / alpha)),
            green: Double(TransferFunction.encode(value.green / alpha)),
            blue: Double(TransferFunction.encode(value.blue / alpha)),
            opacity: Double(alpha))
    }

    /// 画面で選んだ色を、作業空間の値にする。
    static func working(of color: Color) -> LinearRGBA {
        guard let components = NSColor(color).usingColorSpace(.displayP3) else {
            return .transparent
        }
        return .display(
            red: Float(components.redComponent), green: Float(components.greenComponent),
            blue: Float(components.blueComponent), alpha: Float(components.alphaComponent))
    }
}

// MARK: - 値の読み方

extension ParamValue {
    /// 整数として宣言された値か。
    fileprivate var isInteger: Bool {
        if case .int = self { return true }
        return false
    }

    /// 数として読む。数でなければ `nil`。
    fileprivate var asDouble: Double? {
        switch self {
        case .float(let value): value
        case .int(let value): Double(value)
        case .bool, .string, .color, .vector2, .vector3: nil
        }
    }

    /// 組の成分として読む。組でなければ `nil`。
    fileprivate var components: [Float]? {
        switch self {
        case .vector2(let value): [value.x, value.y]
        case .vector3(let value): [value.x, value.y, value.z]
        case .float, .int, .bool, .string, .color: nil
        }
    }

    /// 成分から組を組み立てる。成分の数が 2 でも 3 でもなければ `nil`。
    fileprivate init?(components: [Float]) {
        switch components.count {
        case 2: self = .vector2(SIMD2(components[0], components[1]))
        case 3: self = .vector3(SIMD3(components[0], components[1], components[2]))
        default: return nil
        }
    }
}

extension Array {
    fileprivate subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

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
        case .color(let color):
            "#" + [color.red, color.green, color.blue]
                .map { String(format: "%02X", Int((min(max($0, 0), 1) * 255).rounded())) }
                .joined()
        case .vector2(let vector): Self.pair(vector.x, vector.y)
        case .vector3(let vector): Self.pair(vector.x, vector.y, vector.z)
        }
    }

    private static func pair(_ numbers: Float...) -> String {
        numbers.map { $0.formatted(.number.precision(.fractionLength(2))) }.joined(separator: ", ")
    }
}
