// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// MIDI 入力の出どころ。**実機も記録の再生も、同じ入れ物 (``MIDIInbox``) へ入れる**
/// ([ADR-0028] 決定 6・[ADR-0042] 決定 4 の「供給元を差し替えられる」)。
///
/// 入れ物から先 (``MIDIPort``) は出どころを知らない。だから記録の再生で回した検査が、実機のときの
/// 受け取りの正しさをそのまま固定する。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
protocol MIDISource: AnyObject {
    /// 始める。届いたメッセージと状態は `inbox` へ入れる。
    func start(into inbox: MIDIInbox)
    /// フレームごとに、取り出す前に呼ばれる。**実機は何もしない** (入力は向こうの都合で届く)。
    func pump(into inbox: MIDIInbox)
    /// 止める。
    func stop()
}

/// 実機の機材 1 台ぶんの出どころ。中身は係 (``MIDIHub``) の中継へ繋ぐことだけである。
final class DeviceSource: MIDISource {
    private let id: String
    private let hub: MIDIHub
    private weak var inbox: MIDIInbox?

    init(id: String, hub: MIDIHub) {
        self.id = id
        self.hub = hub
    }

    func start(into inbox: MIDIInbox) {
        self.inbox = inbox
        // 中継が、繋ぐ瞬間にコントロールチェンジの現在値を入れる (足し直しでも、外すときに捨てた分が戻る)
        hub.subscribe(inbox, to: id)
    }

    func pump(into inbox: MIDIInbox) {}

    func stop() {
        if let inbox { hub.unsubscribe(inbox, from: id) }
    }
}

/// 記録したメッセージの列を、フレームごとに 1 組ずつ入れる出どころ。**機材を使わない。**
///
/// どのメッセージが入るかはフレームの数え方だけで決まる (作ってから何番目のフレームか) ので、同じ列からは
/// 何度回しても同じメッセージが同じフレームに出る ([ADR-0028] 決定 7)。
///
/// **外して足し直しても、フレームの数え方は変わらない** (時刻どおり・[#3152])。外していた間もフレームは
/// 進んでいたものとして、足し直したときに列の位置をその数だけ進める (外していた間のものは届かない。ただし
/// 拍に関わるクロック・開始・停止・再開・曲の位置は、実機の中継が数え続けるのと同じく拍だけを進める)。
///
/// 実機と同じ入れ物を通す。`nil` (抜かれている) は実機が抜かれたときと同じ形で入れる。
///
/// [#3152]: https://github.com/mokume-metal/mokume/issues/3152
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
final class RecordedMIDISource: MIDISource {
    private let frames: [[MIDIMessage]?]
    private var next = 0
    private var stopped = false
    private var detached: DetachedFrames

    /// - Parameter owner: 外していた間に進んだフレームを数える持ち主。`nil` なら足し直しでも位置を進めない。
    init(frames: [[MIDIMessage]?], owner: (any Sketch)? = nil) {
        self.frames = frames
        detached = DetachedFrames(owner: owner)
    }

    func start(into inbox: MIDIInbox) {
        // 足し直し (``stop()`` の後の 2 度目) で戻る。列の位置は、外していた間に進んだフレームの数だけ進める
        stopped = false
        if !frames.isEmpty {
            // 外していた間に進んだフレームの、拍に関わるメッセージ (クロック・開始・停止・再開・曲の位置) は数える。
            // 実機は外している間も中継が数え続け、足し直すときに渡すので、記録も同じ拍になるようにする
            // (ほかのメッセージは、外していた間のものとして届かない)
            let skipped = detached.reopen()
            if skipped > 0 {
                inbox.advanceClock(through: (0..<skipped).flatMap { frames[(next + $0) % frames.count] ?? [] })
            }
            next = (next + skipped) % frames.count
        }
        inbox.setState(frames.isEmpty ? .unavailable : .running)
        // 外す前に読んだ現在値は、外したときに捨てた入れ物へ戻す (つまみは動いていない)
        inbox.resendControllers()
    }

    func pump(into inbox: MIDIInbox) {
        guard !frames.isEmpty, !stopped else { return }
        let frame = frames[next % frames.count]
        next += 1
        guard let frame else {
            if inbox.state != .disconnected { inbox.unplug() }
            return
        }
        inbox.setState(.running)
        for message in frame { inbox.receive(message) }
    }

    func stop() {
        stopped = true
        detached.close()
    }
}
