// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// 主スレッドから音の側へ渡す操作 1 つ。**値だけの小さな型**で、列へ置くのに確保が要らない。
nonisolated struct SynthCommand {
    enum Op: UInt8 {
        /// 節が置き場に入った。音の側が引き取って、描く順に並べ直す。
        case activate
        /// 値を変える。`bits` に `Float` のビット列。
        case set
        /// 鳴らし始める (音源)。
        case play
        /// 止める (音源)。
        case stop
        /// 包絡を頭から始める (音源)。
        case trigger
        /// エフェクトの入力を置き換える。`bits` に入力の節の番号の集合。
        case inputs
        /// ファイルの節 (``FileNode``) の区切りを始める。`bits` に始まる位置・ループ・区切りの世代
        /// (``FileNode/segment(start:looping:generation:)``)。
        case segment
        /// 作者が音源を手放した (使う側の参照が無くなった)。音の側は、その音源が鳴り終えたら節を外して
        /// 置き場を返す。**この後その節へ操作は来ない。**
        case release
    }

    var op: Op
    var node: UInt8
    var param: SynthParam = .frequency
    var bits: UInt64 = 0
}

/// 1 つのスケッチの合成した音を全部持つ「ラック」。音源 (オシレータ・ノイズ) とエフェクトの節と、
/// エフェクトの入力の繋がりを持ち、標本を作る ([ADR-0042] 決定 6 の「同じ音の流れの音源・処理」)。
///
/// **機材にも時計にも触れない。** 標本を作る口 (``render(left:right:frames:)``) を、実機では
/// 音の側のスレッド (``RackPlayer``) が、書き出しと検査ではフレームの側が呼ぶ。同時に 2 か所から
/// 呼んではならない。
///
/// ## 音の側は待たず、確保しない
///
/// 主スレッドからの操作 (値を変える・鳴らす・繋ぐ) は、事前に確保した列 (書き手 1・読み手 1) で
/// 渡す。音の側は呼ばれるたびに、列に溜まった操作をその順に適用してから標本を作る。錠は
/// 取らず、標本を作る間は確保しない ([ADR-0042] 決定 7)。節の置き場も作るときに 1 度だけ確保する。
///
/// **列が満杯のときは、操作を落とさず控え、頼んだ順に載せ直す** (``post(_:force:)``・``retryHeld()``)。
/// 控えがある間は後から来る操作も控えの後ろに並べる — 節を足す前に節への操作が届くと、その操作は
/// 捨てられ、入力に選ぶ前に節が鳴ると直に出てしまうので、載る順は頼んだ順のままにする。節を足せない
/// のは置き場が埋まっているときだけ。
///
/// ## 置き場は、手放して鳴り終えた音源のぶんだけ戻る
///
/// **同時に生きている節は ``capacity`` までで、エフェクトは置いたらラックの終わりまで残る。**
/// 音源 (オシレータ・ノイズ) と、エフェクトへ通した音声ファイルの節 (``FileNode``) は、作者が手放し
/// (``release(_:)``)、かつ鳴り終えた (止めて消えた・包絡が終わった — ``RackNode/isFinished``) ときに、
/// 置き場が戻る。ファイルの節を手放すのは、``SoundFile`` が外される (``SoundFile/close()``) とき。
/// 鳴っている音は切らない。
///
/// 戻す道筋は、音の側が確保も解放もしない形にしてある。
/// - 音の側は、手放された音源が鳴り終えたと見たら、その節を自分の表と描く順から外し、**事前に確保した
///   列**で番号を主スレッドへ返す (節の型を手放すのは主スレッドだけ — 置き場の `Unmanaged` が最後の参照)
/// - 主スレッドは、番号を受け取ってから (``collectFreed()``。節を足す前にも呼ぶ) 置き場を空け、
///   その番号を使う次の節へ、前の節の繋がりを持ち越さない
/// - 次の節が置き場を使うとき (``SynthCommand/Op/activate``)、音の側は、他のエフェクトの入力の集合から
///   その番号を落とし、その番号の入力の集合を空にする。主スレッドが番号を受け取る前に載せた入力の操作が
///   古い集合を持っていても、新しい節はそれを引き継がない。出口の写し (`SampleRing`) は節ごとに作る
///
/// 音源が返った後も、エフェクトは動き続ける (入力が無音になるだけ。尾は切れない)。
///
/// ## 繋がりと描く順
///
/// エフェクトは、入力に選ばれた節の出口を足し合わせて処理する。入力に選ばれた節は、直には
/// 出口へ出ず、エフェクトの出口を通ってだけ出る (入力に選ばれていない節が、出口へ出る)。
/// エフェクトの入力にエフェクトを選べば、続けて処理できる。**描く順は繋がりから決める** —
/// 入力が先、エフェクトが後。繋がりが輪になっているエフェクトは動かない。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated final class SynthRack: @unchecked Sendable {
    // `@unchecked Sendable`: 主スレッドが書くのは ``slots`` (節を置いてから ``activate`` を列へ
    // 載せる順) と列の書き手の側だけで、音の側が読むのは列から取り出した後に限る。
    // 残りの状態は音の側 (呼んだスレッド) だけが触る。

    /// 同時に生きている節の数の上限。繋がりを 64 ビットの集合で持つ。手放して鳴り終えた音源・ファイルの節は
    /// 数から外れる (エフェクトはラックの終わりまで数える)。
    static let capacity = 64
    /// 1 度に作る標本の数の上限。これより長い区切りは分けて作る。
    static let chunk = 512
    /// 出口の標本の写しの長さ (標本)。解析の窓 (1024) の 8 倍。
    static let meterCapacity = AudioAnalysis.windowSize * 8
    /// 操作の列の長さ。2 のべき乗。
    private static let queueCapacity = 4096
    /// 列に載せられず控えておく操作の数の上限 (``post(_:force:)``)。音の側が止まっている (流れが開いていない・
    /// 閉じた) ままで操作が積み上がり続けないための歯止めで、動いている間は届かない。
    private static let heldLimit = 1 << 14
    /// 列の空きがこれより少ないとき、**詰まっている**とみなす (``isCongested``)。1 回の呼び出しが載せる操作
    /// (節を足す・入力に選ぶ・区切りを始める・音量を伝える) の数より多い。
    private static let congestionMargin = 8

    let sampleRate: Double

    // MARK: 主スレッド側

    /// 置き場が埋まっている番号の集合。音の側が返した番号を受け取る (``collectFreed()``) まで、
    /// 手放された音源の番号も埋まったまま。
    private var occupied: UInt64 = 0
    /// これまでに作った節の数。ノイズの種に使う通し番号 (返った置き場の再利用に依らない)。
    private var created = 0
    /// 主スレッドが見ている繋がり (輪を作らないかを確かめるのに使う)。
    private var wiring = [UInt64](repeating: 0, count: SynthRack.capacity)
    private let slots: UnsafeMutablePointer<Unmanaged<RackNode>?>

    // MARK: 操作の列

    /// 列へ載せた操作を、載せた順に見る。**検査だけが使う** (主スレッドで呼ばれる)。載る順が音の側の
    /// 効き方 (どの操作の間に音が描かれうるか) を決めるので、順を検査が読めるようにしておく。
    nonisolated(unsafe) var observePost: ((SynthCommand) -> Void)?

    private let queue: UnsafeMutablePointer<SynthCommand>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)
    /// 列が満杯で載せられなかった操作 (頼んだ順)。主スレッドだけが触る。**列が空くまで控え、頼んだ順に
    /// 載せ直す** (``retryHeld()``)。控えがある間は、後から来る操作も控えに並べる — 載る順が頼んだ順から
    /// 入れ替わらないようにするため (節を足す前に節への操作が届くと、その操作は捨てられる)。
    private var held: [SynthCommand] = []

    // MARK: 返す番号の列 (音の側が書き手・主スレッドが読み手)

    /// 手放されて鳴り終えた音源の番号。**同じ番号は、主スレッドが受け取って置き場を使い直すまで
    /// 2 度載らない**ので、置き場の数 (``capacity``) で溢れない。
    private let freed: UnsafeMutablePointer<UInt8>
    private let freedTail = Atomic<Int>(0)
    /// 主スレッドが読み終えた位置 (主スレッドだけが触る)。
    private var freedHead = 0

    // MARK: 音の側

    private var nodes = [RackNode?](repeating: nil, count: SynthRack.capacity)
    private var inputs = [UInt64](repeating: 0, count: SynthRack.capacity)
    /// 入力が繋がれたエフェクトの集合 (止められていないもの)。**入力の集合が空でも、繋がれたエフェクトは
    /// 動き続ける** — 入力の音源が返った後も尾を出し、入力が無音のときと同じになる。
    private var armed: UInt64 = 0
    /// 手放された音源の集合。鳴り終えたら返す。
    private var released: UInt64 = 0
    private var plan: ContiguousArray<Step> = []
    private var silent: ContiguousArray<RackNode> = []
    private var order: [Int] = []
    private var indegree = [Int](repeating: 0, count: SynthRack.capacity)
    private let buffers: UnsafeMutablePointer<Float>
    private let gathered: UnsafeMutablePointer<Float>
    private let zeros: UnsafeMutablePointer<Float>
    /// これまでに作った標本の数。
    private(set) var rendered = 0

    /// 描く順の 1 歩。
    private struct Step {
        var node: RackNode
        var inputs: UInt64
        /// 直に出口へ出るか (入力に選ばれていないか)。
        var terminal: Bool
    }

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        slots = .allocate(capacity: Self.capacity)
        slots.initialize(repeating: nil, count: Self.capacity)
        queue = .allocate(capacity: Self.queueCapacity)
        queue.initialize(
            repeating: SynthCommand(op: .stop, node: 0), count: Self.queueCapacity)
        freed = .allocate(capacity: Self.capacity)
        freed.initialize(repeating: 0, count: Self.capacity)
        buffers = .allocate(capacity: Self.capacity * Self.chunk)
        buffers.initialize(repeating: 0, count: Self.capacity * Self.chunk)
        gathered = .allocate(capacity: Self.chunk)
        gathered.initialize(repeating: 0, count: Self.chunk)
        zeros = .allocate(capacity: Self.chunk)
        zeros.initialize(repeating: 0, count: Self.chunk)
        plan.reserveCapacity(Self.capacity)
        silent.reserveCapacity(Self.capacity)
        order.reserveCapacity(Self.capacity)
    }

    deinit {
        for index in 0..<Self.capacity { slots[index]?.release() }
        slots.deallocate()
        queue.deallocate()
        freed.deallocate()
        buffers.deallocate()
        gathered.deallocate()
        zeros.deallocate()
    }

    // MARK: - 主スレッド: 節を足す

    /// 音源の節を足す。置き場が埋まっていれば `nil` (返った置き場は、足す前に受け取る)。
    func addSource(_ kind: SourceNode.Kind) -> RackNode? {
        add { id, serial in
            SourceNode(
                id: id, serial: serial, sampleRate: sampleRate, meter: Self.makeMeter(), kind: kind)
        }
    }

    /// 音声ファイルの標本を読み出す音源の節を足す (``SoundFile`` がエフェクトへ通されたとき)。
    /// 置き場が埋まっていれば `nil`。
    ///
    /// - Parameters:
    ///   - samples: ファイルの標本 (チャンネルを平均したモノラル)。
    ///   - fileRate: ファイルの標本化率 (Hz)。ラックの率と違えば、節が変換する。
    ///   - amplitude: 音量 (0〜1)。
    func addFile(samples: [Float], fileRate: Double, amplitude: Float) -> FileNode? {
        add { id, _ in
            FileNode(
                id: id, sampleRate: sampleRate, meter: Self.makeMeter(), samples: samples,
                fileRate: fileRate, amplitude: amplitude)
        }
    }

    /// 濾波器の節を足す。
    func addFilter(_ shape: FilterShape) -> RackNode? {
        add { id, _ in FilterNode(id: id, sampleRate: sampleRate, meter: Self.makeMeter(), shape: shape) }
    }

    /// リバーブの節を足す。
    func addReverb() -> RackNode? {
        add { id, _ in ReverbNode(id: id, sampleRate: sampleRate, meter: Self.makeMeter()) }
    }

    /// ディレイの節を足す。
    func addDelay() -> RackNode? {
        add { id, _ in DelayNode(id: id, sampleRate: sampleRate, meter: Self.makeMeter()) }
    }

    private static func makeMeter() -> SampleRing {
        SampleRing(capacity: meterCapacity)
    }

    /// `make` は、置き場の番号と、作った順の通し番号を受けて節を作る。
    private func add<Node: RackNode>(_ make: (_ id: Int, _ serial: Int) -> Node) -> Node? {
        collectFreed()
        guard occupied != .max else { return nil }
        // 空いている最小の番号。何も返らない間は、作った順の番号になる
        let id = (~occupied).trailingZeroBitCount
        let node = make(id, created)
        // 置き場へ書いてから列へ載せる。音の側は、列を読んだ後でだけ置き場を読む
        slots[id] = Unmanaged.passRetained(node)
        // 列が満杯でも、控えに並べて頼んだ順に載せる (置き場の数は 64 で、控えの上限には数えない)。
        // **節を足せないのは、置き場が埋まっているときだけ** — 呼ぶ側は、`nil` を置き場の上限と名乗ってよい
        post(SynthCommand(op: .activate, node: UInt8(id)), force: true)
        occupied |= 1 << UInt64(id)
        created += 1
        return node
    }

    /// 音源 `id` を手放した (使う側の参照が無くなった) と音の側へ伝える。受け付ければ `true`
    /// (``post(_:force:)``)。
    ///
    /// **鳴っている音は切らない。** 音の側が、鳴り終えたと見てから置き場を返す。この後その節へ操作を
    /// 渡してはならない。
    @discardableResult
    func release(_ id: Int) -> Bool {
        post(SynthCommand(op: .release, node: UInt8(id)))
    }

    /// 音の側が返した番号を受け取って、置き場を空ける。**主スレッドから呼ぶ。** 節を足すときにも呼ぶ。
    ///
    /// 節の型を手放すのはここ (主スレッド) だけで、音の側は番号を載せた後、その節に触らない。
    func collectFreed() {
        let end = freedTail.load(ordering: .acquiring)
        guard freedHead != end else { return }
        var position = freedHead
        while position != end {
            let id = Int(freed[position & (Self.capacity - 1)])
            position += 1
            slots[id]?.release()
            slots[id] = nil
            occupied &= ~(1 << UInt64(id))
            // 繋がりの写しも空ける。残すと、置き場を使う次の節が前の節の繋がりを持つ
            wiring[id] = 0
            let cleared: UInt64 = ~(1 << UInt64(id))
            for effect in 0..<Self.capacity { wiring[effect] &= cleared }
        }
        freedHead = end
    }

    /// 置き場が埋まっている節の数 (返す番号を受け取るまで、手放された音源も数える)。検査が読む。
    var occupiedCount: Int { occupied.nonzeroBitCount }

    // MARK: - 主スレッド: 操作を渡す

    /// 操作を列へ載せる。**列が満杯なら控えて、頼んだ順に載せ直す** (``retryHeld()``)。受け付ければ
    /// `true`。`false` は、控えが上限 (``heldLimit``) に達して捨てたとき — 音の側が長く止まっている間だけ。
    ///
    /// - Parameter force: `true` なら、控えの上限に数えず必ず受け付ける。置き場の数で数が抑えられている
    ///   操作 (節を足す) だけが使う。
    @discardableResult
    func post(_ command: SynthCommand, force: Bool = false) -> Bool {
        if held.isEmpty, postNow(command) { return true }
        guard force || held.count < Self.heldLimit else { return false }
        held.append(command)
        return true
    }

    /// 列に空きがあれば載せる。
    private func postNow(_ command: SynthCommand) -> Bool {
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < Self.queueCapacity else { return false }
        observePost?(command)
        queue[end & (Self.queueCapacity - 1)] = command
        tail.store(end + 1, ordering: .releasing)
        return true
    }

    /// 控えていた操作を、頼まれた順に載せられるだけ載せる。**主スレッドから、フレームごとに呼ぶ**
    /// (``SynthStage``)。
    func retryHeld() {
        guard !held.isEmpty else { return }
        var posted = 0
        while posted < held.count, postNow(held[posted]) { posted += 1 }
        if posted > 0 { held.removeFirst(posted) }
    }

    /// 載せられずに控えている操作の数。検査が読む。
    var heldCount: Int { held.count }

    /// 列が詰まっているか — 控えがあるか、空きが少ない。**詰まっている間は、位置を動かす操作を
    /// 音の側へ渡さず、操作を控える** (``SoundFile``): 渡した操作が控えに回ると、聞こえている音と位置がずれる。
    var isCongested: Bool {
        !held.isEmpty
            || Self.queueCapacity - (tail.load(ordering: .relaxed) - head.load(ordering: .acquiring))
                < Self.congestionMargin
    }

    /// 値を変える。
    @discardableResult
    func set(_ node: Int, _ param: SynthParam, _ value: Float) -> Bool {
        post(
            SynthCommand(
                op: .set, node: UInt8(node), param: param, bits: UInt64(value.bitPattern)))
    }

    /// エフェクト `effect` の入力に `input` を足せるか (輪にならないか)。
    func canConnect(_ input: Int, to effect: Int) -> Bool {
        guard input != effect else { return false }
        // `input` の入力をさかのぼって、`effect` に着くなら輪になる
        var seen: UInt64 = 0
        var pending: [Int] = [input]
        while let current = pending.popLast() {
            if current == effect { return false }
            if seen & (1 << UInt64(current)) != 0 { continue }
            seen |= 1 << UInt64(current)
            var mask = wiring[current]
            while mask != 0 {
                pending.append(mask.trailingZeroBitCount)
                mask &= mask - 1
            }
        }
        return true
    }

    /// エフェクト `effect` の入力を `mask` (節の番号の集合) に置き換える。
    @discardableResult
    func setInputs(_ effect: Int, _ mask: UInt64) -> Bool {
        wiring[effect] = mask
        return post(SynthCommand(op: .inputs, node: UInt8(effect), bits: mask))
    }

    /// いまエフェクト `effect` の入力 (主スレッドが見ているもの)。
    func inputs(of effect: Int) -> UInt64 {
        wiring[effect]
    }

    // MARK: - 標本を作る

    /// `frames` 標本を左右へ作る。左右の中身は上書きする。
    func render(
        left: UnsafeMutablePointer<Float>, right: UnsafeMutablePointer<Float>, frames: Int
    ) {
        drain()
        var done = 0
        while done < frames {
            let count = min(Self.chunk, frames - done)
            (left + done).update(repeating: 0, count: count)
            (right + done).update(repeating: 0, count: count)
            renderChunk(count, left: left + done, right: right + done)
            done += count
        }
        rendered += frames
        returnFinished()
    }

    /// 出口へは出さず、`frames` 標本ぶん進める。出口の標本の写し (解析が読む) だけが更新される。
    func advance(frames: Int) {
        drain()
        var done = 0
        while done < frames {
            let count = min(Self.chunk, frames - done)
            renderChunk(count, left: nil, right: nil)
            done += count
        }
        rendered += frames
        returnFinished()
    }

    private func renderChunk(
        _ frames: Int, left: UnsafeMutablePointer<Float>?, right: UnsafeMutablePointer<Float>?
    ) {
        for step in plan {
            let node = step.node
            let output = buffers + node.id * Self.chunk
            let idle = node.isIdle
            if node.isSource {
                node.render(frames: frames, input: zeros, output: output)
            } else {
                gathered.update(repeating: 0, count: frames)
                var mask = step.inputs
                while mask != 0 {
                    let source = buffers + mask.trailingZeroBitCount * Self.chunk
                    for index in 0..<frames { gathered[index] += source[index] }
                    mask &= mask - 1
                }
                node.render(frames: frames, input: gathered, output: output)
            }
            node.meter.write(count: frames, hostTime: 0) { output[$0] }
            if step.terminal, !idle, let left, let right {
                node.mix(output, frames: frames, left: left, right: right)
            }
        }
        // 入っていても動かない節 (入力の無いエフェクト・輪の中) の出口は無音
        for node in silent { node.meter.write(count: frames, hostTime: 0) { _ in 0 } }
    }

    // MARK: - 操作の列を読む

    private func drain() {
        var position = head.load(ordering: .relaxed)
        let end = tail.load(ordering: .acquiring)
        guard position != end else { return }
        var rebuild = false
        while position != end {
            let command = queue[position & (Self.queueCapacity - 1)]
            position += 1
            let id = Int(command.node)
            switch command.op {
            case .activate:
                // 置き場を使い直す節は、前の節の繋がりを持たない。他のエフェクトの入力から落とし、
                // 自分の入力も空にする (主スレッドが番号を受け取る前に載せた古い集合を、ここで断つ)
                let bit: UInt64 = 1 << UInt64(id)
                for effect in 0..<Self.capacity { inputs[effect] &= ~bit }
                inputs[id] = 0
                armed &= ~bit
                released &= ~bit
                nodes[id] = slots[id]?.takeUnretainedValue()
                rebuild = true
            case .set:
                nodes[id]?.apply(command.param, Float(bitPattern: UInt32(truncatingIfNeeded: command.bits)))
            case .play:
                nodes[id]?.start()
            case .stop:
                nodes[id]?.halt()
            case .trigger:
                nodes[id]?.trigger()
            case .inputs:
                let bit: UInt64 = 1 << UInt64(id)
                // 入力が無い (まだ繋がれていない・止められた) 状態から入力が入ったとき、前の状態を捨てる
                if armed & bit == 0, command.bits != 0 { nodes[id]?.reset() }
                inputs[id] = command.bits
                if command.bits != 0 { armed |= bit } else { armed &= ~bit }
                rebuild = true
            case .segment:
                nodes[id]?.begin(command.bits)
            case .release:
                if nodes[id] != nil { released |= 1 << UInt64(id) }
            }
        }
        head.store(position, ordering: .releasing)
        if rebuild { rebuildPlan() }
    }

    /// 手放された音源のうち鳴り終えたものを、表と描く順から外し、番号を主スレッドへ返す。
    /// 確保も解放もしない (節の型を手放すのは番号を受け取った主スレッドだけ)。
    private func returnFinished() {
        var pending = released
        guard pending != 0 else { return }
        var finished: UInt64 = 0
        while pending != 0 {
            let id = pending.trailingZeroBitCount
            pending &= pending - 1
            if let node = nodes[id], node.isFinished { finished |= 1 << UInt64(id) }
        }
        guard finished != 0 else { return }
        var each = finished
        while each != 0 {
            let id = each.trailingZeroBitCount
            each &= each - 1
            nodes[id] = nil
            inputs[id] = 0
            armed &= ~(1 << UInt64(id))
        }
        released &= ~finished
        // 描く順から外してから番号を渡す — 渡した後、音の側はその節に触らない
        rebuildPlan()
        var end = freedTail.load(ordering: .relaxed)
        each = finished
        while each != 0 {
            freed[end & (Self.capacity - 1)] = UInt8(each.trailingZeroBitCount)
            end += 1
            each &= each - 1
        }
        freedTail.store(end, ordering: .releasing)
    }

    /// 繋がりから、描く順と、出口へ直に出る節を決め直す。確保しない (置き場は事前に取ってある)。
    private func rebuildPlan() {
        plan.removeAll(keepingCapacity: true)
        silent.removeAll(keepingCapacity: true)
        var active: UInt64 = 0
        for id in 0..<Self.capacity where nodes[id] != nil { active |= 1 << UInt64(id) }

        // 描く順 (入力が先): 音源から始めて、入力が出そろったエフェクトを足していく
        var ordered: UInt64 = 0
        order.removeAll(keepingCapacity: true)
        for id in 0..<Self.capacity {
            guard let node = nodes[id] else { continue }
            if node.isSource {
                order.append(id)
                ordered |= 1 << UInt64(id)
                indegree[id] = 0
            } else {
                indegree[id] = (inputs[id] & active).nonzeroBitCount
                // 繋がれたまま入力の音源が全部返ったエフェクトは、入力が無音のときと同じに動き続ける
                if indegree[id] == 0, armed & (1 << UInt64(id)) != 0 {
                    order.append(id)
                    ordered |= 1 << UInt64(id)
                }
            }
        }
        var cursor = 0
        while cursor < order.count {
            let source = order[cursor]
            cursor += 1
            for id in 0..<Self.capacity {
                guard let node = nodes[id], !node.isSource, indegree[id] > 0,
                    inputs[id] & active & (1 << UInt64(source)) != 0
                else { continue }
                indegree[id] -= 1
                if indegree[id] == 0 {
                    order.append(id)
                    ordered |= 1 << UInt64(id)
                }
            }
        }

        // 入力に選ばれた節は直には出ない
        var consumed: UInt64 = 0
        for id in order {
            if let node = nodes[id], !node.isSource { consumed |= inputs[id] & active }
        }
        for id in order {
            guard let node = nodes[id] else { continue }
            plan.append(
                Step(
                    node: node, inputs: inputs[id] & active,
                    terminal: consumed & (1 << UInt64(id)) == 0))
        }
        for id in 0..<Self.capacity where ordered & (1 << UInt64(id)) == 0 {
            if let node = nodes[id] { silent.append(node) }
        }
    }
}
