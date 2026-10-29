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
// 入力だけで、クロックの受けと出力 (ノートを送る・クロックを送る) は持たない。それは #1963 の続きで、作例と
// 一緒に足す ([ADR-0041] 決定 3)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// 繋がっている MIDI 機材の一覧。``createMIDI(_:)`` で 1 台を選ぶのに使う。初めて繋がった順に並ぶ。
    ///
    /// ```swift
    /// func setup() {
    ///     for device in midiDevices() { print(device.id, device.isConnected) }
    /// }
    /// ```
    ///
    /// - **抜いた機材も列に残る。** ``MIDIDevice/isConnected`` が `false` になり、挿し直せば `true` に戻る。
    ///   いま繋がっているものだけが要るなら `isConnected` で絞る
    /// - **毎回引き直す。** 起動した後に挿した機材も、OS が知らせた後に呼べば並ぶ
    /// - **呼んだときだけ見張り始める。** `import mokume` しただけでは、CoreMIDI に触れない
    /// - 他のアプリが作った仮想の入力 (IAC バスなど) も、機材と同じように並ぶ
    public func midiDevices() -> [MIDIDevice] {
        let hub = MIDIHub.shared
        hub.start()
        // 毎回引き直す。知らせを待つ間に挿された機材・繋げなかった機材も、呼ぶたびに繋ぎ直す
        hub.refresh()
        return hub.devices
    }

    /// 機材を 1 台選んで、その入力を受ける。届いたノートとコントロールチェンジは ``MIDIPort`` から読む。
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
    /// - **機材が繋がっていなくても作れる。** ``MIDIPort/state`` が ``SourceState/unavailable`` (その機材が一度も
    ///   繋がっていない) か ``SourceState/disconnected`` (抜かれた) になり、挿されたら受け始める
    /// - **1 台の機材に、複数の ``MIDIPort`` を作ってよい。** どれにも同じメッセージが届く
    /// - OS の許可は要らない
    ///
    /// 機材なしで確かめるときは、記録した列を ``createMIDI(messages:)`` で流す。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、
    /// 返る ``MIDIPort`` は走っているスケッチに足されず、何も届かない。この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter device: 使う機材 (``midiDevices()`` から選ぶ)。
    public func createMIDI(_ device: MIDIDevice) -> MIDIPort {
        let hub = MIDIHub.shared
        hub.start()
        let port = MIDIPort(
            id: device.id, name: "midi: \(device.id)", source: DeviceSource(id: device.id, hub: hub))
        attach(port, calledAs: #function, returning: "a MIDI port that never receives anything")
        return port
    }

    /// 記録したメッセージの列を、MIDI 機材から届いたかのように流す。**機材を使わない。**
    ///
    /// ``createMIDI(_:)`` で受けるスケッチを機材なしで回すときは、これに差し替える。`messages[i]` が、作ってから
    /// i 番目のフレームで ``MIDIPort/messages`` に入る。最後まで行けば最初に戻る。どのメッセージが入るかは
    /// フレームの数え方だけで決まるので、同じ列からは何度回しても同じメッセージが同じフレームに届く — 機材の
    /// 無い場所で確かめるときや、展示の前に空回しするときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// **外して足し直しても、i 番目のフレームには `messages[i]` が入る** (外していた間の分は届かない。時刻どおり・[#3152](https://github.com/mokume-metal/mokume/issues/3152))。
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
    /// 実機と同じ入れ物を通る — ノートとコントロールチェンジの出来事は落とさない列に、コントロールチェンジの現在値は
    /// 最新の 1 つに入る。`nil` のフレームは抜かれている (``MIDIPort/state`` が ``SourceState/disconnected`` になり、
    /// 押していたノートは離したことになる)。範囲に収まらないメッセージ (チャンネルが 1〜16 の外・値が 0〜127 の外)
    /// は「読めずに捨てた」と数える。
    ///
    /// `setup()`・`draw()`・入力のコールバックの外 (初期化子の中・後片付けの後・`Task` の中) で呼ぶと、走っている
    /// スケッチに足されず何も届かない ``MIDIPort`` を返し、この口の名前で 1 度だけ警告する。
    ///
    /// - Parameter messages: フレームごとに届くメッセージ。何も届かないフレームは空の並びにし、抜かれている
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
