// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

// MIDI の入力。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0041] の地図の「連携の口 (標準)」)。`plugins` には何も書かない —
// 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
//
// 名前 ([ADR-0020] 決定 1): 手本 (Processing の The MidiBus・p5 の WebMIDI) の本体に MIDI は無いので、
// 一覧と作る口はカメラ・シリアルの口 (`captureDevices()`・`serialPorts()`・`createSerial`) に揃える。
// 記録を流す口の `messages:` は、通信の `createOSC(messages:)` と揃える。
//
// 入力 (ノート・コントロールチェンジ・拍を数えるクロックの受け) だけで、出力 (ノートを送る・クロックを送る) は
// 持たない。それは #1963 の続きで、作例と一緒に足す ([ADR-0041] 決定 3)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// 接続されている MIDI デバイスの一覧。``createMIDI(_:)`` で 1 台を選ぶのに使う。初めて接続された順に並ぶ。
    ///
    /// ```swift
    /// func setup() {
    ///     for device in midiDevices() { print(device.id, device.isConnected) }
    /// }
    /// ```
    ///
    /// - **切断したデバイスも列に残る。** ``MIDIDevice/isConnected`` が `false` になり、再接続すれば `true` に戻る。
    ///   いま接続されているものだけが要るなら `isConnected` で絞る
    /// - **毎回引き直す。** 起動した後に接続したデバイスも、OS が通知した後に呼べば並ぶ
    /// - **呼んだときだけ監視を始める。** `import mokume` しただけでは、CoreMIDI に触れない
    /// - 他のアプリが作った仮想の入力 (IAC バスなど) も、デバイスと同じように並ぶ
    public func midiDevices() -> [MIDIDevice] {
        let hub = MIDIHub.shared
        hub.start()
        // 毎回引き直す。知らせを待つ間に挿された機材・繋げなかった機材も、呼ぶたびに繋ぎ直す
        hub.refresh()
        return hub.devices
    }

    /// デバイスを 1 台選んで、その入力を受け取る。届いたノートとコントロールチェンジは ``MIDIPort`` から読む。
    ///
    /// ```swift
    /// final class Knob: Sketch {
    ///     var midi: MIDIPort?
    ///     func setup() {
    ///         if let first = midiDevices().first { midi = createMIDI(first) }
    ///     }
    ///     func draw() {
    ///         background(0)
    ///         // 1 番のつまみを回すと、円の色相が回る
    ///         fill(color(hue: (midi?.controlChange(1) ?? 0) * 360, saturation: 90, brightness: 100))
    ///         circle(width / 2, height / 2, 200)
    ///         if midi?.state == .disconnected { text("切断", 10, 20) }
    ///     }
    /// }
    /// ```
    ///
    /// - **デバイスが接続されていなくても作れる。** ``MIDIPort/state`` が ``SourceState/unavailable`` (そのデバイスが一度も
    ///   接続されていない) か ``SourceState/disconnected`` (切断された) になり、接続されたら受け取り始める
    /// - **1 台のデバイスに、複数の ``MIDIPort`` を作ってよい。** どれにも同じメッセージが届く
    /// - OS の許可は要らない
    ///
    /// デバイスなしで確かめるときは、記録した列を ``createMIDI(messages:)`` で流す。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと、
    /// 返る ``MIDIPort`` は実行中のスケッチに追加されず、何も届かない。この API の名前で 1 度だけ警告する。
    ///
    /// - Parameter device: 使うデバイス (``midiDevices()`` から選ぶ)。
    public func createMIDI(_ device: MIDIDevice) -> MIDIPort {
        let hub = MIDIHub.shared
        hub.start()
        let port = MIDIPort(
            id: device.id, name: "midi: \(device.id)", source: DeviceSource(id: device.id, hub: hub))
        attach(port, calledAs: #function, returning: "a MIDI port that never receives anything")
        return port
    }

    /// 記録したメッセージの列を、MIDI デバイスから届いたかのように流す。**デバイスを使わない。**
    ///
    /// ``createMIDI(_:)`` で受け取るスケッチをデバイスなしで回すときは、これに差し替える。`messages[i]` が、作ってから
    /// i 番目のフレームで ``MIDIPort/messages`` に入る。最後まで行けば最初に戻る。どのメッセージが入るかは
    /// フレームの数え方だけで決まるので、同じ列からは何度回しても同じメッセージが同じフレームに届く — デバイスの
    /// 無い場所で確かめるときや、展示の前にリハーサルするときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// **取り外して追加し直しても、i 番目のフレームには `messages[i]` が入る** (取り外していた間の分は届かない。時刻どおり・[#3152](https://github.com/mokume-metal/mokume/issues/3152))。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var midi: MIDIPort?
    ///     func setup() {
    ///         // つまみ 1 番を、1 秒かけて 0 から 127 まで回したかのように流す
    ///         midi = createMIDI(messages: (0..<60).map { frame in
    ///             [.controlChange(channel: 1, controller: 1, value: frame * 127 / 59)]
    ///         })
    ///     }
    ///     func draw() {
    ///         background(0)
    ///         fill(color(hue: (midi?.controlChange(1) ?? 0) * 360, saturation: 90, brightness: 100))
    ///         circle(width / 2, height / 2, 200)
    ///     }
    /// }
    /// ```
    ///
    /// クロック・開始・停止・再開・曲の位置 (``MIDIMessage``) も同じ列に書ける。``MIDIPort/beat`` が 24 クロックで 1 ビートに
    /// 数え、テンポは書いたクロックの間隔がそのまま決める (クロックは ``MIDIPort/messages`` に入らない)。
    ///
    /// ```swift
    /// // 開始の後、1 フレームに 1 クロック。24 フレームごとにビートが 1 つ進む
    /// let clocks: [[MIDIMessage]?] = [[.start]] + Array(repeating: [.clock], count: 71)
    /// ```
    ///
    /// 実機と同じ経路を通る — ノートとコントロールチェンジのイベントは取りこぼさない列 (`ExternalQueue`) に、コントロールチェンジの現在値と
    /// 数えたビートは最新の 1 つに入る。`nil` のフレームは切断されている (``MIDIPort/state`` が ``SourceState/disconnected`` になり、
    /// 押していたノートは離したことになる)。範囲に収まらないメッセージ (チャンネルが 1〜16 の外・値が 0〜127 の外)
    /// は「読めなかったもの」として数える。
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・終了処理の後・`Task` の中) で呼ぶと、実行中の
    /// スケッチに追加されず何も届かない ``MIDIPort`` を返し、この API の名前で 1 度だけ警告する。
    ///
    /// - Parameter messages: フレームごとに届くメッセージ。何も届かないフレームは空の並びにし、切断されている
    ///   フレームは `nil`。空の列なら ``MIDIPort/state`` が ``SourceState/unavailable`` のまま何も入らない。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createMIDI(messages: [[MIDIMessage]?]) -> MIDIPort {
        let port = MIDIPort(
            id: "recorded", name: "midi (recorded)",
            source: RecordedMIDISource(frames: messages, owner: self))
        attach(port, calledAs: #function, returning: "a MIDI port that never receives anything")
        return port
    }
}
