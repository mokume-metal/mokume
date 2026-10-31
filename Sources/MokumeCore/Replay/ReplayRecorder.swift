// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import MokumeDiagnostics

/// フレームの時計のスケッチの実行を、頭から終わりまで 1 本のファイルにする係 ([#3570])。
///
/// ## 何を残すか (ADR-0045 決定 10)
///
/// 同じ機械で、何フレーム目の絵もバイト単位で一致させるのに要るもの — 開始の状態 (乱数の種・開始時の
/// `@Param`・作者の時計の開始の秒と止めているか) と、`advance()` 1 回ごとの入力の束・つまみの変更・時刻を
/// 指定した観測。加えて、記録を流した側が照らす値として、毎フレームの `expose` の値と、60 フレームごと
/// + 最後の 1 枚の画素のハッシュを残す。
///
/// ## 記録の単位は `advance()` の 1 回
///
/// 入力は ``InputState`` の `beginFrame` 1 回ぶんの束で持ち、**同じフレーム番号の束を畳まない**。`beginFrame` は
/// 呼ぶたびに `scrollY`・`dragX` ほかを 0 に戻し、`noLoop()` で止めた作品は回ごとに束を配るので、2 つの束を
/// 畳むと流したときに量が変わる。回には通し番号 (`step`) を付け、何も起きなかった止めた回は載せない (番号の欠けで表す)。
///
/// 入力は `InputState.enqueue` に入った時点の**生の形**で、注入の道と同じ `wireLine` の 1 行を JSON の
/// 値としてそのまま載せる (2026-10-23 の決定)。当てる前の姿なので、溢れて先に当てた 1 件も、和が溢れて
/// 捨てる 1 件も落とさない — 捨てる判定は流す側でも同じ層で起きる。
///
/// ## 終わり方
///
/// 書き途中は `<行き先>.partial` で、``finish(last:)`` が `"complete": true` を書き、閉じてから行き先へ
/// 改名する。**落ちた回は `.partial` のまま残り、行き先は作られない** — 完成として読まれない。
/// 開始の時点で、前の回が同じ行き先に残した完成品は消す (今回の回が落ちたとき、古い完成品を今回のものと
/// 取り違えない)。
///
/// ## 形は足せる向きにだけ変える
///
/// 版は ``schemaVersion``。外から届くメッセージの欄 (`frame`・`time`) など、後の段が足す欄は、未知の鍵として
/// 読み飛ばせる形にしてある (`Schemas/replay-record.schema.json`)。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
final class ReplayRecorder {
    /// 記録の書式の版。
    static let schemaVersion = 1
    /// 画素のハッシュを取るフレーム番号の間隔。**そのフレーム番号が 60 の倍数のとき**に取る。
    static let hashInterval = 60
    /// 書き途中のファイルの名前の末尾。
    static let partialSuffix = ".partial"
    /// 1 回の束に溜める入力の上限。**越えたら残りは載せず、再現を保証しないと書く。**
    private static let pendingInputLimit = 65_536
    /// 理由の文面 (記録に書く・英語)。
    enum Reason {
        static let nonFiniteInput = "Replay is not guaranteed (non-finite input)"
        static let tooManyInputs = "Replay is not guaranteed (too many inputs between two frames)"
    }

    /// 記録の識別子。**この記録を指す** (#2618 の観測 1 枚と条件の組)。
    let id: String
    /// 記録の行き先。
    let destination: URL
    /// 書き途中のファイル。
    let partial: URL

    private var handle: FileHandle?
    private var buffer = ""
    private var failed = false
    private(set) var isFinished = false
    private var wroteHeader = false
    private var stepsWritten = 0
    private var stepsSinceFlush = 0

    private var start: Start?
    private var startClock: (seconds: Double, paused: Bool)?
    private var pendingInputs: [String] = []
    private var pendingParams: [NamedParamValue] = []
    private var pendingObserveTime: Float?
    private var exposed: [String: ExposedValue] = [:]
    private var notes: [Note] = []
    private var openStep: Open?
    private var nextOrdinal = 0

    /// 開始の状態。
    private struct Start {
        var seed: Int
        var params: [NamedParamValue]
        var frameRate: Int
        var width: Int
        var height: Int
    }

    /// 1 回の `advance()` が、入力を配った時点で持ち込んだもの。
    private struct Open {
        var ordinal: Int
        var inputs: [String]
        var params: [NamedParamValue]
        var observeTime: Float?
    }

    /// 再現を保証しない理由 1 件。
    private struct Note {
        var step: Int
        var reason: String
    }

