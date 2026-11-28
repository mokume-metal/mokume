// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import SwiftUI

/// 警告の欄に出す値の置き場 ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。
///
/// 欄は数字の下に出入りして**面の丈を変える**ので、値は読み手が引くのではなく重ねる側 (``KnobOverlay``) が
/// 押し込む — 押し込んだ側が、丈を測り直して枠を置き直せる (``KnobOverlay/show(warnings:)``)。数字のように
/// 一定の間隔で引き直す形では、欄が伸びても枠が伸びない。
@MainActor
@Observable
final class WarningFeed {
    var summary: WarningSummary?
}

/// 面を畳んでいるか (#4137)。
///
/// **面の外に持つ。** 道具のウィンドウは宣言の顔ぶれが変わるたびに面を作り直すので、面が自分で持つと、
/// 保存のたびに畳んだ面が開き直る。持ち回るのは作る側 (``SharedFramePreview``) である。
@MainActor
@Observable
final class KnobPanelState {
    var isCollapsed = false
}

/// つまみの面の背景 (#4221)。
///
/// 面は `watch` のプレビューと `run` の作品のウィンドウで共有するので、どちらを使うかは面を重ねる側が選ぶ。
enum KnobPanelBackdrop: Equatable, Sendable {
    /// SwiftUI の `.regularMaterial`。作品の上に重ねる `run` の面。
    case material
    /// システムの Liquid Glass (`glassEffect`・`.buttonStyle(.glass)`)。`watch` の列の面。
    case glass
}

