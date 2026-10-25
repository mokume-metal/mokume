// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 拍の検出。**標本を 1 つずつ順に足すだけの状態**で、機材にも時計にも触れない ([ADR-0042] 決定 6 の改訂)。
///
/// 入力の分け方 (fps・届くチャンクの長さ) が違っても、同じ標本列からは同じ標本位置で拍を判定する。状態は
/// 音源の標本の通し番号を ``AudioAnalysis/hop`` ごとに区切った**固定のブロック**の列でだけ進み、届いた単位ごとに
/// 1 回判定する作りは採らない。足し算の順も標本の順に決まっているので、区切り方でビットがずれない。
///
/// ## 判定
///
/// ブロックごとの平均二乗 (エネルギー) が、直近の ``historyBlocks`` ブロック (48 kHz で約 1 秒) の平均の
/// ``ratio`` 倍を越え、かつ ``floorEnergy`` (−60 dBFS の RMS) を越えたら拍とする。
///
/// - 拍の直後の ``refractoryBlocks`` ブロック (約 64 ms) は数えない。1 つの立ち上がりが 2 つのブロックに
///   またがっても 1 回になる
/// - **途中から始めた (または捨てて始め直した) ときは、最初の ``warmupBlocks`` ブロックは出さない。** 履歴が
///   溜まる前の平均は当てにならず、曲の途中で読み始めた最初のブロックが拍になってしまう。標本の流れの
///   **最初から**始めたとき (``init(fresh:)``・``reset(fresh:)``。無音から鳴り始める音・ファイルの頭から鳴らす音) は、
///   履歴が無いのは本当に何も鳴っていなかったからなので、最初の立ち上がりも拍になる
/// - 拍の位置は、それを見つけたブロックの先頭の通し番号。立ち上がりはそのブロックか、1 つ前のブロックの
///   終わりの数標本にあるので (後者は前のブロックのエネルギーが小さすぎて見つからない)、立ち上がりから
///   hop 1 つ (512 標本) 以内である
/// - 区間が連続しないとき (標本を落としたとき) は履歴を捨てて、次の格子の境目から始め直す (途中からの
///   始め直し)。落とした区間では拍を出さない
///
/// 手本は Minim の `BeatDetect` の「音のエネルギーを直近の平均と比べる」形。p5.sound の `PeakDetect`・
/// Processing Sound の `BeatDetector` と同じく、感度の口は持たない (作例が要るまで作らない)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated struct BeatTracker {
    /// ブロックの長さ (標本)。窓の格子の hop と同じ。
    static let block = AudioAnalysis.hop
    /// 平均を取る直近のブロックの数。
    static let historyBlocks = 94
    /// 直近の平均の何倍を越えたら拍か。
    static let ratio: Float = 1.5
    /// 拍にする最小のエネルギー (平均二乗)。−60 dBFS の RMS。
    static let floorEnergy: Float = 1e-6
    /// 拍の後に数えないブロックの数。
    static let refractoryBlocks = 6
    /// 途中から始めたときに、出さないブロックの数。
    static let warmupBlocks = 8

    /// 次に足す標本の通し番号。まだ何も足していなければ `nil`。
    private var next: Int?
    /// 読み飛ばす標本の数 (始め直したとき、次の格子の境目まで)。
    private var skipping = 0
    /// いまのブロックの二乗和と、足した標本の数。
    private var sum: Float = 0
    private var filled = 0
    /// 終えたブロックのエネルギー (環)。
    private var history: [Float] = []
    private var cursor = 0
    /// 出さないブロックの残り (途中から始めたとき ``warmupBlocks``)。
    private var warmupLeft = 0
    /// 拍の後に残る、数えないブロックの数。
    private var quiet = 0

    /// - Parameter fresh: 標本の流れの最初から始めるか (``reset(fresh:)``)。
    init(fresh: Bool = true) {
        warmupLeft = fresh ? 0 : Self.warmupBlocks
    }

    /// 区間を処理した回数。検査が読む。
    private(set) var calls = 0
    /// 直近の ``process(_:)`` で見つけた拍の位置 (ブロックの先頭の通し番号)。検査が読む。
    private(set) var beats: [Int] = []

    /// 履歴を捨てる。
    ///
    /// - Parameter fresh: 次に足す標本が標本の流れの最初か (無音から鳴り始める・ファイルの頭から鳴らす)。
    ///   そうなら最初の立ち上がりも拍にする。途中 (曲の途中への飛び先・止めた位置からの再開) なら
    ///   ``warmupBlocks`` ブロックは出さない。
    mutating func reset(fresh: Bool) {
        next = nil
        skipping = 0
        sum = 0
        filled = 0
        history.removeAll(keepingCapacity: true)
        cursor = 0
        warmupLeft = fresh ? 0 : Self.warmupBlocks
        quiet = 0
    }

    /// 区間の標本を、標本の順に足す。区間に拍があれば `true`。
    ///
    /// 前の区間の終わりから続いていなければ、履歴を捨てて始め直す (``AudioSpan/from`` は上限で切られている)。
    mutating func process(_ span: AudioSpan) -> Bool {
        calls += 1
        beats.removeAll(keepingCapacity: true)
        var position = span.from
        if let expected = next, expected != position {
            // 続かない = 標本を落とした。途中からの始め直し
            reset(fresh: false)
        }
        if next == nil { skipping = (Self.block - position % Self.block) % Self.block }
        let end = span.to
        let base = span.base
        span.samples.withUnsafeBufferPointer { samples in
            while position < end {
                if skipping > 0 {
                    let count = min(skipping, end - position)
                    position += count
                    skipping -= count
                    continue
                }
                let value = samples[position - base]
                sum += value * value
                filled += 1
                position += 1
                if filled == Self.block { closeBlock(endingAt: position) }
            }
        }
        next = max(end, span.from)
        return !beats.isEmpty
    }

    private mutating func closeBlock(endingAt position: Int) {
        let energy = sum / Float(Self.block)
        sum = 0
        filled = 0
        var total: Float = 0
        for value in history { total += value }
        let mean = history.isEmpty ? 0 : total / Float(history.count)
        if warmupLeft > 0 {
            warmupLeft -= 1
        } else if quiet > 0 {
            quiet -= 1
        } else if energy > Self.floorEnergy, energy > Self.ratio * mean {
            beats.append(position - Self.block)
            quiet = Self.refractoryBlocks
        }
        if history.count < Self.historyBlocks {
            history.append(energy)
        } else {
            history[cursor] = energy
            cursor = (cursor + 1) % Self.historyBlocks
        }
    }
}
