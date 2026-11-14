// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Synchronization

/// 速さ (``SoundFile/rate(_:)``・#3473) で読み出す位置と、読み出し方。音の側 (``FileVoice``・``FileNode``) と
/// 主スレッドの解析 (``Playhead``) が、**同じ式で同じ標本を作る**ための共有の部品。
///
/// ## 位置は「速さを変えた点」から導く
///
/// 区切りの中で速さを変えた点を「錨」と呼ぶ。錨は、区切りの頭から何標本経ったか (`elapsed`)・そこで読んでいた
/// ファイルの位置 (`position`。小数・ループでも折り返さない)・そこからの速さ (`rate`) を持つ。錨から `k` 標本
/// 経ったところで読む位置は `position + Double(k) × rate` で、足し込まずに毎回導く (``FileNode`` の標本化率の変換と
/// 同じ書き方)。次の錨の位置も同じ式で決める。音の側と主スレッドは同じ値から同じ順に計算するので、同じ位置になる。
///
/// ## 読み出し方
///
/// エフェクトへ通した経路 (``FileNode``) の標本化率の変換と同じ方式で、実装を共有する (``read(_:length:at:looping:kernel:)``)。
///
/// - 速さ 1 以下 (遅くする): 位置の前後 4 標本の三次補間。位置が整数なら標本そのまま
/// - 速さ 1 より上 (速くする): 読む比 (速さ) に合わせた窓つき sinc の低域通過 (``DownsamplingKernel``)。読む比が
///   ``maximumRatio`` を越えるときは、``maximumRatio`` の低域通過のまま読む (係数の表と 1 標本あたりの手間が比に
///   比例して増え、音の側で間に合わなくなるため。越えた分の高い音は折り返す)
nonisolated enum FileRate {
    /// 低域通過の係数を作る比の上限。8 倍の比で、係数は片側 105 標本・表は約 5 万個。
    static let maximumRatio = 8.0

    /// 錨から `elapsed` 標本経ったところで読む位置。**音の側と主スレッドの式の正本。**
    @inline(__always)
    static func position(from origin: Double, elapsed: Int, rate: Double) -> Double {
        origin + Double(elapsed) * rate
    }

    /// `source` (長さ `length`) の位置 `position` (小数) の値。ループなら端を折り返して読み、1 度だけなら端の標本を
    /// 保って読む。`kernel` があれば低域通過を掛けて、無ければ三次補間 (Catmull-Rom) で読む。
    ///
    /// ``FileNode`` の標本化率の変換と同じ式 (ここが正本)。**位置が整数で `kernel` が無ければ、標本そのもの**を返す。
    @inline(__always)
    static func read(
        _ source: UnsafePointer<Float>, length: Int, at position: Double, looping: Bool,
        kernel: DownsamplingKernel?
    ) -> Float {
        let floor = position.rounded(.down)
        let fraction = position - floor
        var base = floor
        if looping { base = base.truncatingRemainder(dividingBy: Double(length)) }
        let index = Int(base)
        func at(_ place: Int) -> Float {
            if looping { return source[((place % length) + length) % length] }
            return source[min(max(place, 0), length - 1)]
        }
        if let kernel { return kernel.apply(at: index, fraction: fraction, read: at) }
        let near = at(index)
        guard fraction != 0 else { return near }
        let before = at(index - 1)
        let next = at(index + 1)
        let after = at(index + 2)
        let t = Float(fraction)
        let cubic = -0.5 * before + 1.5 * near - 1.5 * next + 0.5 * after
        let square = before - 2.5 * near + 2 * next - 0.5 * after
        let slope = -0.5 * before + 0.5 * next
        return ((cubic * t + square) * t + slope) * t + near
    }
}