    /// 開く。**書き途中のファイルを作れなければ `nil`** で、理由を `failure` に載せる。
    ///
    /// 行き先の親が無ければ作る。行き先が既に在るファイルなら、先に消す (上の「終わり方」)。
    static func open(destination: URL) -> (recorder: ReplayRecorder?, failure: String?) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        if manager.fileExists(atPath: destination.path, isDirectory: &isDirectory) {
            guard !isDirectory.boolValue else {
                return (nil, "\(destination.path) is a directory, not a file")
            }
            do { try manager.removeItem(at: destination) } catch {
                return (nil, "Could not replace \(destination.path): \(Diagnostics.reason(error))")
            }
        }
        let partial = URL(fileURLWithPath: destination.path + partialSuffix)
        do {
            try manager.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard manager.createFile(atPath: partial.path, contents: nil) else {
                return (nil, "Could not create \(partial.path)")
            }
            let handle = try FileHandle(forWritingTo: partial)
            return (ReplayRecorder(destination: destination, partial: partial, handle: handle), nil)
        } catch {
            return (nil, "Could not open \(partial.path): \(Diagnostics.reason(error))")
        }
    }

    private init(destination: URL, partial: URL, handle: FileHandle) {
        self.id = UUID().uuidString.lowercased()
        self.destination = destination
        self.partial = partial
        self.handle = handle
    }

    // MARK: - 開始の状態

    /// 開始の状態を控える。**`setup()` の前に呼ぶ** — 保存から戻した `@Param` の値を含む。
    ///
    /// 乱数の種は、作者が `randomSeed` を呼ぶまで常に 0 (`Randomness()`) なので、開始の種は 0 である。
    func noteStart(seed: Int, params: [NamedParamValue], frameRate: Int, width: Int, height: Int) {
        start = Start(seed: seed, params: params, frameRate: frameRate, width: width, height: height)
    }

    /// 最初の枚が実際に使った、作者の時計の開始の秒と止めているか。**1 度だけ。**
    func noteStartClock(seconds: Double, paused: Bool) {
        guard startClock == nil else { return }
        startClock = (seconds, paused)
    }

    // MARK: - 溜める

    /// 入力の出来事が `InputState.enqueue` に入った。
    func noteInput(_ event: InputEvent) {
        guard !isFinished, !failed else { return }
        if pendingInputs.count >= Self.pendingInputLimit {
            noteUnreproducible(Self.Reason.tooManyInputs)
            return
        }
        // 1 行の末尾の改行は JSON の値に要らない
        var line = event.wireLine
        if line.hasSuffix("\n") { line.removeLast() }
        pendingInputs.append(line)
        if event.hasNonFiniteNumber { noteUnreproducible(Self.Reason.nonFiniteInput) }
    }

    /// 外から来た `@Param` の書き込みが入った (窓のつまみ・区画)。**収めた後の値**を残す。
    func noteParam(_ name: String, _ value: ParamValue) {
        guard !isFinished, !failed else { return }
        pendingParams.append(NamedParamValue(name: name, value: value))
    }

    /// 時刻を指定した観測の枚を描く。
    func noteTimedObservation(_ time: Float) {
        guard !isFinished, !failed else { return }
        pendingObserveTime = time
    }

    /// `expose` された値。同じ名前は後のものが勝つ。
    func noteExposed(_ name: String, _ value: ExposedValue) {
        guard !isFinished, !failed else { return }
        exposed[name] = value
    }

    /// フレームの頭で、差し出された値を捨てる (観測の `exposedValues` と同じ位置)。
    func clearExposed() { exposed.removeAll(keepingCapacity: true) }

    /// 再現を保証しないものが使われた。**同じ理由は 1 度だけ書く。**
    func noteUnreproducible(_ reason: String) {
        guard !isFinished, !failed, !notes.contains(where: { $0.reason == reason }) else { return }
        notes.append(Note(step: openStep?.ordinal ?? nextOrdinal, reason: reason))
        Diagnostics.warn("Recording: \(reason). The record says so")
    }

    // MARK: - 回

    /// 入力の束を配る回が始まった。**溜めたものをこの回へ持ち込む。** 1 回の `advance()` で 1 度だけ。
    func beginStep() {
        guard !isFinished, !failed, openStep == nil else { return }
        openStep = Open(
            ordinal: nextOrdinal, inputs: pendingInputs, params: pendingParams,
            observeTime: pendingObserveTime)
        nextOrdinal += 1
        pendingInputs.removeAll(keepingCapacity: true)
        pendingParams.removeAll(keepingCapacity: true)
        pendingObserveTime = nil
    }

    /// 回が終わった。何も起きなかった止めた回は載せない。
    ///
    /// - Parameters:
    ///   - frame: その回の終わりのフレーム番号。
    ///   - drew: フレームを描いたか。
    ///   - hash: 画素のハッシュ。**描いた回で、フレーム番号が間隔の倍数のときだけ呼ぶ。**
    func endStep(frame: Int, drew: Bool, hash: () -> String?) {
        guard let step = openStep else { return }
        openStep = nil
        let values = exposed
        exposed.removeAll(keepingCapacity: true)
        guard !isFinished, !failed else { return }
        let hasContent =
            drew || !step.inputs.isEmpty || !step.params.isEmpty || step.observeTime != nil
            || !values.isEmpty
        guard hasContent else { return }
        var line = "{\"step\":\(step.ordinal),\"frame\":\(frame),\"drew\":\(drew)"
        if !step.inputs.isEmpty { line += ",\"inputs\":[" + step.inputs.joined(separator: ",") + "]" }
        if !step.params.isEmpty { line += ",\"params\":" + Self.json(step.params) }
        if let time = step.observeTime { line += ",\"observe\":{\"time\":" + Self.json(Double(time)) + "}" }
        if !values.isEmpty { line += ",\"expose\":" + Self.json(values) }
        if drew, frame % Self.hashInterval == 0, let hash = hash() {
            line += ",\"pixelHash\":" + Self.json(hash)
        }
        line += "}"
        writeHeaderIfNeeded()
        buffer += (stepsWritten == 0 ? "" : ",") + line
        stepsWritten += 1
        stepsSinceFlush += 1
        if stepsSinceFlush >= Self.hashInterval || buffer.utf8.count > 32_768 { flush() }
    }

    // MARK: - 終わり

    /// 最後まで書いて閉じ、行き先へ改名する。**2 度目からは何もしない。**
    ///
    /// - Parameter last: 最後に描いたフレームの番号と画素のハッシュ。1 枚も描いていなければ `nil`。
    func finish(last: (frame: Int, hash: String)?) {
        guard !isFinished else { return }
        isFinished = true
        guard !failed else { return }
        writeHeaderIfNeeded()
        buffer += "]"
        if !notes.isEmpty {
            let items = notes.map { "{\"step\":\($0.step),\"reason\":\(Self.json($0.reason))}" }
            buffer += ",\"unreproducible\":[" + items.joined(separator: ",") + "]"
        }
        if let last {
            buffer += ",\"last\":{\"frame\":\(last.frame),\"pixelHash\":\(Self.json(last.hash))}"
        }
        buffer += ",\"complete\":true}\n"
        flush()
        guard !failed, let handle else { return }
        do {
            try handle.close()
            self.handle = nil
            guard rename(partial.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            fail("Could not finish \(destination.path): \(Diagnostics.reason(error))")
        }
    }

    // MARK: - 書く

    private func writeHeaderIfNeeded() {
        guard !wroteHeader else { return }
        wroteHeader = true
        let start =
            start ?? Start(seed: 0, params: [], frameRate: 0, width: 0, height: 0)
        let clock = startClock ?? (0, false)
        buffer += "{\"schemaVersion\":\(Self.schemaVersion),\"id\":\(Self.json(id))"
        buffer += ",\"clock\":{\"kind\":\"frames\",\"frameRate\":\(start.frameRate)}"
        buffer += ",\"size\":{\"width\":\(start.width),\"height\":\(start.height)}"
        buffer += ",\"start\":{\"seed\":\(start.seed),\"seconds\":\(Self.json(clock.seconds))"
        buffer += ",\"paused\":\(clock.paused),\"params\":\(Self.json(start.params))}"
        buffer += ",\"steps\":["
    }

    private func flush() {
        stepsSinceFlush = 0
        guard !buffer.isEmpty, let handle, !failed else { return }
        do {
            try handle.write(contentsOf: Data(buffer.utf8))
            buffer.removeAll(keepingCapacity: true)
        } catch {
            fail("Could not write \(partial.path): \(Diagnostics.reason(error))")
        }
    }

    /// 書けなくなった。**1 度だけ言い、以後は何も書かない。** 書き途中のファイルは完成として読まれない形で残る。
    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        buffer.removeAll()
        try? handle?.close()
        handle = nil
        Diagnostics.warn("Recording stopped: \(message). The record is left unfinished at \(partial.path)")
    }

    /// 値を JSON にする。**キーを並べ直して、同じ値から同じ文字を出す。**
    private static func json<Value: Encodable>(_ value: Value) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    /// 画素のバイト列のハッシュ (SHA-256・16 進)。**出口が受け取るのと同じ道の絵**(``DisplayImage``) を渡す。
    static func hash(of image: DisplayImage) -> String {
        SHA256.hash(data: image.bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension InputEvent {
    /// 数のどれかが有限でないか。**線は有限でない数を 0 で書く** (``wireLine``) ので、記録の中で 0 になり、
    /// 流すと食い違う — 記録は「再現を保証しない」と理由を書く。
    var hasNonFiniteNumber: Bool {
        switch self {
        case .mouseDown(let x, let y, _, _), .mouseUp(let x, let y, _), .mouseMoved(let x, let y):
            !x.isFinite || !y.isFinite
        case .mouseMovedBy(let dx, let dy), .scrolled(let dx, let dy):
            !dx.isFinite || !dy.isFinite
        case .pinched(let amount):
            !amount.isFinite
        case .fileDropped(_, let x, let y):
            !x.isFinite || !y.isFinite
        case .fileSelected, .keyDown, .keyUp:
            false
        }
    }
}
