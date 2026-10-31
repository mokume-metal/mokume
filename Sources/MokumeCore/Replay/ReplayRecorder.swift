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
/// 書き途中は `<行き先>.<プロセス番号>.partial` で、``finish(last:)`` が `"complete": true` を書き、同期
/// (`fsync`) して閉じてから行き先へ改名する (電源が落ちても、改名した後の完成品が空にならない)。
/// **落ちた回は `.partial` のまま残り、行き先は作られない** — 完成として読まれない。`setup()` が投げて
/// 終わった実行も完成と呼ばない (``abandon(because:)``)。
///
/// 同じ行き先へ書く実行は、行き先の隣の錠 (`<行き先>.lock`・``ReplayClaim``) で 1 つに絞る。取れなければ
/// 記録を始めない。錠を取った実行は、前の回が同じ行き先に残した完成品と `.partial` を消す (今回の回が
/// 落ちたとき、古い完成品を今回のものと取り違えない)。**消すのは、実時間の時計で記録を始めない回も同じ**
/// (``ReplayClaim/discardPrevious()``)。
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
    static let partialSuffix = ReplayClaim.partialSuffix
    /// 1 回の束に溜める入力の上限。**越えたら残りは載せず、再現を保証しないと書く。**
    private static let pendingInputLimit = 65_536
    /// 理由の文面 (記録に書く・英語)。
    ///
    /// 「再現を保証しない」ものは、記録の `unreproducible` に**種類ごとに 1 度**書く。保証の外にあるものを使った
    /// 実行が、黙って保証の内と名乗らないために、使われた時点でここへ書く。
    enum Reason {
        static let nonFiniteInput = "Replay is not guaranteed (non-finite input)"
        static let tooManyInputs = "Replay is not guaranteed (too many inputs between two frames)"
        /// ファイルのドロップと `selectInput`。パスだけを持ち、中身は持たない (`WebFile` の取得も同じ)。
        static let fileByPath =
            "Replay is not guaranteed (a dropped or chosen file is recorded by its path, not its contents)"
        static let webFile =
            "Replay is not guaranteed (a file fetched from a URL is not recorded, and its contents can change)"
        /// 画素のハッシュを取るために絵を読み戻せなかった。その枚は照らせない。
        static let pictureUnreadable =
            "Replay cannot be checked against every picture (a picture could not be read back to hash it)"
        static let drawFailed = "Replay is not guaranteed (a frame failed to draw)"
        /// 外から値が届く入り口 (ゲームパッド・MIDI・OSC / TCP / UDP / WebSocket・シリアル・マイク・カメラ) を足した。
        /// この段の記録は、入り口の値を持たない (#2603 の後段)。
        static func outsideInput(_ name: String) -> String {
            "Replay is not guaranteed (input from outside the sketch, which the record does not hold: \(name))"
        }
        /// 窓では音が実時間で鳴り、窓なしで流すときは数で進む。音の解析値を絵に使う作品は割れうる。
        static func realtimeSound(_ kind: String) -> String {
            "Replay is not guaranteed (sound plays in real time in a window, and counts frames when replayed: \(kind))"
        }
    }

    /// 記録の識別子。**この記録を指す** (#2618 の観測 1 枚と条件の組)。
    let id: String
    /// 記録の行き先。
    let destination: URL
    /// 書き途中のファイル (`<行き先>.<プロセス番号>.partial`)。
    let partial: URL

    /// 行き先の錠。閉じる (終わり・書けなくなった・手放す) まで握る。
    private var claim: ReplayClaim?
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
        /// 窓に出しながら回したか。
        var window: Bool
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

    /// 錠を取り、前の回の残りを消して、開く。**開けなければ `nil`** で、理由を `failure` に載せる。
    static func open(destination: URL) -> (recorder: ReplayRecorder?, failure: String?) {
        let taken = ReplayClaim.take(destination: destination)
        guard let claim = taken.claim else { return (nil, taken.failure) }
        if let failure = claim.discardPrevious() { return (nil, failure) }
        return open(claim: claim)
    }

    /// 取った錠のもとで、書き途中のファイルを作る。**錠は記録が握り、終わりで手放す。**
    static func open(claim: ReplayClaim) -> (recorder: ReplayRecorder?, failure: String?) {
        let partial = URL(
            fileURLWithPath: claim.destination.path + ".\(getpid())" + partialSuffix)
        do {
            guard FileManager.default.createFile(atPath: partial.path, contents: nil) else {
                return (nil, "Could not create \(partial.path)")
            }
            let handle = try FileHandle(forWritingTo: partial)
            return (ReplayRecorder(claim: claim, partial: partial, handle: handle), nil)
        } catch {
            return (nil, "Could not open \(partial.path): \(Diagnostics.reason(error))")
        }
    }

    private init(claim: ReplayClaim, partial: URL, handle: FileHandle) {
        self.id = UUID().uuidString.lowercased()
        self.destination = claim.destination
        self.partial = partial
        self.claim = claim
        self.handle = handle
    }

    // MARK: - 開始の状態

    /// 開始の状態を控える。**`setup()` の前に呼ぶ** — 保存から戻した `@Param` の値を含む。
    ///
    /// 乱数の種は、作者が `randomSeed` を呼ぶまで常に 0 (`Randomness()`) なので、開始の種は 0 である。
    ///
    /// `window` は、窓に出しながら回したか。窓では音が実時間で鳴り、拡大した字の焼きを次のフレームへ送る経路も
    /// 窓のものなので、流す側が「窓で録った記録」と知っておくために残す。
    func noteStart(
        seed: Int, params: [NamedParamValue], frameRate: Int, width: Int, height: Int, window: Bool = false
    ) {
        start = Start(
            seed: seed, params: params, frameRate: frameRate, width: width, height: height, window: window)
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
        // 届いたパスの先の中身は持たない。届いた回に名乗る
        if event.carriesAFileByPath { noteUnreproducible(Self.Reason.fileByPath) }
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
    ///   - drew: フレームを**描けたか**。描けなかった枚 (止めた作品の回・描くのに失敗した枚) は偽で、ハッシュを取らない。
    ///   - drawFailed: 描こうとして失敗した枚か (`drew` は偽)。再現を保証しないと書く。
    ///   - hash: 画素のハッシュ。**描いた回で、フレーム番号が間隔の倍数のときだけ呼ぶ。** 読み戻せなければ
    ///     `nil` を返し、その枚は照らせないと記録に書く。
    func endStep(frame: Int, drew: Bool, drawFailed: Bool = false, hash: () -> String?) {
        guard let step = openStep else { return }
        openStep = nil
        let values = exposed
        exposed.removeAll(keepingCapacity: true)
        guard !isFinished, !failed else { return }
        let hasContent =
            drew || drawFailed || !step.inputs.isEmpty || !step.params.isEmpty || step.observeTime != nil
            || !values.isEmpty
        guard hasContent else { return }
        if drawFailed { noteUnreproducible(Self.Reason.drawFailed) }
        var line = "{\"step\":\(step.ordinal),\"frame\":\(frame),\"drew\":\(drew)"
        if !step.inputs.isEmpty { line += ",\"inputs\":[" + step.inputs.joined(separator: ",") + "]" }
        if !step.params.isEmpty {
            guard let json = encode(step.params) else { return }
            line += ",\"params\":" + json
        }
        if let time = step.observeTime {
            guard let json = encode(Double(time)) else { return }
            line += ",\"observe\":{\"time\":" + json + "}"
        }
        if !values.isEmpty {
            guard let json = encode(values) else { return }
            line += ",\"expose\":" + json
        }
        if drew, frame % Self.hashInterval == 0 {
            if let hash = hash(), let json = encode(hash) {
                line += ",\"pixelHash\":" + json
            } else if !failed {
                // 読み戻せなかった枚は、欠けたまま黙らない
                noteUnreproducible(Self.Reason.pictureUnreadable)
            }
        }
        line += "}"
        writeHeaderIfNeeded()
        guard !failed else { return }
        buffer += (stepsWritten == 0 ? "" : ",") + line
        stepsWritten += 1
        stepsSinceFlush += 1
        if stepsSinceFlush >= Self.hashInterval || buffer.utf8.count > 32_768 { flush() }
    }

    // MARK: - 終わり

    /// 最後まで書いて閉じ、行き先へ改名する。**2 度目からは何もしない。**
    ///
    /// 閉じる前に同期する (`fsync`)。改名の後に電源が落ちても、行き先が空のまま残らない。
    ///
    /// - Parameter last: 最後に描いたフレームの番号と画素のハッシュ。1 枚も描いていなければ `nil`。
    ///   描いたのに読み戻せなかった枚は ``noteUnreproducible(_:)`` で名乗ってから呼ぶ。
    func finish(last: (frame: Int, hash: String)?) {
        guard !isFinished else { return }
        isFinished = true
        guard !failed else { return }
        writeHeaderIfNeeded()
        guard !failed else { return }
        buffer += "]"
        if !notes.isEmpty {
            var items: [String] = []
            for note in notes {
                guard let reason = encode(note.reason) else { return }
                items.append("{\"step\":\(note.step),\"reason\":\(reason)}")
            }
            buffer += ",\"unreproducible\":[" + items.joined(separator: ",") + "]"
        }
        if let last {
            guard let hash = encode(last.hash) else { return }
            buffer += ",\"last\":{\"frame\":\(last.frame),\"pixelHash\":\(hash)}"
        }
        buffer += ",\"complete\":true}\n"
        flush()
        guard !failed, let handle else { return }
        do {
            try handle.synchronize()
            try handle.close()
            self.handle = nil
            guard rename(partial.path, destination.path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            fail("Could not finish \(destination.path): \(Diagnostics.reason(error))")
            return
        }
        claim?.release()
        claim = nil
    }

    /// 完成と呼べない終わり方をした。**行き先は作らず、`.partial` を残す** — `setup()` が投げて終わった
    /// 実行は、1 枚も描いておらず、再生の土台にならない。理由を 1 度言う。2 度目からは何もしない。
    func abandon(because reason: String) {
        guard !isFinished else { return }
        fail(reason)
    }

    // MARK: - 書く

    private func writeHeaderIfNeeded() {
        guard !wroteHeader, !failed else { return }
        wroteHeader = true
        let start =
            start ?? Start(seed: 0, params: [], frameRate: 0, width: 0, height: 0, window: false)
        let clock = startClock ?? (0, false)
        guard let identifier = encode(id), let seconds = encode(clock.seconds), let params = encode(start.params)
        else { return }
        buffer += "{\"schemaVersion\":\(Self.schemaVersion),\"id\":\(identifier)"
        buffer += ",\"clock\":{\"kind\":\"frames\",\"frameRate\":\(start.frameRate)}"
        buffer += ",\"size\":{\"width\":\(start.width),\"height\":\(start.height)}"
        buffer += ",\"window\":\(start.window)"
        buffer += ",\"start\":{\"seed\":\(start.seed),\"seconds\":\(seconds)"
        buffer += ",\"paused\":\(clock.paused),\"params\":\(params)}"
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

    /// 書けなくなった・完成と呼べなくなった。**1 度だけ言い、以後は何も書かない。** 書き途中のファイルは
    /// 完成として読まれない形で残る。
    private func fail(_ message: String) {
        guard !failed else { return }
        failed = true
        isFinished = true
        buffer.removeAll()
        try? handle?.close()
        handle = nil
        claim?.release()
        claim = nil
        Diagnostics.warn("Recording stopped: \(message). The record is left unfinished at \(partial.path)")
    }

    /// 値を JSON にする。**キーを並べ直して、同じ値から同じ文字を出す。** 有限でない数 (`@Param` の既定値が
    /// `.nan` など) は、数としては書けないので文字列 `"nan"`・`"inf"`・`"-inf"` にする。
    ///
    /// **書けなければ黙って `null` にせず、記録を止める** — `null` はスキーマに無い形で、そのまま完成品に
    /// なれば、読み手が壊れた記録を正しいものとして受け取る。
    private func encode<Value: Encodable>(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.nonConformingFloatEncodingStrategy = .convertToString(
            positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        do {
            return String(decoding: try encoder.encode(value), as: UTF8.self)
        } catch {
            fail("Could not write a value of the record: \(Diagnostics.reason(error))")
            return nil
        }
    }

    /// 画素のバイト列のハッシュ (SHA-256・16 進)。**出口が受け取るのと同じ道の絵**(``DisplayImage``) を渡す。
    static func hash(of image: DisplayImage) -> String {
        SHA256.hash(data: image.bytes).map { String(format: "%02x", $0) }.joined()
    }
}

extension InputEvent {
    /// パスだけを持つ出来事か (ドロップした先・`selectInput` で選んだ先)。**中身は記録に持たない。**
    /// パスの無い落とし・取り消し (`path` が `nil`) は含めない。
    var carriesAFileByPath: Bool {
        switch self {
        case .fileDropped(let paths, _, _): !paths.isEmpty
        case .fileSelected(let path, _): path != nil
        default: false
        }
    }

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
