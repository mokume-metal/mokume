// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

// OSC。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0041] の地図の「連携の口 (標準)」)。`plugins` には何も
// 書かない — 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
//
// 名前は Issue の作例の綴りに合わせた。手本 (Processing / p5.js) の本体に OSC は無いので、
// Swift の慣行に従う ([ADR-0020] 決定 1)。`create…` は手本の作る口 (`createCapture`) と揃える。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// OSC を受けるポートを開く。届いたメッセージは ``OSCPort/messages`` から読み、
    /// ``OSCPort/send(_:_:)`` で `send` の宛先へ送る。
    ///
    /// ```swift
    /// final class Remote: Sketch {
    ///     var osc: OSCPort?
    ///     var size: Float = 0.5
    ///     func setup() { osc = try? createOSC(listen: 9000, send: ("127.0.0.1", 7000)) }
    ///     func draw() {
    ///         for message in osc?.messages ?? [] where message.address == "/size" {
    ///             size = message.float(0) ?? size
    ///         }
    ///         circle(width / 2, height / 2, size * height)
    ///     }
    ///     func mousePressed() { osc?.send("/hit", 1) }
    /// }
    /// ```
    ///
    /// - **呼んだときだけポートを開く。** `import mokume` しただけでポートが開くことはない
    /// - この機械のすべての口で受ける。別の機械の TouchDesigner や、携帯の TouchOSC からも届く
    /// - **ポートを他のアプリが使っていても作れる。** ``OSCPort/state`` が
    ///   ``SourceState/unavailable`` になり、空けば受け始める
    /// - 送り先を自分のポート (`("127.0.0.1", listen と同じ番号)`) にすれば、自分で送って自分で
    ///   受けられる。相手が居なくても動きを確かめられる
    /// - 束ねずに動かしている間は、受けるのに OS の許可は要らない。別の機械とやりとりするとき、
    ///   macOS がローカルネットワークの許可を求めることがある。受けるほうが拒まれていれば
    ///   ``OSCPort/state`` が ``SourceState/denied`` を名乗る
    /// - **送れないことは ``OSCPort/state`` に出ない。** 送れないとき (宛先で誰も受けていない・
    ///   このアプリにローカルネットワークの許可が無い・ネットワークが落ちている) は、1 度だけ
    ///   診断に出す
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameters:
    ///   - port: 受けるポート (1〜65535)。
    ///   - destination: 送り先のホストとポート。省けば送らない。
    /// - Throws: ポートの番号が 1〜65535 に入っていない・送り先のホストが空のとき。
    public func createOSC(
        listen port: Int, send destination: (host: String, port: Int)? = nil
    ) throws(OSCFailure) -> OSCPort {
        guard Endpoint.usablePorts.contains(port) else { throw .invalidPort(port) }
        var outbound: DatagramSender?
        if let destination {
            guard Endpoint.usablePorts.contains(destination.port) else {
                throw .invalidPort(destination.port)
            }
            guard Endpoint.isUsable(host: destination.host) else {
                throw .invalidHost(destination.host)
            }
            outbound = DatagramSender(
                host: destination.host, port: destination.port, warn: { Diagnostics.warn($0) })
        }
        let osc = OSCPort(
            port: port, name: "osc :\(port)",
            source: NetworkOSCSource(port: port, warn: { Diagnostics.warn($0) }),
            outbound: outbound, owner: self)
        attach(osc)
        return osc
    }

    /// 記録したメッセージの列を、受けたかのように流す。**ポートを開かない。**
    ///
    /// `messages[i]` が、作ってから i 番目のフレームで ``OSCPort/messages`` に入る。最後まで
    /// 行けば最初に戻る。どのメッセージが入るかはフレームの数え方だけで決まるので、同じ列からは
    /// 何度回しても同じメッセージが同じフレームに届く — OSC で動かすスケッチを相手なしで
    /// 確かめるときや、展示の前に空回しするときに使う ([ADR-0028] 決定 6・7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var osc: OSCPort?
    ///     var size: Float = 0.5
    ///     func setup() {
    ///         // 1 フレームごとに大きさを送ってきたかのように流す
    ///         osc = createOSC(messages: (0..<60).map { [OSCMessage("/size", Float($0) / 60)] })
    ///     }
    ///     func draw() {
    ///         for message in osc?.messages ?? [] where message.address == "/size" {
    ///             size = message.float(0) ?? size
    ///         }
    ///         circle(width / 2, height / 2, size * height)
    ///     }
    /// }
    /// ```
    ///
    /// 送り先は持たない。``OSCPort/send(_:_:)`` を呼んでも何も出ない (1 度だけ知らせる)。
    ///
    /// - Parameter messages: フレームごとに届くメッセージ。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createOSC(messages: [[OSCMessage]]) -> OSCPort {
        let osc = OSCPort(
            port: nil, name: "osc (recorded)", source: RecordedSource(batches: messages),
            outbound: nil, owner: self)
        attach(osc)
        return osc
    }
}
