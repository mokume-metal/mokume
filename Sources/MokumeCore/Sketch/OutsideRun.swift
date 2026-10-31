// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 走っている実行の外から呼ばれた語彙の控え。**何を、どう扱ったか**を口の名前ごとに 1 度だけ言う
/// ([#2265])。
///
/// 語彙が描く先・読む元は ``runningSketch`` で、差さっているのは `setup()`・`draw()`・入力の
/// コールバックの間だけである。外 — 初期化子の中 (`struct Player: SketchPart` の `init()`)・
/// 後片付けの後・そこで起こした `Task` の中 — から呼ばれたとき、以前は `fatalError` で
/// プロセスごと落ちていた。ADR-0020 決定 5 は、描く口は「警告して安全な既定へ倒す」、読み取りは
/// 「決して落ちない」と決めている。ここはその警告の側を持つ。
///
/// **口の名前と扱い (読んだ・呼んだ) の組を鍵に 1 度だけ言う。** 名前は呼ぶ側の `#function` で、
/// 引数の数が同じ重ね定義 (`fill(_:)` の灰色と色) は 1 つに、数が違う形 (`fill(_:)` と
/// `fill(_:_:_:)`) は別に数える。扱いも鍵に入れるのは、`orbit` のように読みと書きが同じ名前を
/// 持つ口で、先に踏んだ側がもう一方を永久に黙らせないためである。毎フレーム呼ばれる口でも 1 行で
/// 済み、控えは口の種類の数で止まる。
///
/// **言った警告は、次の観測の応答にも 1 度だけ載る。** 標準エラーの 1 行は MCP から読めず、部品が
/// (0, −30) に居続ける理由を AI が観測で辿れなくなるためである。載せるのはここではなく
/// ``Diagnostics/takeUnreported()`` の 1 本で、スケッチが言った警告すべてと同じ経路を通る
/// ([#2761])。ここも ``WarningLog`` の控えを通って ``Diagnostics/warn(_:)`` へ言うので、
/// 載せる口を別に持つと同じ行が 2 度載る。毎回載せると、`init` で 1 度踏んだ古い警告が、
/// 無関係な観測の失敗の理由 (時刻を指定した観測は `warnings` をそのまま理由にする) に混ざり続ける。
///
/// 呼び出しの外から頼まれた進行・時刻・書き出し・繋ぎの口 (``OutsideCall``) も、同じ控えで言う。
///
/// **「走っていない」とは言わない** (``OutsideCall`` と同じく [#1322])。`draw()` が回っている
/// 最中に `Task` から呼んでもここへ来るので、どちらでも事実である「どこからなら受け付けるか」を
/// 言う。
///
/// [#1322]: https://github.com/mokume-metal/mokume/issues/1322
/// [#2265]: https://github.com/mokume-metal/mokume/issues/2265
/// [#2761]: https://github.com/mokume-metal/mokume/issues/2761
@MainActor
package final class OutsideRun {
    /// 外から呼ばれたとき、どう倒したか。
    package enum Use {
        /// 描く・状態を書く口。何もしなかった。入力の止める口 (`AudioIn.stop()` など)
        /// ``SketchPart/detach(_:calledAs:)``) も使う。
        case act
        /// 読み取りの口。代わりに `value` (人が読む綴り: `0`・`.wallClock` など) を返した。
        case read(returning: String)
        /// 値を作って返す口のうち、投げない口。代わりに `value` (人が読む綴り: `an empty shape` など) を返した。
        /// ``SketchPart/createShape(_:)`` と、音・通信・シリアル・ゲームパッド・MIDI の投げない作る口 (合成音の `createSinOsc()` など・
        /// `createAudioIn(device:)`・記録を流す `messages:` の 4 口と `createSerial(lines:)`・`gamepads()`・
        /// `createGamepad(inputs:)`・`createMIDI(_:)`・`createMIDI(messages:)`。``SketchPart/attach(_:calledAs:returning:)``) が使う。
        case make(returning: String)
        /// 資源を作る口 (``SketchPart/loadImage(_:)`` など)。`notRunning(call:)` を投げた。
        ///
        /// 投げるだけでは、`try?` で受けた側に何も残らない (値が黙って `nil` になる)。投げる前に
        /// ここで 1 度言い、観測の応答にも載せる ([#2683] の反証 3)。
        ///
        /// [#2683]: https://github.com/mokume-metal/mokume/issues/2683
        case thrown
        /// 走っている実行へ足して使うものを作る口 (音・通信・シリアルの `loadSound(_:)`・`createTCPServer(_:)`・
        /// `createSerial(_:baudRate:)` など)。`notRunning(call:)` を投げた。文面は ``notAttachedNotice(_:)`` で、面の話をしない ([#2740])。
        ///
        /// [#2740]: https://github.com/mokume-metal/mokume/issues/2740
        case thrownUnattached
        /// 読み取りの口のうち、外では**最後に描いたフレームの値**を返すもの。代わりに `value` (人が読む綴り) を返した。
        /// 毎フレームの値を 1 つ持つ口 (`MokumeGame` の `Scene.current` など) が使う。`.read` の助言「`setup()` の中で決める」は
        /// 持ち主が毎フレーム変える値には成り立たないので、`draw()` の中で読み、他の所では自分の状態へ写して使う、と言う
        /// (SwiftUI の `body` のような、`draw()` の外に置く読み手にも実行できる助言)。
        case readLast(returning: String)
    }

    /// 検査が自分の控えを差す口。差していなければ ``shared``。
    ///
    /// 控えはプロセスで 1 つなので、並んで走る検査が同じ口を呼ぶと「1 度だけ」を数え合う。
    /// 差しておけば、その検査の中で起きたことだけを数えられる。
    @TaskLocal static var current: OutsideRun?

    /// プロセスの控え。
    static let shared = OutsideRun()

    /// いま言う先の控え。
    package static var log: OutsideRun { current ?? shared }

    /// 鍵。口の名前と、読んだか呼んだか。
    private struct Key: Hashable {
        let call: String
        let reading: Bool
    }

    private var said = WarningLog<Key>()
    /// 言った順 (対応表の順は定まらない)。**検査が読む。** 観測の応答へは、同じ文面が
    /// ``Diagnostics/takeUnreported()`` を通って載る。
    private(set) var messages: [String] = []

    /// その口について、まだ言っていなければ 1 度だけ言う。
    package func warn(_ call: String, _ use: Use) {
        switch use {
        case .read, .readLast:
            say(Key(call: call, reading: true), Self.notice(call, use))
        case .act, .make, .thrown, .thrownUnattached:
            say(Key(call: call, reading: false), Self.notice(call, use))
        }
    }

    /// 文面を呼ぶ側が持つ口 (``OutsideCall``) を、1 度だけ言う。
    func warn(_ call: OutsideCall) {
        say(Key(call: "\(call)", reading: false), call.notice)
    }

    private func say(_ key: Key, _ text: @autoclosure () -> String) {
        guard !said.hasWarned(key) else { return }
        said.warnOnce(key, text())
        if let said = said.message(for: key) { messages.append(said) }
    }

    /// 呼んだ口について言った文面。まだ言っていなければ `nil`。**検査が読む。**
    func message(for call: String) -> String? { said.message(for: Key(call: call, reading: false)) }

    /// 読んだ口について言った文面。まだ言っていなければ `nil`。**検査が読む。**
    func messageForRead(of call: String) -> String? { said.message(for: Key(call: call, reading: true)) }

    /// 言う中身。**2 通りを完全な文として持つ** (ADR-0038 決定 3)。差し込むのは口の名前と
    /// 返した値だけで、どちらも語順に関わらない識別子である。
    static func notice(_ call: String, _ use: Use) -> String {
        switch use {
        case .act:
            "\(call) only works inside setup(), draw() or an input callback. It was called "
                + "outside them — from an initialiser, after the sketch ended, or from a Task — so "
                + "it did nothing. Call it from setup() or draw()"
        case .read(let value):
            "\(call) is only known inside setup(), draw() or an input callback. It was read "
                + "outside them — from an initialiser, after the sketch ended, or from a Task — so "
                + "\(value) was returned instead. Make anything that depends on it inside setup()"
        case .readLast(let value):
            "\(call) is only known while the sketch is running (inside setup(), draw() or an input "
                + "callback). It was read outside — from an initialiser, a Task, or a SwiftUI view body — so "
                + "\(value) was returned instead. Read it inside draw(), and copy it into your own state "
                + "there (or expose() it) to use it anywhere else"
        case .make(let value):
            "\(call) only works inside setup(), draw() or an input callback. It was called "
                + "outside them — from an initialiser, after the sketch ended, or from a Task — so "
                + "\(value) was returned instead. Call it from setup()"
        case .thrown:
            // 投げた文面の 2 文 (起きたこと・次にすること) の間に、投げたことを言う独立の 1 文を挟む。
            // 標準エラーへは 1 行しか流せないので、改行は畳む
            notRunningNotice(call).replacingOccurrences(
                of: "\n", with: " It threw an error instead of returning anything. ")
        case .thrownUnattached:
            notAttachedNotice(call).replacingOccurrences(
                of: "\n", with: " It threw an error instead of returning anything. ")
        }
    }

    /// 待つ読み込みの口の名前。走っている実行の中で起こした `Task` からも呼べる (``LaunchingSketch``)
    /// ので、``notRunningNotice(_:)`` が呼べる場所をそう言い分ける。名前は口の `#function` である。
    nonisolated static let waitingLoads: Set<String> = [
        "requestImage(_:)", "requestModel(_:normalize:)", "requestShape(_:)",
    ]

    /// 走っている実行へ足して使うものを、待って返す口の名前 (``SketchPart/requestSound(_:)``)。`Task` の続きで返るので、
    /// 走っている実行の中で起こした `Task` からなら呼べる (``AttachRequests``)。``notAttachedNotice(_:)`` が
    /// 呼べる場所をそう言い分ける。名前は口の `#function` である。
    nonisolated static let waitingAttaches: Set<String> = ["requestSound(_:)"]

    /// 外から読まれた ``SketchPart/canvas`` が止めるときの文面。
    ///
    /// **資源の口の文面 (``notRunningNotice(_:)``) を使わない** (#2683 の反証 B5)。`canvas` は読む
    /// プロパティで、何かを作って返す口ではない。代わりに返せる値も投げる道も無いので止まる、と言い、
    /// 外からでも落ちない語彙へ案内する。「走っていない」とは言わない (#1322)。
    nonisolated static let canvasStopNotice =
        "canvas can only be read inside setup(), draw() or an input callback. It was read outside "
        + "them — from an initialiser, after the sketch ended, or from a Task — where the sketch's "
        + "surface cannot be reached, and there is no other value to give back, so the sketch "
        + "stopped. Read it inside setup() or draw(), or use the drawing functions such as circle() "
        + "and the values such as width, which do not stop outside them"

    /// 資源を作る口を外から呼んだときの文面 (``RenderFailure/notRunning(call:)`` など 6 つの型の
    /// `notRunning` と、その前に 1 度言う警告)。返す値そのものを面からしか作れないので、既定へ
    /// 倒せない ([#2683])。
    ///
    /// **2 通りを完全な文として持つ** (ADR-0038 決定 3)。待つ読み込みの口 (``waitingLoads``) だけが、
    /// 走っている実行の中で起こした `Task` から呼べる。同期の口をそこから呼ぶと投げるので、同じ文面で
    /// 「`Task` から呼べる」と言うと、呼んだ場所そのものを勧めることになる。
    ///
    /// 1 行目が起きたこと、2 行目が次にすることで、走っている最中の警告の 1 行 (``RenderFailure``
    /// の `headline`) は 1 行目になる。
    ///
    /// **「走っていない」「面が無い」とは言わない** (上の冒頭と同じく [#1322])。`draw()` が回っている
    /// 最中に、そこで起こした `Task` から同期の口を呼んでもここへ来る。そのとき面はあるが、そこからは
    /// 取れない。どちらでも事実である「どこからなら面を取れるか」を言う。場合の名前 (`notRunning`) は
    /// #2683 の完了条件が決めたもので、この言い方とずれる。
    ///
    /// [#1322]: https://github.com/mokume-metal/mokume/issues/1322
    /// [#2683]: https://github.com/mokume-metal/mokume/issues/2683
    nonisolated static func notRunningNotice(_ call: String) -> String {
        if waitingLoads.contains(call) {
            "\(call) only works inside setup(), draw() or an input callback, or in a Task started "
                + "there, because it makes what it returns on the sketch's surface, which can only be "
                + "reached from those places. It was called from somewhere else — an initialiser, "
                + "after the sketch ended, or Task.detached — so the surface could not be reached."
                + "\nCall it from a Task started in setup()"
        } else {
            "\(call) only works inside setup(), draw() or an input callback, because it makes what "
                + "it returns on the sketch's surface, which can only be reached there. It was called "
                + "outside them — from an initialiser, after the sketch ended, or from a Task — so the "
                + "surface could not be reached.\nCall it from setup()"
        }
    }

    /// 走っている実行へ足して使うものを作る口 (音・通信・シリアル) を外から呼んだときの文面 (`AudioFailure`・
    /// `NetworkFailure`・`OSCFailure`・`SerialFailure` の `notRunning(call:)` と、その前に 1 度言う警告) ([#2740])。
    ///
    /// 返すもの (音・ポート) は、走っている実行へ足されて毎フレーム回され、終わるときに閉じられる。足せない所で
    /// 作ると、音は鳴らず、ポートは受けない (送るだけなら届くが、終わっても閉じられない)。理由は面ではないので、
    /// ``notRunningNotice(_:)`` (面から作る口の文面) を使わない。
    /// 形はそれと同じく、1 行目が起きたこと、2 行目が次にすることで、「走っていない」とは言わない
    /// ([#1322])。投げる口は、ファイルを読む・ポートを開く前に投げる。
    ///
    /// **待って返す口 (``waitingAttaches``) だけが、走っている実行の中で起こした `Task` から呼べる。** 同期の口を
    /// そこから呼ぶと投げるので、同じ文面で「`Task` から呼べる」と言うと、呼んだ場所そのものを勧めることになる
    /// (``notRunningNotice(_:)`` の ``waitingLoads`` と同じ言い分け)。2 通りを完全な文として持つ (ADR-0038 決定 3)。
    ///
    /// [#1322]: https://github.com/mokume-metal/mokume/issues/1322
    /// [#2740]: https://github.com/mokume-metal/mokume/issues/2740
    nonisolated static func notAttachedNotice(_ call: String) -> String {
        if waitingAttaches.contains(call) {
            return "\(call) only works inside setup(), draw() or an input callback, or in a Task started "
                + "there, because what it returns has to join the running sketch, which can only happen "
                + "there. It was called from somewhere else — an initialiser, after the sketch ended, or "
                + "Task.detached — so it stopped before reading or opening anything."
                + "\nCall it from a Task started in setup()"
        }
        return "\(call) only works inside setup(), draw() or an input callback, because what it returns has "
            + "to join the running sketch, which can only happen there. It was called outside them — "
            + "from an initialiser, after the sketch ended, or from a Task — so it stopped before "
            + "reading or opening anything.\nCall it from setup()"
    }
}