/// ウィンドウに重ねる、宣言した値のつまみ。
///
/// **入口はここ 1 つで、型ごとの名前に分けない** ([ADR-0030] 決定 8)。宣言側で型は
/// 決まっているのに呼び出し側で型別の名前を選ばせると、取り違えが実行時にしか出ない。
///
/// ## ウィンドウは値を持たない
///
/// 各行が読むのは正典 (``ParamBox``) そのもので、写しを持たない ([ADR-0013] 決定 3)。
/// 持つと「変わったか」の判定がウィンドウの中に生まれ、触っていないフレームでも「変わった」と
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
    /// いまの数字を読む口。**ウィンドウは読み手である** ([ADR-0030] 決定 7) — 自分では
    /// 数えず、観測の応答が返すのと同じ集計器を読む。
    ///
    /// **`nil` を返してよい。** 走っているのが別のプロセスのときは「まだ何も届いていない」
    /// 「もう届かなくなった」があり、そのとき数字を出せば嘘になる (``RemoteTempo``)。
    var numbers: (() -> FrameNumbers?)?
    /// 走らせているスケッチが言った警告の置き場 (#3087)。**無いか、1 つも言っていなければ欄ごと出さない。**
    /// 数字と違い、古くなっても消えない (``WarningSummary``)。
    var warnings: WarningFeed?
    /// 畳んでいるか (#4137)。`nil` なら畳めない面として描く。
    var state: KnobPanelState?
    /// 手の操作を積む履歴 (#4124)。`nil` なら積まない。
    var history: KnobHistory?
    /// 畳む・開くボタンが押されたとき。**値を替えるのは受け取った側** — 替えた後に枠の大きさを測り直す
    /// 必要があり、それは面を重ねる側 (``KnobOverlay``) にしかできない。
    var toggle: (() -> Void)?
    /// 背景 (#4221)。
    var backdrop: KnobPanelBackdrop = .material

    /// 面の横幅。行の折り返しではなくウィンドウの隅に収まる大きさで決める。
    static let width: CGFloat = 260
    /// 畳んだ面の一辺。開くボタン 1 つだけが収まる大きさ。
    static let collapsedSide: CGFloat = 28

    var body: some View {
        if state?.isCollapsed == true {
            collapsed
        } else {
            expanded
        }
    }

    /// 畳んだ面: 開くボタンだけ。**絵を隠す範囲をこの大きさまで減らす**のが畳む目的である。
    @ViewBuilder
    private var collapsed: some View {
        switch backdrop {
        case .material:
            toggleButton(systemImage: "slider.horizontal.3", help: "Show the knobs")
                .buttonStyle(.plain)
                .frame(width: Self.collapsedSide, height: Self.collapsedSide)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
                .controlSize(.small)
        case .glass:
            // ボタンそのものがガラスの面になる。手書きの背景を重ねると、ガラスの下に別の面が透ける
            toggleButton(systemImage: "slider.horizontal.3", help: "Show the knobs")
                .buttonStyle(.glass)
                .buttonBorderShape(.roundedRectangle(radius: 8))
                .frame(width: Self.collapsedSide, height: Self.collapsedSide)
                .controlSize(.small)
        }
    }

    private var expanded: some View {
        // **ウィンドウより丈が高くなることがある。** 宣言の数は作品が決めるので、収まらない
        // ぶんは巻き取る — はみ出したまま置くと、下のつまみへ手が届かない
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 10) {
                if toggle != nil {
                    HStack {
                        Spacer(minLength: 0)
                        toggleButton(systemImage: "sidebar.left", help: "Hide the knobs")
                            .buttonStyle(.plain)
                    }
                }
                if let numbers {
                    NumbersReadout(read: numbers, warnings: warnings)
                    // **並ぶものが無ければ仕切らない。** つまみを 1 つも宣言していない
                    // スケッチでも数字は出す (道具のウィンドウに限る — ADR-0032 決定 1) ので、
                    // 何も無い側を仕切る線が残る
                    if !boxes.isEmpty { Divider() }
                }
                ForEach(Array(boxes.enumerated()), id: \.offset) { _, box in
                    KnobRow(box: box, history: history)
                }
            }
            .padding(12)
            .frame(width: Self.width, alignment: .leading)
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(width: Self.width)
        .modifier(PanelBackdrop(kind: backdrop, shape: RoundedRectangle(cornerRadius: 10)))
        // 作品の描画設定は、この面の見え方を変えない (ADR-0030 決定 1)。SwiftUI の
        // 層は自分の色で描く — 混ぜ方も色の解釈も、絵の側の設定とは無関係である
        .controlSize(.small)
        .font(.system(size: 11))
    }

    /// 畳む・開くボタン。**キーは割り当てない** — これらのウィンドウにはメニューが無く、⌘ を含むキーも
    /// スケッチへ届く入力なので、どのキーもスケッチのキーと取り合う (#4137)。
    private func toggleButton(systemImage: String, help: String) -> some View {
        Button(action: { toggle?() }) {
            Image(systemName: systemImage)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .foregroundStyle(.secondary)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// 開いた面の背景。ガラスは面全体に 1 枚だけ当てる — 行ごとに当てると、ガラスの上にガラスが重なる。
private struct PanelBackdrop: ViewModifier {
    let kind: KnobPanelBackdrop
    let shape: RoundedRectangle

    func body(content: Content) -> some View {
        switch kind {
        case .material: content.background(.regularMaterial, in: shape)
        case .glass: content.glassEffect(.regular, in: shape)
        }
    }
}

/// 走っている速さと時刻。
///
/// **自分の間隔で読み直す。** 数字はフレームごとに変わるが、フレームごとに引き直すと
/// つまみの面が毎フレーム組み直される。読むのは既に数えてある値だけなので、間隔を
/// 落としても数字そのものは正しい。
private struct NumbersReadout: View {
    let read: () -> FrameNumbers?
    let warnings: WarningFeed?

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.interval)) { _ in
            VStack(alignment: .leading, spacing: 4) {
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
                // 警告は数字の下に 1 欄: 件数と、端末に出た最後の 1 行 (#3087)
                if let warnings = KnobText.warnings(warnings?.summary) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text("warnings")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        (Text(warnings.count).monospacedDigit() + Text(" — ") + Text(warnings.last))
                            .lineLimit(Self.warningLines)
                            .truncationMode(.tail)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }

    /// 読み直す間隔 (秒)。人が読める速さで足り、これより速くしても読めない。
    private static let interval: Double = 0.5
    /// 警告の欄の行数の上限。
    private static let warningLines = 3
}

/// 宣言 1 つぶんの行。
private struct KnobRow: View {
    let box: any DeclaredParam
    let history: KnobHistory?

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

    /// 実数のスライダー。**刻みを書いていれば刻みで動き、書いていなければ連続で動く** — 値は
    /// 刻みへ丸めない (外からの書き込み・保存の復元・コードからの代入は、ウィンドウの外の入口である)。
    ///
    /// **掴んでから離すまでを履歴の 1 段にする** (#4124) — 途中の値は積まない。
    @ViewBuilder
    private func slider(value: Binding<Double>, in range: ParamRange, step: Double?) -> some View {
        let editing = KnobBinding.editing(box, history: history)
        if let step {
            Slider(
                value: value, in: range.lowerBound...range.upperBound, step: step,
                onEditingChanged: editing)
        } else {
            Slider(
                value: value, in: range.lowerBound...range.upperBound, onEditingChanged: editing)
        }
    }

    @ViewBuilder
    private func control(for declaration: ParamDeclaration) -> some View {
        switch KnobKind.forDeclaration(declaration) {
        case .slider(let range, let step):
            slider(
                value: KnobBinding.number(box, declaration.value, history: history), in: range,
                step: step)
        case .steppedSlider(let range):
            slider(
                value: KnobBinding.number(box, declaration.value, history: history), in: range,
                step: 1)
        case .toggle:
            Toggle("", isOn: KnobBinding.flag(box, history: history))
                .labelsHidden()
        case .color:
            ColorPicker("", selection: KnobBinding.color(box, history: history))
                .labelsHidden()
        case .components(let count, let range, let step):
            VStack(spacing: 2) {
                ForEach(0..<count, id: \.self) { index in
                    slider(
                        value: KnobBinding.component(box, at: index, history: history),
                        in: range, step: step)
                }
            }
        case .choice(let choices):
            Picker("", selection: KnobBinding.text(box, history: history)) {
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
