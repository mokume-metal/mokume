// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 再生位置の移り変わり。**機材にも時計にも触れない純粋な型**で、検査が直に回す。
///
/// 位置は「区切り」で持つ。区切りは鳴らし始めた位置 (``start``) から始まり、そこから鳴った
/// 標本の数 (`played`) は呼ぶ側が測って渡す — 実際に鳴らしているなら player が描いた数、
/// 書き出しならフレームの数から決めた数である。どちらで測っても、同じ `played` からは
/// 同じ位置と同じ窓が出る。だから書き出しの解析は、実時間の再生と同じ時刻の窓から取られる。
///
/// 鳴らし始めるたびに区切りを始め直し、止めるときは区切りを締めて位置を ``start`` に残す。
nonisolated struct Playhead: Equatable {
    /// 標本の数。1 以上。
    let length: Int
    /// いまの区切りが始まった位置 (標本)。止まっている間は、次に鳴らし始める位置。
    private(set) var start = 0
    /// 鳴っているか。
    private(set) var isPlaying = false
    /// 終わりから頭へ戻り続けるか。
    private(set) var isLooping = false

    init(length: Int) {
        self.length = max(1, length)
    }

    /// 区切りの中で `played` 標本鳴ったときの位置。止まっていれば ``start``。
    /// 1 度だけ鳴らしているなら ``length`` で止まる。
    func position(after played: Int) -> Int {
        guard isPlaying else { return start }
        let reached = start + max(0, played)
        return isLooping ? reached % length : min(reached, length)
    }

    /// 1 度だけ鳴らしていて、`played` 標本で終わりまで鳴り切ったか。
    func hasEnded(after played: Int) -> Bool {
        isPlaying && !isLooping && start + max(0, played) >= length
    }

    /// 鳴らし始める。**鳴っている最中なら頭から鳴らし直す。** 止めていれば止めた位置から、
    /// 頭へ戻してあれば頭から。呼んだ側は区切りを始め直す。
    mutating func play(looping: Bool) {
        if isPlaying { start = 0 }
        isPlaying = true
        isLooping = looping
    }

    /// 止めて、いまの位置を覚える。鳴り終わっていれば頭へ戻す。
    mutating func pause(after played: Int) {
        guard isPlaying else { return }
        start = hasEnded(after: played) ? 0 : position(after: played)
        isPlaying = false
    }

    /// 止めて頭へ戻す。
    mutating func stop() {
        start = 0
        isPlaying = false
    }

    /// 鳴り終わっていれば止めて頭へ戻す。止めたなら `true`。
    mutating func settle(after played: Int) -> Bool {
        guard hasEnded(after: played) else { return false }
        stop()
        return true
    }

    /// 区切りの中で `played` 標本鳴ったところで終わる、`size` 標本の窓。**いま鳴っている音**の
    /// 窓で、入力の窓 (``AudioAnalysis/window(of:sampleRate:endingAt:)``) と同じく古い順に並ぶ。
    ///
    /// - 止まっていれば全部 0
    /// - 区切りの始まりより前は 0 (まだ鳴らしていない)
    /// - 1 度だけなら、終わりより後は 0。ループなら頭へ戻って続ける
    func window(of samples: [Float], after played: Int, size: Int = AudioAnalysis.windowSize)
        -> [Float]
    {
        guard isPlaying, !samples.isEmpty else { return Array(repeating: 0, count: size) }
        let played = max(0, played)
        return (0..<size).map { offset in
            let step = played - size + offset
            guard step >= 0 else { return 0 }
            let index = start + step
            if isLooping { return samples[index % samples.count] }
            return index < samples.count ? samples[index] : 0
        }
    }
}
