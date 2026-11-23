// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation
import Synchronization

/// 再現を保証しないものが使われたと聞く係 (#3575)。記録する係 (``ReplayRecorder``) と流す係 (``ReplayPlayer``) の
/// 両方が受け、**同じ口から記録と再生の両方で名乗る**。
///
/// 名乗る口は ``LaunchingSketch/replay`` から引く。記録も再生もしていない実行では `nil` で、名乗りは判定 1 つで
/// 通り過ぎる。`Sendable` なのは、タスクローカル値に置くため (適合する 2 つは main actor に隔離されている)。
protocol UnreproducibleSink: AnyObject, Sendable {
    /// 再現を保証しないものが使われた。**同じ理由は 1 度だけ名乗る。**
    func noteUnreproducible(_ reason: String)
    /// ウィンドウで録った記録か (流す側では、流している記録がそうか)。ウィンドウでは音が実時間で鳴り、ウィンドウなしで
    /// 流すときはフレームの数で進むので、音の解析の値と音の時計に依る値が割れうる。ウィンドウなしで録った記録は流す側と同じ数え方である。
    var soundRunsInRealTime: Bool { get }
    /// 資源 (画像・データ・SVG・モデル・フォント・音・`.metal` の断片) を読んだ (#4092)。`name` は記録に載せる名前
    /// (``ReplayNotice/recordedName(_:)``)、`sha256` は読んだ中身の SHA-256 (16 進)。記録は控え、流す側は記録の控えと比べる。
    func noteResource(_ name: String, sha256: String)
    /// ファイルを読み直して取ったハッシュの控え。**受け手 1 つの寿命の中だけ**持つ (#4092)。
    var resourceDigests: ResourceDigests { get }
}

/// 外のモジュール (音) が、記録している実行・流している実行へ名乗る口 (#3575)。
///
/// 受け手は ``LaunchingSketch/replay`` で、`setup()`・`draw()`・入力のコールバックと、そこで起動した `Task` から届く。
///
/// ## 資源のハッシュ (#4092)
///
/// 取るのは記録か再生をしている実行だけで、取る係 (``ResourceHasher``) はそのときにしか作られない。取り方は 2 つ:
///
/// - **読んだバイト列から取る** (文字・データ・表・JSON・XML・SVG・OBJ・`.metal` の断片): 使った中身そのもののハッシュ
/// - **ファイルをもう 1 度読んで取る** (画像・STL・フォント・音・`createAudioIn(file:)`): 復号は OS (ImageIO・Model I/O・
///   CoreText・AVFoundation) にファイルの場所を渡すので、使ったバイト列を手にしない。2 度の読みの間にファイルが
///   書き換わると、ハッシュは使った中身と別のものになりうる (限界)。同じ場所・同じ更新の印なら前のハッシュを使い回す
///   (``ResourceDigests``)
///
/// 読み直せずにハッシュが取れなければ、黙って落とさず ``ReplayRecorder/Reason/resourceUnhashed(_:)`` を名乗る。
package enum ReplayNotice {
    /// 待つ読み込み (`request…`) を使った。結果が届くフレームは読み込みの速さで決まり、記録はそれを持たない。
    package static func waitingLoad() {
        LaunchingSketch.replay?.noteUnreproducible(ReplayRecorder.Reason.waitingLoad)
    }

    /// 記録か再生をしている実行なら資源のハッシュを取る係、していなければ `nil`。**待つ読み込みは、裏の仕事
    /// (タスクローカル値を継がない) へ渡す前にこれを読み**、裏でハッシュを取って、戻った所で ``readResource(_:sha256:)`` に渡す。
    package static var resourceHasher: ResourceHasher? {
        LaunchingSketch.replay.map { ResourceHasher(digests: $0.resourceDigests) }
    }

    /// 記録に載せる資源の名前。**名前を組み立てるのはここだけ**で、いまはスケッチが読み手に渡した名前そのまま
    /// (絶対パスで読めば絶対パスが載る)。
    static func recordedName(_ name: String) -> String { name }

    /// 資源 `name` を `url` から読んだ。記録も再生もしていなければ判定 1 つで返る。していれば、ファイルを
    /// もう 1 度読んで SHA-256 を取る (同じ更新の印なら控えを使う)。**読み手の控えに当たって読まなかったときは呼ばない**。
    package static func readResource(_ name: String, at url: URL) {
        guard let sink = LaunchingSketch.replay else { return }
        note(name, sha256: ResourceHasher(digests: sink.resourceDigests).sha256(of: url, name: name), to: sink)
    }

    /// 資源 `name` を読み、中身が `data` だった。
    package static func readResource(_ name: String, data: Data) {
        guard let sink = LaunchingSketch.replay else { return }
        note(name, sha256: ResourceHasher(digests: sink.resourceDigests).sha256(of: data, name: name), to: sink)
    }

    /// 裏の仕事で ``resourceHasher`` が取ったハッシュを名乗る。`nil` は読み直せなかったことで、そう名乗る。
    package static func readResource(_ name: String, sha256: String?) {
        guard let sink = LaunchingSketch.replay else { return }
        note(name, sha256: sha256, to: sink)
    }

    private static func note(_ name: String, sha256: String?, to sink: any UnreproducibleSink) {
        let recorded = recordedName(name)
        guard let sha256 else {
            sink.noteUnreproducible(ReplayRecorder.Reason.resourceUnhashed(recorded))
            return
        }
        sink.noteResource(recorded, sha256: sha256)
    }
}

