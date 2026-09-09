// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 別のプロセスが差し出している絵を、**作品の窓**として出す。
///
/// ## なぜ道具が窓を持つのか
///
/// 見張り (`watch`) は保存のたびに子を入れ替えるので、**子が窓を持つ限り窓は死ぬ**。
/// 全画面と、どの画面に置いたかは窓の寿命に紐づいているので、作り直しのたびに一緒に
/// 失われる — 位置を覚えて開き直しても戻らない。見張りから起こした作品も本番になりうる
/// 以上、これは**本番の見え方が保存のたびに壊れる**ということである
/// ([ADR-0032] 決定 1)。
///
/// ## ここに道具の都合を出さない
///
/// つまみも、作り直しの状態も、回っている印も載せない — 見張りから本番を回している間、
/// 開発の都合が本番の画面に出てはならない ([ADR-0032] 決定 1・6)。それらは
/// ``SharedFramePreview`` の仕事である。
///
/// **守り方は「載せないように気をつける」ではない。** 重ねる面を台へ渡さないので、
/// 載せる場所そのものが無い。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
public final class SharedFrameWindow {
    /// 覚えている枠が無いときの大きさ。
    ///
    /// **この値はプレビューのずらし量の前提である。** `SharedFramePreview.nudge` は
    /// `SharedFramePreview.defaultSize` の丈からずらす量を出しており、2 つの既定が
    /// 揃っていることで初めて「プレビューが作品の窓の真下に並ぶ」が成立する — ここだけ
    /// 大きくすると**プレビューが作品の窓に重なる**。割れたら
    /// `SharedFrameStageTests` が赤くなる ([#964])。
    ///
    /// ## 写しは畳まない
    ///
    /// 同じ 480x270 は**3 つ目がある** — `SketchApplication` が `run` の窓を出すときの
    /// `settings.width / 2` が、``SketchSettings`` の既定 960x540 の半分としてこの値に
    /// なる。あちらはキャンバスの大きさで実行時に動くのに、道具の窓が出しているのは
    /// 別プロセスが差し出す絵で、キャンバスの大きさを知らない。**3 つを寄せる先が無い**
    /// ので、寄せずに「割れても直せる形」(検査) を置いた
    /// ([ADR-0008] 決定 6・[#964])。
    ///
    /// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
    /// [#964]: https://github.com/mokume-metal/mokume/issues/964
    static let defaultSize = NSSize(width: 480, height: 270)

    private let stage: SharedFrameStage

    /// - Parameters:
    ///   - facet: 差し出し元の番号が置かれる区画 (`.mokume/viewport`)。
    ///   - title: 窓の名前。
    public init(gpu: RenderDevice, facet: URL, title: String) throws(RenderFailure) {
        self.stage = try SharedFrameStage(
            gpu: gpu, facet: facet,
            look: SharedFrameStage.Look(
                title: title, autosaveName: WindowPlacement.autosaveName,
                defaultSize: Self.defaultSize))
    }

    /// 作品の窓が拾った出来事の行き先。**渡ってくるのはそのまま子の標準入力へ書ける 1 行**で、
    /// 受け取る側は中身を見ずに転送するだけでよい ([ADR-0032] 決定 4)。
    ///
    /// 繋がなければ、触っても何も起きない。
    public var onInput: ((String) -> Void)? {
        get { stage.onInput }
        set { stage.onInput = newValue }
    }

    /// × と `⌘W` を押されたときに確かめ、確定したら知らせる。
    ///
    /// **確かめている間は閉じない。** 繋がなければ AppKit の既定で閉じるので、絵の出口
    /// だけが消えて誰も止まらない ([#826](https://github.com/mokume-metal/mokume/issues/826))。
    ///
    /// **窓を畳むのはここではない** — 受け取った側が後始末の順で畳む。
    ///
    /// - Parameters:
    ///   - message: 見出し。
    ///   - detail: 押した後どうなるか。
    ///   - confirm: 閉じる側の押しどころ。
    ///   - cancel: 閉じない側の押しどころ。
    ///   - confirmed: 閉じてよいと確定したときに呼ばれる。
    public func askBeforeClosing(
        message: String, detail: String, confirm: String, cancel: String,
        then confirmed: @escaping () -> Void
    ) {
        stage.askBeforeClosing(
            .init(message: message, detail: detail, confirm: confirm, cancel: cancel),
            then: confirmed)
    }

    /// 窓を出し、区画を見張り始める。
    public func open() {
        stage.open()
    }

    /// 畳む。
    public func close() {
        stage.close()
    }
}
