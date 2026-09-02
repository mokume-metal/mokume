// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 制作を助けるための窓。**作品の窓とは別に立つ。**
///
/// ## なぜ分けるのか
///
/// 道具の窓が 1 つしかないと、作り直しの状態やつまみを重ねる面が、そのまま本番の画面に
/// 出る面になる。見張りから起こした作品も本番になりうる (外部ディスプレイへ全画面で
/// 据える) ので、**混ぜた時点で開発の都合が本番へ出る** ([ADR-0032] 決定 1)。
///
/// ## 作品の窓の子ではない
///
/// 両方が同じ区画を独立に見る**兄弟**である。だから作品の窓が 0 つでもプレビューは
/// 成立する — 窓を持たず外へ流す作品 (Syphon で渡すなど) では、これだけが出る。
/// 作品が窓の数を宣言する口ができた日に、こちら側は何も変えなくてよい。
///
/// ## 重ねるものは絵に触らない
///
/// 状態は AppKit の層へ描かれ、絵は Metal の層を通る。つまみ (`KnobOverlay`) と同じ形で、
/// **経路が別であることそのもの**が「1 画素も触らない」を守っている
/// ([ADR-0030] 決定 1 / [ADR-0032] 決定 6)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
public final class SharedFramePreview {
    /// 覚えている枠が無いときの大きさ。作品の窓と揃える。
    static let defaultSize = NSSize(width: 480, height: 270)

    /// 覚えている枠が無いとき、中央からどれだけずらすか。
    ///
    /// **作品の窓の下へ出す。** どちらも同じ大きさで中央へ出るので、ずらさないと 2 枚が
    /// 寸分違わず重なり、窓が 1 つしか無いように見える (実測)。丈のぶんに窓枠と隙間を
    /// 足しただけずらす。
    static let nudge = NSSize(width: 0, height: -(defaultSize.height + 44))

    private let stage: SharedFrameStage
    private let notice = NoticeOverlay()
    /// 面越しのつまみ。区画を渡されたときだけ在る。
    private let params: RemoteParams?
    /// いま重ねているつまみの面。宣言の顔ぶれが変われば作り直す。
    private var knobs: KnobOverlay?

    /// - Parameters:
    ///   - facet: 差し出し元の番号が置かれる区画 (`.mokume/viewport`)。
    ///   - params: つまみの区画 (`.mokume/params`)。渡さなければつまみは出ない。
    ///   - title: 窓の名前。
    public init(gpu: RenderDevice, facet: URL, params: URL? = nil, title: String)
        throws(RenderFailure)
    {
        self.params = params.map { RemoteParams(directory: $0) }
        self.stage = try SharedFrameStage(
            gpu: gpu, facet: facet,
            look: SharedFrameStage.Look(
                title: title, autosaveName: WindowPlacement.previewAutosaveName,
                defaultSize: Self.defaultSize, nudge: Self.nudge))
    }

    /// プレビューが拾った出来事の行き先。**渡ってくるのはそのまま子の標準入力へ書ける 1 行**で、
    /// 受け取る側は中身を見ずに転送するだけでよい ([ADR-0032] 決定 4)。
    ///
    /// 繋がなければ、触っても何も起きない。
    public var onInput: ((String) -> Void)? {
        get { stage.onInput }
        set { stage.onInput = newValue }
    }

    /// 窓を出し、区画を見張り始める。
    public func open() {
        stage.open(overlay: notice)
        // **1 拍ごとに面を読み直す。** 走っている側が値を変えることもあるので、
        // こちらから動かしたときだけ見に行く形にはしない
        stage.onTick = { [weak self] in self?.refreshKnobs() }
        refreshKnobs(force: true)
    }

    /// 畳む。
    public func close() {
        stage.onTick = nil
        knobs = nil
        stage.close()
    }

    /// 重ねる面が出ているか。**検査から見る** — 「作品の窓には出ない」を機械で確かめるには、
    /// 出ている側も見えている必要がある。
    var hasPanel: Bool { knobs != nil }

    /// 並んでいるつまみの数。**面が出ていることとは別に見る** — 宣言が 1 つも無いときは
    /// 「面は出るがつまみは 0」であり、これを 1 つの真偽で表すと区別が付かない。
    var knobCount: Int { knobs?.knobCount ?? 0 }

    /// つまみと速さの読み出しを面と合わせる。
    ///
    /// **宣言が 1 つも無くても、速さは出す。** つまみが宣言から出る ([ADR-0030] 決定 8) のは
    /// そのままだが、速さは宣言ではない — ここは**道具の窓**なので、宣言の有無と関係なく
    /// 制作を助けるものが載る ([ADR-0032] 決定 1)。作品の窓 (`run` の窓) の振る舞いは
    /// 変わらない。
    ///
    /// 顔ぶれが変わったときだけ組み直すのは、値が変わるたびに作り直すと触っている手から
    /// つまみが消えるためである。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private func refreshKnobs(force: Bool = false) {
        guard let params, let host = stage.host else { return }
        guard params.refresh() || force else { return }
        knobs?.removeFromSuperview()
        // **数字は面から読む。** 数えているのは走っている側で、こちらは読み手である
        // ([ADR-0030] 決定 7) — 届いていなければ `nil` が返り、面は「—」と描く
        let overlay = KnobOverlay(boxes: params.boxes) { [stage] in stage.numbers }
        overlay.attach(to: host)
        knobs = overlay
    }

    /// 重ねる 1 行を差し替える。
    ///
    /// **文言はここで決めない。** 正本は端末に出ている行で ([#695](https://github.com/mokume-metal/mokume/issues/695))、
    /// この面はそれを映す — 言葉を持つと、同じことを 2 か所で名乗ることになる。
    ///
    /// - Parameters:
    ///   - line: 出す 1 行。`nil` なら畳む。
    ///   - spinning: 回っている印を出すか。
    public func report(_ line: String?, spinning: Bool) {
        notice.show(line, spinning: spinning)
    }
}