/// 資源のハッシュを取る係 (#4092)。記録か再生をしている実行の中でだけ作られ (``ReplayNotice/resourceHasher``)、
/// 裏の仕事へ渡せる。
package nonisolated struct ResourceHasher: Sendable {
    let digests: ResourceDigests

    /// 検査が数えを差し込んだか。**差していなければ、数えの錠も辞書も触らない** (読むのは不可分の値 1 つ)。
    private static let counts = Atomic<Bool>(false)
    /// 取った回数 (名前ごと)。検査が「取らなかった」「取り直さなかった」を数えて確かめる。
    private static let taken = Mutex<[String: Int]>([:])

    /// 取った回数を数え始める (検査の口)。外さない — 名前ごとに数えるので、並べて走る検査どうしは混ざらない。
    package static func startCounting() {
        counts.store(true, ordering: .releasing)
    }

    /// 資源 `name` のハッシュを取った回数 (検査の口。``startCounting()`` の後に取ったものだけ)。
    package static func timesTaken(for name: String) -> Int {
        taken.withLock { $0[name, default: 0] }
    }

    private static func count(_ name: String) {
        guard counts.load(ordering: .acquiring) else { return }
        taken.withLock { $0[name, default: 0] += 1 }
    }

    /// ファイルを読み直して取る。**同じ場所・同じ更新の印 (``FileStamp``) なら前に取ったものを使い回す。** 読めなければ `nil`。
    package func sha256(of url: URL, name: String) -> String? {
        let stamp = FileStamp.of(url)
        if let stamp, let known = digests.known(url, stamp: stamp) { return known }
        Self.count(name)
        guard let digest = ResourceDigest.sha256(of: url) else { return nil }
        if let stamp { digests.remember(digest, for: url, stamp: stamp) }
        return digest
    }

    /// 読んだバイト列から取る。
    package func sha256(of data: Data, name: String) -> String {
        Self.count(name)
        return ResourceDigest.sha256(of: data)
    }
}

/// ファイルを読み直して取ったハッシュの控え (#4092)。受け手 (記録する係・流す係) が 1 つずつ持ち、その寿命の中だけ使う。
///
/// **毎フレーム `loadFont` する作品が、毎フレームもう 1 度フォントを読まないため。** 鍵は場所と更新の印で、印が変われば
/// 取り直す。印は ``FileStamp`` そのもの (更新時刻・大きさ・ファイル番号・ボリューム) で、リンクの付け替えや時刻を保った
/// 写しの置き換えは取り直す。同じファイルを同じ大きさで書き換えて時刻を保つ書き方 (`cp -p`・`rsync -t --inplace` の上書き)
/// や、時刻の粒度の粗い置き場 (exFAT・SMB) での同じ刻みの内の同じ大きさの書き換えは見分けない。
package nonisolated final class ResourceDigests: Sendable {
    private let entries = Mutex<[URL: (stamp: FileStamp, sha256: String)]>([:])

    package init() {}

    func known(_ url: URL, stamp: FileStamp) -> String? {
        entries.withLock { entries in
            guard let entry = entries[url], entry.stamp == stamp else { return nil }
            return entry.sha256
        }
    }

    func remember(_ sha256: String, for url: URL, stamp: FileStamp) {
        entries.withLock { $0[url] = (stamp, sha256) }
    }
}

