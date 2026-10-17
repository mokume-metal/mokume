// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

// シリアル。**説明文の正本はこちら** ([ADR-0020] 決定 4)。
//
// 呼べば使える標準の機能である ([ADR-0041] の地図の「mokume の仕事 (標準)」)。`plugins` には
// 何も書かない — 作る口が、走っているスケッチへ自分で入り口を足す (``Sketch/attach(_:)-(Inlet)``)。
//
// 名前 ([ADR-0020] 決定 1): 型は手本 (Processing の `Serial`) のまま。一覧と作る口はカメラの口
// (`captureDevices()`・`createCapture`) に揃える — Processing では一覧が型に付いている
// (`Serial.list()`・`Capture.list()`) が、カメラも `captureDevices()` にした。読む値は、単位を
// 名乗る `lines` にする。シリアルはバイトの流れで「1 つのメッセージ」の単位を持たない。
//
// 設定はボーレートだけで、送る向き (`write`) は持たない ([ADR-0041] 決定 3 の例 — 「ボーレート
// 以外の設定や、送る向きの口をどこまで持つかは、作例と作品で踏んでから足す」)。
//
// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
// [ADR-0041]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0041-standard-scope-map.md
extension Sketch {

    /// 繋がっているシリアルポートの一覧。``createSerial(_:baudRate:)`` で 1 つを選ぶのに使う。
    ///
    /// ```swift
    /// func setup() {
    ///     for port in serialPorts() { print(port.id, port.name) }
    /// }
    /// ```
    ///
    /// **USB で繋いだもの (Arduino など) を先に並べる。** Mac 自身のポート
    /// (`/dev/cu.Bluetooth-Incoming-Port`・`/dev/cu.debug-console`) は後ろに来るので、USB で
    /// 1 台だけ挿していれば `serialPorts().first` がそれになる。どちらの組の中も
    /// ``SerialPort/id`` の順。
    ///
    /// Processing の `Serial.list()` に当たる。
    public func serialPorts() -> [SerialPort] {
        SerialPort.connected()
    }

    /// シリアルポートを開く。届いた行は ``Serial/lines`` から読む。
    ///
    /// ```swift
    /// final class Knob: Sketch {
    ///     var port: Serial?
    ///     var x: Float = 0
    ///     func setup() {
    ///         if let first = serialPorts().first { port = try? createSerial(first, baudRate: 9600) }
    ///     }
    ///     func draw() {
    ///         background(0)
    ///         for line in port?.lines ?? [] {
    ///             if let value = Float(line) { x = value / 1023 * width }
    ///         }
    ///         circle(x, height / 2, 60)
    ///         if port?.state == .disconnected { text("切断", 10, 20) }
    ///     }
    /// }
    /// ```
    ///
    /// Arduino には `Serial.begin(9600)` と `Serial.println(analogRead(A0))` を書き込んでおく。
    /// つまみを回すと円が左右に動き、USB を抜くと円が止まって「切断」と出る。
    ///
    /// - **呼んだときだけポートを開く。** `import mokume` しただけでポートが開くことはない
    /// - 8 ビット・パリティなし・ストップビット 1・流れ制御なしで開く (Arduino の `Serial.begin` の
    ///   既定と同じ)。変えられるのはボーレートだけ
    /// - **開いている間は、他のアプリはそのポートを開けない** (Arduino IDE の書き込みとシリアル
    ///   モニタも)。書き込む前に ``Serial/stop()`` するか、スケッチを止める。2 つのアプリが同じ
    ///   ポートを読むと、届いたバイト列が両方へ割れて、どちらにも欠けた行が届くからである
    /// - **ポートが繋がっていない・他のアプリが使っていても作れる。** ``Serial/state`` が
    ///   ``SourceState/unavailable`` になり、挿されたら・空けば受け始める (1 秒ごとに開き直す)。
    ///   抜かれたら ``SourceState/disconnected`` になり、挿し直せば戻る
    /// - OS の許可は要らない
    ///
    /// 機材なしで確かめるときは、記録した行を ``Sketch/createSerial(lines:)`` で流す。
    ///
    /// Processing の `new Serial(this, name, 9600)` に当たる。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中で呼ぶ。
    ///
    /// - Parameters:
    ///   - port: 使うポート (``serialPorts()`` から選ぶ)。
    ///   - baudRate: 1 秒に送るビットの数。相手が `Serial.begin` に渡した値と同じにする。
    /// - Throws: ボーレートが 1 より小さいとき。
    public func createSerial(_ port: SerialPort, baudRate: Int) throws(SerialFailure) -> Serial {
        guard baudRate >= 1 else { throw .invalidBaudRate(baudRate) }
        let serial = Serial(
            name: "serial: \(port.id)",
            source: SerialSource(path: port.id, baudRate: baudRate, warn: { Diagnostics.warn($0) }),
            owner: self)
        attach(serial)
        return serial
    }

    /// 記録した行の列を、シリアルポートから届いたかのように流す。**ポートを開かない。**
    ///
    /// ``Sketch/createSerial(_:baudRate:)`` で受けるスケッチを機材なしで回すときは、これに差し替える。
    /// `lines[i]` が、作ってから i 番目のフレームで ``Serial/lines`` に入る。最後まで行けば最初に
    /// 戻る。どの行が入るかはフレームの数え方だけで決まるので、同じ列からは何度回しても同じ行が
    /// 同じフレームに届く — 機材の無い場所で確かめるときや、展示の前に空回しするときに使う
    /// ([ADR-0028] 決定 6・7)。
    ///
    /// ```swift
    /// final class Replay: Sketch {
    ///     var port: Serial?
    ///     var x: Float = 0
    ///     func setup() {
    ///         // つまみを 1 秒かけて 0 から 1023 まで回したかのように流す
    ///         port = createSerial(lines: (0..<60).map { ["\($0 * 1023 / 59)"] })
    ///     }
    ///     func draw() {
    ///         background(0)
    ///         for line in port?.lines ?? [] {
    ///             if let value = Float(line) { x = value / 1023 * width }
    ///         }
    ///         circle(x, height / 2, 60)
    ///     }
    /// }
    /// ```
    ///
    /// ``Serial/state`` は ``SourceState/running`` のままで、抜かれることはない。
    ///
    /// - Parameter lines: フレームごとに届く行。何も届かないフレームは空の並びにする。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    public func createSerial(lines: [[String]]) -> Serial {
        let serial = Serial(
            name: "serial (recorded)", source: RecordedSource(batches: lines), owner: self)
        attach(serial)
        return serial
    }
}