/// 読む比 (``ratio``) の低域通過の係数。**主スレッドが作り、音の側は参照を保たずに読む**
/// (``RateLink`` が、音の側が使い終えるまで主スレッドの側で持つ)。
nonisolated final class RateKernel: Equatable, @unchecked Sendable {
    /// 同じ比の係数は同じ値 (作り方が決まっている)。
    static func == (lhs: RateKernel, rhs: RateKernel) -> Bool { lhs.ratio == rhs.ratio }

    /// 係数を作った比 (``FileRate/maximumRatio`` で寄せた後)。
    let ratio: Double
    let kernel: DownsamplingKernel

    init(ratio: Double) {
        self.ratio = ratio
        kernel = DownsamplingKernel(ratio: ratio)
    }

    /// 読む比 `ratio` の係数。1 以下 (三次補間で読む) なら `nil`。**主スレッドだけが呼ぶ** (係数を作るのは確保)。
    /// 同じ比は `cache` から返す。使われなくなった係数は ``prune(_:)`` で捨てる。
    static func make(ratio: Double, cache: inout [UInt64: RateKernel]) -> RateKernel? {
        guard ratio > 1 else { return nil }
        let held = min(ratio, FileRate.maximumRatio)
        if let found = cache[held.bitPattern] { return found }
        let made = RateKernel(ratio: held)
        cache[held.bitPattern] = made
        return made
    }

    /// 係数の置き場から、ほかのどこからも参照されていない係数を捨てる。
    static func prune(_ cache: inout [UInt64: RateKernel]) {
        for key in Array(cache.keys) where isKnownUniquelyReferenced(&cache[key]!) {
            cache[key] = nil
        }
    }
}