/// 資源の中身の SHA-256 (16 進・#4092)。どのスレッドからも呼べる。
package nonisolated enum ResourceDigest {
    /// ファイルの中身の SHA-256。読めなければ `nil` (名乗りの口が ``ReplayRecorder/Reason/resourceUnhashed(_:)`` にする)。
    /// 大きなファイル (音) を丸ごと持たないよう、塊ごとに読む。
    package nonisolated static func sha256(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            // 終わりでは `nil` か空が返る
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
                hasher.update(data: chunk)
            }
        } catch {
            return nil
        }
        return hex(hasher.finalize())
    }

    /// バイト列の SHA-256。
    package nonisolated static func sha256(of data: Data) -> String {
        hex(SHA256.hash(data: data))
    }

    private nonisolated static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 音 1 つの、解析の値 (`level`・`spectrum`・`waveform`・`isBeat` など) を読んだことの名乗り (#3575)。
///
/// **鳴らすだけの音は名乗らない** — 鳴った音は絵にも `expose` の値にも返らないので、照合を崩さない。名乗るのは
/// ウィンドウで録った記録 (流す側では、それを流しているとき) だけ (``UnreproducibleSink/soundRunsInRealTime``)。
///
/// 解析の値を読むたびに通る。**同じ受け手へは 1 度しか理由を組まない** — 2 度目からは受け手を比べるだけで返る
/// (帯ごとに何百回も読む作品で、読むたびに文字列を組んで走査しない)。
package struct SoundAnalysisNotice {
    /// 読んだ音の型の名前 (理由に載る)。
    private let kind: String
    /// 既に名乗った (または名乗らないと決めた) 受け手。受け手の寿命は実行が決めるので弱く持つ。
    private weak var settled: (any UnreproducibleSink)?

    package init(kind: String) {
        self.kind = kind
    }

    /// 解析の値を読んだ。
    package mutating func noteRead() {
        guard let sink = LaunchingSketch.replay, sink !== settled else { return }
        settled = sink
        guard sink.soundRunsInRealTime else { return }
        sink.noteUnreproducible(ReplayRecorder.Reason.soundAnalysis(kind))
    }
}

/// 音の時計に依る値 (`soundTime`・`SoundFile.position`・`SoundFile.isPlaying`) を読んだことの名乗り (#4096)。
///
/// 音の時計は、ウィンドウでは音が実際に作った標本の数で進み、ウィンドウなしで流すときはフレームの数で進む。
/// 名乗るのは ``SoundAnalysisNotice`` と同じく、ウィンドウで録った記録 (流す側では、それを流しているとき) だけで、
/// 同じ受け手へは 1 度しか理由を組まない。読み手 1 つにつき 1 つ持つ (理由に読み手の名前が載る)。
package struct SoundClockNotice {
    /// 読んだ口の名前 (理由に載る)。
    private let reader: String
    /// 既に名乗った (または名乗らないと決めた) 受け手。受け手の寿命は実行が決めるので弱く持つ。
    private weak var settled: (any UnreproducibleSink)?

    package init(reader: String) {
        self.reader = reader
    }

    /// 音の時計に依る値を読んだ。
    package mutating func noteRead() {
        guard let sink = LaunchingSketch.replay, sink !== settled else { return }
        settled = sink
        guard sink.soundRunsInRealTime else { return }
        sink.noteUnreproducible(ReplayRecorder.Reason.soundClock(reader))
    }
}

/// 外から値が届く入り口のうち、**届く値がフレームの数え方だけで決まるもの**の印 (#3575)。
///
/// ``Inlet/report`` を持つ入り口は、届いた値を記録が持たないので「再現を保証しない」と名乗る。ただし、スケッチの中で
/// 作った値の列を 1 フレームに 1 つずつ流すだけの入り口 (`createCapture(frames:)`) は、同じ列からは同じフレームに
/// 同じ値が出るので名乗らない。列を作るのに使ったもの (URL から受け取った本文など) は、それぞれの口が名乗る。
package protocol FrameDeterminedSource {
    /// 届く値がフレームの数え方だけで決まるか。
    var isDeterminedByFrames: Bool { get }
}
