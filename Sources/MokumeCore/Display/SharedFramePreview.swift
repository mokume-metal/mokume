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

    /// - Parameters:
    ///   - facet: 差し出し元の番号が置かれる区画 (`.mokume/viewport`)。
    ///   - title: 窓の名前。**作品の窓と見分けが付く形にする** — 並んで出るので、
    ///     同じ名前だとどちらを本番へ送るのか分からない。
    public init(gpu: RenderDevice, facet: URL, title: String) throws(RenderFailure) {
        self.stage = try SharedFrameStage(
            gpu: gpu, facet: facet,
            look: SharedFrameStage.Look(
                title: title, autosaveName: WindowPlacement.previewAutosaveName,
                defaultSize: Self.defaultSize, nudge: Self.nudge))
    }

    /// 窓を出し、区画を見張り始める。
    public func open() {
        stage.open(overlay: notice)
    }

    /// 畳む。
    public func close() {
        stage.close()
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