/// 速さを主スレッドから音の側へ渡し、**音の側が速さを変えた点 (錨) を主スレッドへ返す** (#3473)。
///
/// 実際に鳴らしている間、音の側がいつ速さを受け取るかは主スレッドには分からない。そこで音の側は、受けた点の
/// 区切りの世代・区切りの頭から経った標本の数・読んでいた位置を返し、主スレッドはそれを錨として位置と解析に使う。
///
/// **音の側は、前に返した錨を主スレッドが読むまで、次の速さを受けない** (主スレッドは読んだら ``acknowledged`` を
/// 書く)。返す錨は常に 1 つで、主スレッドが錨を取りこぼさない — 取りこぼすと、主スレッドの位置と解析が鳴った音と
/// ずれる。代わりに、実時間では 1 フレームに 2 度以上速さを変えると、2 度目は次のフレームまで待つことがある
/// (固定の時計の書き出しでは、フレームの頭で主スレッドが読むので待たない)。
///
/// - 頼む側 (主スレッドが書き、音の側が読む): 版・速さ・係数の参照を、版で挟んで書く (seqlock。``FileVoice`` の包絡と同じ)
/// - 返す側 (音の側が書き、主スレッドが読む): 版・世代と経った数・位置・速さを、版で挟んで書く
///
/// 音の側は待たず、確保しない。読みかけで版が動いていれば受けず、次の描き出しで読み直す。主スレッドは、音の側が
/// 書いている途中なら書き終わるまで回って待つ (音の側は数個の原子値を書くだけ)。
nonisolated final class RateLink: @unchecked Sendable {
    /// 音の側が速さを受けた点。
    struct Anchor: Equatable {
        /// 受けたときの区切りの世代 (音の側の数え方の、詰める前の値)。
        var generation: UInt64
        /// 区切りの頭から経った標本の数 (主スレッドが ``Playhead`` に渡す数と同じ数え方)。
        var elapsed: Int
        /// 受けた点で読んでいた位置 (ファイルの標本・小数・折り返さない)。
        var position: Double
        /// 受けた速さ。
        var rate: Double
    }

    /// 頼んだ速さ (音の側が受けて使う形)。
    struct Request {
        var rate: Double
        var kernel: Unmanaged<RateKernel>?
    }

    private let requestVersion = Atomic<UInt64>(0)
    private let requestRate = Atomic<UInt64>(0)
    private let requestKernel = Atomic<UInt>(0)

    private let anchorVersion = Atomic<UInt64>(0)
    private let anchorGeneration = Atomic<UInt64>(0)
    private let anchorElapsed = Atomic<UInt64>(0)
    private let anchorPosition = Atomic<UInt64>(0)
    private let anchorRate = Atomic<UInt64>(0)
    private let anchorRequest = Atomic<UInt64>(0)
    /// 主スレッドが読んだ錨の版。
    private let acknowledged = Atomic<UInt64>(0)

    // 主スレッドだけが読み書きする
    /// 頼んだ版ごとの係数。音の側が使い終えるまで持つ。
    private var held: [UInt64: RateKernel] = [:]
    private var absorbed: UInt64 = 0

    // 音の側だけが読み書きする
    private var taken: UInt64 = 0
    private var published: UInt64 = 0

    /// - Parameter kernel: 音の側が最初から使う係数。音の側が次の係数へ移るまで持つ。
    init(kernel: RateKernel?) {
        if let kernel { held[0] = kernel }
    }

    // MARK: - 主スレッド

    /// 速さ `rate` (読む比が 1 を越えるなら係数 `kernel`) を頼む。音の側は、次に描くとき (前の錨を主スレッドが
    /// 読んでいれば) 受ける。
    func request(_ rate: Double, kernel: RateKernel?) {
        let version = requestVersion.load(ordering: .relaxed)
        requestVersion.store(version &+ 1, ordering: .releasing)
        requestRate.store(rate.bitPattern, ordering: .releasing)
        let pointer = kernel.map { UInt(bitPattern: Unmanaged.passUnretained($0).toOpaque()) } ?? 0
        requestKernel.store(pointer, ordering: .releasing)
        requestVersion.store(version &+ 2, ordering: .releasing)
        if let kernel { held[version &+ 2] = kernel }
    }

    /// 音の側が返した新しい錨を読む。無ければ `nil`。読んだら音の側に知らせ、もう使わない係数を手放す。
    func absorb() -> Anchor? {
        var version = anchorVersion.load(ordering: .acquiring)
        for _ in 0..<1_000_000 {
            guard version & 1 == 1 else { break }
            version = anchorVersion.load(ordering: .acquiring)
        }
        guard version & 1 == 0, version != absorbed else { return nil }
        let generation = anchorGeneration.load(ordering: .acquiring)
        let elapsed = anchorElapsed.load(ordering: .acquiring)
        let position = anchorPosition.load(ordering: .acquiring)
        let rate = anchorRate.load(ordering: .acquiring)
        let request = anchorRequest.load(ordering: .acquiring)
        // 音の側は前の錨を読むまで次を書かない (``acknowledged``) ので、読んでいる間に版は動かない
        guard anchorVersion.load(ordering: .acquiring) == version else { return nil }
        absorbed = version
        acknowledged.store(version, ordering: .releasing)
        // 音の側が受けた版より前の係数は、もう読まれない
        for key in Array(held.keys) where key < request { held[key] = nil }
        return Anchor(
            generation: generation, elapsed: Int(truncatingIfNeeded: elapsed),
            position: Double(bitPattern: position), rate: Double(bitPattern: rate))
    }

    // MARK: - 音の側

    /// 新しく頼まれた速さ。前の錨を主スレッドがまだ読んでいない・書いている途中・新しく頼まれていなければ `nil`。
    /// **待たず、確保しない。**
    func take() -> Request? {
        guard acknowledged.load(ordering: .acquiring) == published else { return nil }
        let version = requestVersion.load(ordering: .acquiring)
        guard version & 1 == 0, version != taken else { return nil }
        let rate = requestRate.load(ordering: .acquiring)
        let pointer = requestKernel.load(ordering: .acquiring)
        guard requestVersion.load(ordering: .acquiring) == version else { return nil }
        taken = version
        let kernel = UnsafeMutableRawPointer(bitPattern: pointer).map {
            Unmanaged<RateKernel>.fromOpaque($0)
        }
        return Request(rate: Double(bitPattern: rate), kernel: kernel)
    }

    /// 受けた速さの錨を返す。``take()`` が速さを返した描き出しの中で 1 度呼ぶ。
    func publish(generation: UInt64, elapsed: Int, position: Double, rate: Double) {
        let version = published &+ 2
        anchorVersion.store(published &+ 1, ordering: .releasing)
        anchorGeneration.store(generation, ordering: .releasing)
        anchorElapsed.store(UInt64(truncatingIfNeeded: elapsed), ordering: .releasing)
        anchorPosition.store(position.bitPattern, ordering: .releasing)
        anchorRate.store(rate.bitPattern, ordering: .releasing)
        anchorRequest.store(taken, ordering: .releasing)
        anchorVersion.store(version, ordering: .releasing)
        published = version
    }
}
