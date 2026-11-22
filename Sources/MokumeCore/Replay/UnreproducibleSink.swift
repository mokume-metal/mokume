// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CryptoKit
import Foundation

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
    /// 資源 (画像・データ・SVG・モデル・フォント・音・`.metal` の断片) を読んだ (#4092)。`name` は利用者が渡した名前、
    /// `sha256` は読んだ中身の SHA-256 (16 進)。記録は控え、流す側は記録の控えと比べる。
    func noteResource(_ name: String, sha256: String)
}

/// 外のモジュール (音) が、記録している実行・流している実行へ名乗る口 (#3575)。
///
/// 受け手は ``LaunchingSketch/replay`` で、`setup()`・`draw()`・入力のコールバックと、そこで起動した `Task` から届く。
package enum ReplayNotice {
    /// 待つ読み込み (`request…`) を使った。結果が届くフレームは読み込みの速さで決まり、記録はそれを持たない。
    package static func waitingLoad() {
        LaunchingSketch.replay?.noteUnreproducible(ReplayRecorder.Reason.waitingLoad)
    }

    /// 記録か再生をしている実行の中か。**資源のハッシュを取るかをここで決める** — 待つ読み込みは、裏の仕事
    /// (タスクローカル値を継がない) へ渡す前にこれを読み、裏でハッシュを取って、戻った所で ``readResource(_:sha256:)`` に渡す。
    package static var watchesResources: Bool { LaunchingSketch.replay != nil }

    /// 資源 `name` を `url` から読んだ (#4092)。記録も再生もしていなければ判定 1 つで返る。していれば、ファイルを
    /// もう 1 度読んで SHA-256 を取る。**控えに当たって読まなかったときは呼ばない** (1 度目が名乗っている)。
    package static func readResource(_ name: String, at url: URL) {
        guard let sink = LaunchingSketch.replay, let digest = ResourceDigest.sha256(of: url) else { return }
        sink.noteResource(name, sha256: digest)
    }

    /// 資源 `name` を読み、中身が `data` だった。
    package static func readResource(_ name: String, data: Data) {
        guard let sink = LaunchingSketch.replay else { return }
        sink.noteResource(name, sha256: ResourceDigest.sha256(of: data))
    }

    /// 資源 `name` を文字として読み、中身が `text` だった (`.metal` の断片)。ハッシュは UTF-8 のバイト列から取る。
    package static func readResource(_ name: String, text: String) {
        guard let sink = LaunchingSketch.replay else { return }
        sink.noteResource(name, sha256: ResourceDigest.sha256(of: Data(text.utf8)))
    }

    /// 裏の仕事で取ったハッシュを名乗る。`sha256` が `nil` (取らなかった・読めなかった) なら何もしない。
    package static func readResource(_ name: String, sha256: String?) {
        guard let sha256, let sink = LaunchingSketch.replay else { return }
        sink.noteResource(name, sha256: sha256)
    }
}

/// 資源の中身の SHA-256 (16 進・#4092)。どのスレッドからも呼べる。
package enum ResourceDigest {
    /// ファイルの中身の SHA-256。読めなければ `nil` (読めなかった資源は、読み手が自分の失敗として名乗る)。
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
