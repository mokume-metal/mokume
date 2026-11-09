// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 制作を助けるためのウィンドウ。**スケッチのウィンドウとは別に立つ。**
///
/// ## なぜ分けるのか
///
/// ツールのウィンドウが 1 つしかないと、再ビルドの状態やノブを重ねるオーバーレイが、そのまま本番の画面に
/// 出るオーバーレイになる。`mokume watch` から起動したスケッチも本番になりうる (外部ディスプレイへ全画面で
/// 据える) ので、**混ぜた時点で開発の都合が本番へ出る** ([ADR-0032] 決定 1)。
///
/// ## スケッチのウィンドウの子ではない
///
/// 両方が同じディレクトリを独立に見る**兄弟**である。だからスケッチのウィンドウが 0 個でもプレビューは
/// 成立する — ウィンドウを持たず外へ流すスケッチ (Syphon で渡すなど) では、これだけが出る。
/// スケッチがウィンドウの数を宣言する API ができた日に、こちら側は何も変えなくてよい。
///
/// ## 重ねるものはフレームに触らない
///
/// 状態は AppKit のレイヤへ描かれ、フレームは Metal のレイヤを通る。ノブ (`KnobOverlay`) と同じ形で、
/// **経路が別であることそのもの**が「1 画素も触らない」を守っている
/// ([ADR-0030] 決定 1 / [ADR-0032] 決定 6)。
///
/// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
public final class SharedFramePreview {
    /// 覚えている枠が無いときの大きさ。作品のウィンドウ (`SharedFrameWindow.defaultSize`) と揃える。
    static let defaultSize = NSSize(width: 480, height: 270)

    /// 覚えている枠が無いとき、中央からどれだけずらすか。
    ///
    /// **作品のウィンドウの下へ出す。** どちらも同じ大きさで中央へ出るので、ずらさないと 2 枚が
    /// 寸分違わず重なり、ウィンドウが 1 つしか無いように見える (実測)。丈のぶんにウィンドウ枠と隙間を
    /// 足しただけずらす。
    ///
    /// 効くのは差し出し元が来る前の 1 回で、作品のウィンドウはまだ既定の大きさである。差し出し元が
    /// ウィンドウの倍率を名乗れば、作品のウィンドウはその大きさで置き直され、プレビューもその真下へ
    /// 置き直す (``WindowPlacement/placeBeneathArtwork(_:window:autosaveName:defaults:)``・#1624)。
    static let nudge = WindowPlacement.nudgeBelow(
        artworkHeight: SharedFrameWindow.defaultSize.height, previewHeight: defaultSize.height)

    /// 検査が拍を打つために見える (`displayLinkFired()`)。
    let stage: SharedFrameStage
    private let notice = NoticeOverlay()
    /// 面越しのつまみ。区画を渡されたときだけ在る。
    private let params: RemoteParams?
    /// いま重ねているつまみの面。宣言の顔ぶれが変われば作り直す。
    private var knobs: KnobOverlay?

    /// - Parameters:
    ///   - facet: 差し出し元の PID が置かれるディレクトリ (`.mokume/viewport`)。
    ///   - params: パラメータのディレクトリ (`.mokume/params`)。渡さなければノブは出ない。
    ///   - title: ウィンドウの名前。
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

    /// プレビューが拾ったイベントの送り先。**渡ってくるのはそのまま子プロセスの標準入力へ書ける 1 行**で、
    /// 受け取る側は中身を見ずに転送するだけでよい ([ADR-0032] 決定 4)。
    ///
    /// 繋がなければ、触っても何も起きない。
    public var onInput: ((String) -> Void)? {
        get { stage.onInput }
        set { stage.onInput = newValue }
    }

    /// 表示する世代が切り替わったことの通知。
    ///
    /// **切り替わるのは、新しい世代が最初のフレームを描画したときである** — マニフェストに現れた
    /// 瞬間ではない ([#1142](https://github.com/mokume-metal/mokume/issues/1142))。受け取る側は
    /// これをきっかけに、前の世代を実行していた子プロセスを止められる。**引数は切り替わった先の世代の子プロセスの PID**
    /// ([#2982](https://github.com/mokume-metal/mokume/issues/2982))で、PID を報告しない子プロセス (古いライブラリ) なら `nil`。
    public var onGenerationPromoted: ((Int32?) -> Void)? {
        get { stage.onGenerationPromoted }
        set { stage.onGenerationPromoted = newValue }
    }

