// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import AppKit

/// 別のプロセスが差し出しているフレームを、**スケッチのウィンドウ**として出す。
///
/// ## なぜツールがウィンドウを持つのか
///
/// `mokume watch` は保存のたびに子プロセスを入れ替えるので、**子プロセスがウィンドウを持つ限りウィンドウは消える**。
/// 全画面と、どの画面に置いたかはウィンドウの寿命に紐づいているので、再ビルドのたびに一緒に
/// 失われる — 位置を覚えて開き直しても戻らない。`mokume watch` から起動したスケッチも本番になりうる
/// 以上、これは**本番の見え方が保存のたびに壊れる**ということである
/// ([ADR-0032] 決定 1)。
///
/// ## ここにツールの都合を出さない
///
/// ノブも、再ビルドの状態も、スピナーも載せない — `mokume watch` から本番を実行している間、
/// 開発の都合が本番の画面に出てはならない ([ADR-0032] 決定 1・6)。それらは
/// ``SharedFramePreview`` の仕事である。
///
/// **守り方は「載せないように気をつける」ではない。** オーバーレイをステージへ渡さないので、
/// 載せる場所そのものが無い。
///
/// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
@MainActor
public final class SharedFrameWindow {
    /// 覚えている枠が無く、**差し出し元がまだ来ていない**ときの大きさ。
    ///
    /// 差し出し元がウィンドウの倍率を名乗れば、最初の絵が出るときにその大きさ (描く大きさ ×
    /// ``SketchSettings/windowScale``) へ合わせる — 直に走らせたときと同じ大きさで見える
    /// ([ADR-0032] 決定 1・[#1624])。名乗らない古いライブラリの子なら、この大きさのまま残る。
    ///
    /// **この値はプレビューのずらし量の材料である。** `SharedFramePreview.nudge` は
    /// この丈とプレビューの丈から、差し出し元が来る前にプレビューを作品のウィンドウの真下へ出す
    /// 量を出している (`WindowPlacement.nudgeBelow`)。作品のウィンドウが頼まれた大きさで置き直された
    /// 後は、プレビューもその丈から置き直す (#1624)。並びが割れたら
    /// `SharedFrameStageTests` が赤くなる ([#964])。
    ///
    /// ## 写しは畳まない
    ///
    /// 同じ 480x270 は**3 つ目がある** — `SketchApplication` が `run` のウィンドウを出すときの
    /// 描く大きさ × 倍率が、``SketchSettings`` の既定 (960x540・0.5) でこの値になる。
    /// あちらはキャンバスの大きさで実行時に動くのに、道具のウィンドウが開く時点では差し出し元が
    /// まだ来ておらず、キャンバスの大きさを知らない。**3 つを寄せる先が無い**
    /// ので、寄せずに「割れても直せる形」(検査) を置いた
    /// ([ADR-0008] 決定 6・[#964])。
    ///
    /// [ADR-0008]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0008-mechanism-needs-demonstrated-harm.md
    /// [#964]: https://github.com/mokume-metal/mokume/issues/964
    /// [#1624]: https://github.com/mokume-metal/mokume/issues/1624
    /// [ADR-0032]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0032-window-ownership.md
    static let defaultSize = NSSize(width: 480, height: 270)

    /// 検査が拍を打つために見える (``SharedFramePreview/stage`` と同じ)。
    let stage: SharedFrameStage

    /// - Parameters:
    ///   - facet: 差し出し元の PID が置かれるディレクトリ (`.mokume/viewport`)。
    ///   - title: ウィンドウの名前。
    public init(gpu: RenderDevice, facet: URL, title: String) throws(RenderFailure) {
        self.stage = try SharedFrameStage(
            gpu: gpu, facet: facet,
            look: SharedFrameStage.Look(
                title: title, autosaveName: WindowPlacement.autosaveName,
                defaultSize: Self.defaultSize, followsRequestedSize: true,
                showsSelectionDialogs: true, followsRequestedTitle: true))
    }

    /// スケッチのウィンドウが拾ったイベントの送り先。**渡ってくるのはそのまま子プロセスの標準入力へ書ける 1 行**で、
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

    /// 映している世代の子が載せた名乗りの中身を、新しい絵から読むたびの知らせ (``SharedFrameStage/onFrameShareRead``)。
    /// `nil` は断っている。見張りが目録への名乗りを付け外しする ([#3919](https://github.com/mokume-metal/mokume/issues/3919))。
    package var onFrameShareRead: ((FrameShare?) -> Void)? {
        get { stage.onFrameShareRead }
        set { stage.onFrameShareRead = newValue }
    }

    /// 映している世代のいまの絵を、リフレッシュごとに新しいかを添えて知らせる (``SharedFrameStage/onFrame``)。見張りが
    /// 受け手の面へ写す ([#3920](https://github.com/mokume-metal/mokume/issues/3920)・#3945)。ウィンドウが見えなくても呼ぶ。
    package var onFrame: (((any MTLTexture)?, Bool) -> Void)? {
        get { stage.onFrame }
        set { stage.onFrame = newValue }
    }

    /// 台が描く GPU。見張りの送り手が、子の面から受け手の面へ写すのに使う。
    package var gpu: RenderDevice { stage.gpu }

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
    /// **確認している間は閉じない。** 繋がなければ AppKit の既定で閉じるので、表示
    /// だけが消えて誰も止まらない ([#826](https://github.com/mokume-metal/mokume/issues/826))。
    ///
    /// **ウィンドウを閉じるのはここではない** — 受け取った側が終了処理の順で閉じる。
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

    /// ウィンドウを出し、ディレクトリの監視を始める。
    public func open() {
        stage.open()
    }

    /// 閉じる。
    public func close() {
        stage.close()
    }
}
