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
    /// 覚えている枠が無いときの大きさ。作品の窓 (`SharedFrameWindow.defaultSize`) と揃える。
    static let defaultSize = NSSize(width: 480, height: 270)

    /// 覚えている枠が無いとき、中央からどれだけずらすか。
    ///
    /// **作品の窓の下へ出す。** どちらも同じ大きさで中央へ出るので、ずらさないと 2 枚が
    /// 寸分違わず重なり、窓が 1 つしか無いように見える (実測)。丈のぶんに窓枠と隙間を
    /// 足しただけずらす。
    ///
    /// 効くのは差し出し元が来る前の 1 回で、作品の窓はまだ既定の大きさである。差し出し元が
    /// 窓の倍率を名乗れば、作品の窓はその大きさで置き直され、プレビューもその真下へ
    /// 置き直す (``WindowPlacement/placeBeneathArtwork(_:window:autosaveName:defaults:)``・#1624)。
    static let nudge = WindowPlacement.nudgeBelow(
        artworkHeight: SharedFrameWindow.defaultSize.height, previewHeight: defaultSize.height)

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
                defaultSize: Self.defaultSize, nudge: Self.nudge,
                placesBeneathRequestedArtwork: true))
    }

    /// プレビューが拾った出来事の行き先。**渡ってくるのはそのまま子の標準入力へ書ける 1 行**で、
    /// 受け取る側は中身を見ずに転送するだけでよい ([ADR-0032] 決定 4)。
    ///
    /// 繋がなければ、触っても何も起きない。
    public var onInput: ((String) -> Void)? {
        get { stage.onInput }
        set { stage.onInput = newValue }
    }

    /// 出す世代が入れ替わったことの知らせ。
    ///
    /// **入れ替わるのは、新しい世代が最初のフレームを焼いたときである** — 目録に現れた
    /// 瞬間ではない ([#1142](https://github.com/mokume-metal/mokume/issues/1142))。受け取る側は
    /// これを合図に、前の世代を走らせていた子を止められる。**引数は乗り換えた世代の子の番号**
    /// ([#2982](https://github.com/mokume-metal/mokume/issues/2982))で、番号を名乗らない子 (古いライブラリ) なら `nil`。
    public var onGenerationPromoted: ((Int32?) -> Void)? {
        get { stage.onGenerationPromoted }
        set { stage.onGenerationPromoted = newValue }
    }

    /// この台が、控えた世代の絵を受け取れないことの知らせ ([#2928](https://github.com/mokume-metal/mokume/issues/2928))。
    ///
    /// **乗り換えの知らせが来ない形のうち、道具だけが知るもの** (``UndeliverableGeneration``) である。
    /// 受け取る側は、乗り換えを待っている世代のぶんだけ、前の世代を畳める。**2 つ目の引数は、読めた目録が
    /// 名乗った子の番号**で、読めない目録・番号を名乗らない子なら `nil` (#2982)。
    public var onGenerationUndeliverable: ((UndeliverableGeneration, Int32?) -> Void)? {
        get { stage.onGenerationUndeliverable }
        set { stage.onGenerationUndeliverable = newValue }
    }

    /// 見張りが、いま映している世代を手放したと伝える ([#2983](https://github.com/mokume-metal/mokume/issues/2983))。
    ///
    /// 畳んだ世代のカーソルの頼み (捕まえる・隠す) を下ろし、その世代の頼みを次の乗り換えまで読まない。
    /// **最後の絵と入力の写しの寸法は残す。**
    /// 受け取れない世代の知らせ (``onGenerationUndeliverable``) は台が自分で気付くが、倒れた子・子の離脱・
    /// 合図の来ないまま次の保存が来た回は台を通らないので、道具が伝える。**畳む・居なくなったと決めた世代に
    /// ついてだけ呼ぶ** — 生きて書き続ける世代へ当たると、その世代は次の乗り換えまでカーソルを頼めない。
    ///
    /// - Parameter pids: 手放す世代の子の番号 ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。
    ///   映っている世代の目録が名乗る番号と照合し、手放す世代でなければ当てない。まだ採っていない目録も、
    ///   手放した番号のものは生まれたときから手放した扱いにする。番号を名乗らない世代 (古いライブラリ) は
    ///   照合できないので手放す。
    public func relinquishGeneration(pids: [Int32]) {
        stage.relinquishSource(pids: pids)
    }

    /// 見張りが、控えている世代へ乗り換えないと決めた ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// 起動に失敗した新しい版を捨てて前の版を現役に戻した回に呼ぶ。失敗した子の目録が控えにあれば捨て、
    /// 後から来ても採らない。**既に乗り換えて映している世代がその子なら、前の版へ映し直す** — 子が 1 枚書いて
    /// 乗り換えた後、描画が見送られた拍に死ぬと、1 枚目の合図は鳴らない。
    ///
    /// - Parameter pids: 乗り換えない世代の子の番号。
    public func abandonGeneration(pids: [Int32]) {
        stage.abandonIncoming(pids: pids)
    }

    /// 見張りが新しい子を起こした ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// その番号を、乗り換えないと決めた世代から外す。番号は使い回されるので、残すと同じ番号の新しい子の目録を
    /// 黙って捨てる。
    ///
    /// - Parameter pids: 起こした子の番号。
    public func expectGeneration(pids: [Int32]) {
        stage.expectGeneration(pids: pids)
    }

    /// 出す世代の最初の 1 枚を画面へ出したことの知らせ。
    ///
    /// **入れ替わりの知らせより遅いことがある。** 最初の世代は絵が来る前に採用されるので、
    /// 「絵が見えるようになった」を待つ側はこちらを使う
    /// ([#2875](https://github.com/mokume-metal/mokume/issues/2875))。
    ///
    /// **引数は、1 枚目を出した世代の目録が名乗った子の番号** ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    /// 名乗らない子 (古いライブラリ) は `nil`。見張りは、その子が絵を出す前に終わったかを、これで読む。
    public var onGenerationShown: ((Int32?) -> Void)? {
        get { stage.onGenerationShown }
        set { stage.onGenerationShown = newValue }
    }

    /// × と `⌘W` を押されたときに確かめ、確定したら知らせる。
    ///
    /// **作品の窓と同じ経路を通す** ([ADR-0032] 決定 7)。プレビューだけが消える形を作ると、
    /// 決定 7 が作らないと決めた「既定を外す口」がここに開く
    /// ([#826](https://github.com/mokume-metal/mokume/issues/826))。
    ///
    /// 引数の意味は ``SharedFrameWindow/askBeforeClosing(message:detail:confirm:cancel:then:)``
    /// と同じ。
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

    /// 閉じる前に問うようになっているか。**検査から見る** — 「プレビューだけが消える形を
    /// 作らない」(ADR-0032 決定 7) を機械で確かめるには、繋がっていることが見えている
    /// 必要がある。
    var asksBeforeClosing: Bool { stage.asksBeforeClosing }

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