    /// このステージが、待機中の世代のフレームを受け取れないことの通知 ([#2928](https://github.com/mokume-metal/mokume/issues/2928))。
    ///
    /// **切り替えの通知が来ない形のうち、ツールだけが知るもの** (``UndeliverableGeneration``) である。
    /// 受け取る側は、切り替えを待っている世代のぶんだけ、前の世代を終了できる。**2 つ目の引数は、読めたマニフェストが
    /// 報告した子プロセスの PID**で、読めないマニフェスト・PID を報告しない子プロセスなら `nil` (#2982)。
    public var onGenerationUndeliverable: ((UndeliverableGeneration, Int32?) -> Void)? {
        get { stage.onGenerationUndeliverable }
        set { stage.onGenerationUndeliverable = newValue }
    }

    /// `mokume watch` が、いま映している世代を手放したと伝える ([#2983](https://github.com/mokume-metal/mokume/issues/2983))。
    ///
    /// 終了した世代のカーソルの要求 (捕まえる・隠す) を取り下げ、その世代の要求を次の切り替えまで読まない。
    /// **最後のフレームと入力のコピーの寸法は残す。**
    /// 受け取れない世代の通知 (``onGenerationUndeliverable``) はステージが自分で気付くが、クラッシュした子プロセス・子プロセスの離脱・
    /// 通知の来ないまま次の保存が来た回はステージを通らないので、ツールが伝える。**終了した・居なくなったと決めた世代に
    /// ついてだけ呼ぶ** — 生きてフレームを書き続ける世代へ当たると、その世代は次の切り替えまでカーソルを要求できない。
    ///
    /// - Parameter pids: 手放す世代の子プロセスの PID ([#2982](https://github.com/mokume-metal/mokume/issues/2982))。
    ///   映っている世代のマニフェストが報告する PID と照合し、手放す世代でなければ当てない。まだ採用していないマニフェストも、
    ///   手放した PID のものは生成時から手放した扱いにする。PID を報告しない世代 (古いライブラリ) は
    ///   照合できないので手放す。
    public func relinquishGeneration(pids: [Int32]) {
        stage.relinquishSource(pids: pids)
    }

    /// `mokume watch` が、待機中の世代へ切り替えないと決めた ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// 起動に失敗した新しいビルドを捨てて前のビルドを現行に戻した回に呼ぶ。失敗した子プロセスのマニフェストが待機中にあれば破棄し、
    /// 後から来ても採用しない。**既に切り替えて映している世代がその子プロセスなら、前のビルドへ映し直す** — 子プロセスが 1 フレーム書いて
    /// 切り替わった後、描画が見送られたティックで終了すると、最初のフレームの通知は発火しない。
    ///
    /// - Parameter pids: 切り替えない世代の子プロセスの PID。
    public func abandonGeneration(pids: [Int32]) {
        stage.abandonIncoming(pids: pids)
    }

    /// `mokume watch` が新しい子プロセスを起動した ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    ///
    /// その PID を、切り替えないと決めた世代と手放した世代の記録から外す。PID は使い回されるので、残すと同じ PID の
    /// 新しい子プロセスのマニフェストを黙って破棄し、その子プロセスの要求を読まない。
    ///
    /// - Parameter pids: 起動した子プロセスの PID。
    public func expectGeneration(pids: [Int32]) {
        stage.expectGeneration(pids: pids)
    }

    /// いま映している世代の目録が名乗った子の番号 ([#3565](https://github.com/mokume-metal/mokume/issues/3565))。
    ///
    /// 見張りが、このウィンドウで触った出来事の宛先を引くのに使う。名乗らない子 (古いライブラリ)・まだ何も映していない
    /// ときは `nil`。
    package var displayedPID: Int32? { stage.displayedPID }

    /// このウィンドウが採る目録の関所 ([#3565](https://github.com/mokume-metal/mokume/issues/3565))。
    ///
    /// 引数は目録が名乗る子の番号で、名乗らない子は `nil`。`false` を返した目録は採らない。試聴の間、作品のウィンドウは
    /// 試聴の子の目録を、プレビューは本番の目録を採らないために使う。設定しなければ、どの目録も採る。
    package var acceptsGeneration: ((Int32?) -> Bool)? {
        get { stage.acceptsGeneration }
        set { stage.acceptsGeneration = newValue }
    }

    /// 押し出さずに覚えておく世代を決める (``returnToGeneration(pid:)`` の戻り先)。空で外す。
    package func holdGeneration(pids: [Int32]) {
        stage.holdGeneration(pids: pids)
    }

    /// 覚えている目録の世代へ戻る。戻れたかを返す。
    @discardableResult
    package func returnToGeneration(pid: Int32) -> Bool {
        stage.returnToGeneration(pid: pid)
    }

