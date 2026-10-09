// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// シリアルポートから行を受ける入り口。``Sketch/createSerial(_:baudRate:)`` が作り、走っている
/// スケッチへ足す。
///
/// 毎フレーム呼ぶ口は無い。`draw()` の前に、前のフレームの後に届いた行が**全部**、届いた順に
/// ``lines`` へ入っている ([ADR-0024] 決定 6)。最新の 1 つだけではないので、1 フレームの間に
/// 何行届いても取りこぼさない ([ADR-0028] 決定 2 の「落とさない列」)。
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
/// つまみを回すと円が左右に動き、USB を抜くと円が止まって「切断」と出る。挿し直せば、また動く。
///
/// **Processing の `Serial` (`processing.serial`) に当たる。** 受けたものは、Processing の
/// `readStringUntil('\n')` / `bufferUntil` で引き出す形ではなく、フレームごとに ``lines`` で読む
/// ([ADR-0010] 決定 5 — 取りこぼすと意味が変わる出来事の列は、落とさない列に溜めてフレームで読む)。
/// 送る向き (Processing の `write`) は持たない。
///
/// ## 1 行
///
/// 改行 (`\n`) で切った 1 行が 1 つの文字列になる。`Serial.println` が送る `\r\n` の `\r` は落とす
/// ので、`"512"` がそのまま `Float(line)` で読める。決まりは TCP の行 (``TCPServer``) と同じで、
/// UTF-8 として読めない行と 64 KiB を超える行は捨てて数え、溜めきれずに捨てた数 (1 フレームに
/// 4096 行を超えて届いたとき) と合わせて、次のフレームで診断に出す。
///
/// - 開いた時点で相手が行の途中を送っていれば、最初の 1 行は途中から始まる。多くの Arduino は
///   開かれるとリセットされて始めから送るので、起きない
/// - 行の途中で抜かれたら、その残りは渡さずに、読めなかった数に入れる。途中で切れた値
///   (`"1023"` の `"10"`) を黙って別の数として渡さないためである
///
/// ## 来ないことには理由がある
///
/// 届かないとき、``state`` がその理由を名乗る。観測の応答の `inputs` にも同じものが載る
/// ([ADR-0028] 決定 4)。OS の許可は要らない。
///
/// | 状態 | いつ |
/// | --- | --- |
/// | ``SourceState/running`` | 受けている |
/// | ``SourceState/unavailable`` | 開く途中か、ポートが繋がっていないか、他のアプリ (Arduino IDE のシリアルモニタなど) が使っている。挿されたら・空けば受け始める |
/// | ``SourceState/disconnected`` | 受けていたポートが抜かれた。挿し直せば受け始める |
/// | ``SourceState/stopped`` | ``stop()`` した |
///
/// 繋がっていない・使用中・開けないときは、理由ごとに 1 度だけ診断に出す。受け始めたら、
/// また言えるように戻る。**機材がボーレートを受け付けないときだけは、開き直さない** — 開くたびに
/// 多くの Arduino がリセットされるからである。速さを直して、スケッチを始め直す。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public final class Serial: Inlet {
    /// このフレームの前に届いた行。届いた順。何も届いていなければ空。
    public private(set) var lines: [String] = []

    let input: ExternalQueue<String>
    let source: any MessageSource<String>
    private weak var owner: (any Sketch)?

    /// - Parameters:
    ///   - input: 列。検査が知らせの行き先を差し替えるときに渡す。省けば `name` で作る。
    init(
        name: String, source: any MessageSource<String>, owner: (any Sketch)?,
        input: ExternalQueue<String>? = nil
    ) {
        self.source = source
        self.owner = owner
        self.input = input ?? ExternalQueue(name: name, state: .unavailable)
    }

    /// 出どころの状態。
    public var state: SourceState { input.state }
    /// 最後に行が届いたフレーム。まだ 1 行も届いていなければ `nil`。
    public var lastArrival: Arrival? { input.lastArrival }

    /// 止める。ポートを閉じ、以後 ``lines`` は空のまま。閉じたポートは、他のアプリ (Arduino IDE の
    /// 書き込みなど) が開けるようになる。
    ///
    /// `setup()`・`draw()`・入力のコールバックの中から呼ぶ (``Sketch/detach(_:)-(Inlet)`` と同じ)。
    public func stop() {
        owner?.detach(self)
    }

    // MARK: - Inlet

    public func open() throws {
        source.start(into: input)
    }

    public func supply() {
        source.pump(into: input)
        lines = input.take()
    }

    public func close() {
        source.stop()
        input.setState(.stopped)
        lines = []
    }

    public var report: SourceReport? { input.report }
}
