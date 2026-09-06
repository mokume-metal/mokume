// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

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
            Toggle("", isOn: KnobBinding.flag(box))
                .labelsHidden()
        case .color:
            ColorPicker("", selection: KnobBinding.color(box))
                .labelsHidden()
        case .components(let count, let range):
            VStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    Slider(
                        value: KnobBinding.component(box, at: index),
                        in: range.lowerBound...range.upperBound)
                }
            }
        case .choice(let choices):
            Picker("", selection: KnobBinding.text(box)) {
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