    /// 表示する世代の最初のフレームを画面へ出したことの通知。
    ///
    /// **切り替えの通知より遅いことがある。** 最初の世代はフレームが来る前に採用されるので、
    /// 「フレームが見えるようになった」を待つ側はこちらを使う
    /// ([#2875](https://github.com/mokume-metal/mokume/issues/2875))。
    ///
    /// **引数は、最初のフレームを出した世代のマニフェストが報告した子プロセスの PID** ([#3172](https://github.com/mokume-metal/mokume/issues/3172))。
    /// PID を報告しない子プロセス (古いライブラリ) は `nil`。`mokume watch` は、その子プロセスがフレームを出す前に終わったかを、これで読む。
    public var onGenerationShown: ((Int32?) -> Void)? {
        get { stage.onGenerationShown }
        set { stage.onGenerationShown = newValue }
    }

    /// × と `⌘W` を押されたときに確認し、確定したら通知する。
    ///
    /// **スケッチのウィンドウと同じ経路を通す** ([ADR-0032] 決定 7)。プレビューだけが消える形を作ると、
    /// 決定 7 が作らないと決めた「既定を外す API」がここに開く
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

    /// ウィンドウを出し、ディレクトリの監視を始める。
    public func open() {
        stage.open(overlay: notice)
        // **1 拍ごとに面を読み直す。** 走っている側が値を変えることもあるので、
        // こちらから動かしたときだけ見に行く形にはしない
        stage.onTick = { [weak self] in self?.refreshKnobs() }
        refreshKnobs(force: true)
    }

    /// 閉じる。
    public func close() {
        stage.onTick = nil
        knobs = nil
        stage.close()
    }

    /// 重ねる面が出ているか。**検査から見る** — 「作品のウィンドウには出ない」を機械で確かめるには、
    /// 出ている側も見えている必要がある。
    var hasPanel: Bool { knobs != nil }

    /// 閉じる前に問うようになっているか。**検査から見る** — 「プレビューだけが消える形を
    /// 作らない」(ADR-0032 決定 7) を機械で確かめるには、繋がっていることが見えている
    /// 必要がある。
    var asksBeforeClosing: Bool { stage.asksBeforeClosing }

    /// 重ねている面の丈。**検査から見る** — 警告が後から来て欄が伸びたときに、枠が追い付いているかを見る。
    var panelHeight: CGFloat? { knobs?.frame.height }

    /// 並んでいるつまみの数。**面が出ていることとは別に見る** — 宣言が 1 つも無いときは
    /// 「面は出るがつまみは 0」であり、これを 1 つの真偽で表すと区別が付かない。
    var knobCount: Int { knobs?.knobCount ?? 0 }

    /// つまみと速さの読み出しを面と合わせる。
    ///
    /// **宣言が 1 つも無くても、速さは出す。** つまみが宣言から出る ([ADR-0030] 決定 8) のは
    /// そのままだが、速さは宣言ではない — ここは**道具のウィンドウ**なので、宣言の有無と関係なく
    /// 制作を助けるものが載る ([ADR-0032] 決定 1)。作品のウィンドウ (`run` のウィンドウ) の振る舞いは
    /// 変わらない。
    ///
    /// 顔ぶれが変わったときだけ組み直すのは、値が変わるたびに作り直すと触っている手から
    /// つまみが消えるためである。
    ///
    /// [ADR-0030]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0030-parameter-surfaces.md
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    private func refreshKnobs(force: Bool = false) {
        guard let params, let host = stage.host else { return }
        if params.refresh() || force {
            knobs?.removeFromSuperview()
            // **数字は面から読む。** 数えているのは走っている側で、こちらは読み手である
            // ([ADR-0030] 決定 7) — 届いていなければ `nil` が返り、面は「—」と描く
            let overlay = KnobOverlay(boxes: params.boxes, numbers: { [stage] in stage.numbers })
            overlay.attach(to: host)
            knobs = overlay
        }
        // **警告は拍ごとに押し込む** ([#3087](https://github.com/mokume-metal/mokume/issues/3087))。欄が出入りすると
        // 面の丈が変わるので、顔ぶれが変わらなくても枠を置き直す必要がある (面が作り直されたときも、ここで載る)
        knobs?.show(warnings: stage.warnings)
    }

    /// 重ねる 1 行を差し替える。
    ///
    /// **文言はここで決めない。** 正本は端末に出ている行で ([#695](https://github.com/mokume-metal/mokume/issues/695))、
    /// このオーバーレイはそれを映す — 文言を持つと、同じことを 2 か所で報告することになる。
    ///
    /// - Parameters:
    ///   - line: 出す 1 行。`nil` なら消す。
    ///   - spinning: スピナーを出すか。
    public func report(_ line: String?, spinning: Bool) {
        notice.show(line, spinning: spinning)
    }
}
