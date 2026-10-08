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
/// 取らず、標本を作る間は確保しない ([ADR-0042] 決定 7)。節の置き場も作るときに 1 度だけ確保し、
/// 節は置いたらラックの終わりまで残る。**節を作れる数は ``capacity`` までで、手放しても戻らない。**
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

    /// 節の数の上限。繋がりを 64 ビットの集合で持つ。
    static let capacity = 64
    /// 1 度に作る標本の数の上限。これより長い区切りは分けて作る。
    static let chunk = 512
    /// 出口の標本の写しの長さ (標本)。解析の窓 (1024) の 8 倍。
    static let meterCapacity = AudioAnalysis.windowSize * 8
    /// 操作の列の長さ。2 のべき乗。
    private static let queueCapacity = 4096

    let sampleRate: Double

    // MARK: 主スレッド側

    private var reserved = 0
    /// 主スレッドが見ている繋がり (輪を作らないかを確かめるのに使う)。
    private var wiring = [UInt64](repeating: 0, count: SynthRack.capacity)
    private let slots: UnsafeMutablePointer<Unmanaged<RackNode>?>

    // MARK: 操作の列

    private let queue: UnsafeMutablePointer<SynthCommand>
    private let head = Atomic<Int>(0)
    private let tail = Atomic<Int>(0)

    // MARK: 音の側

    private var nodes = [RackNode?](repeating: nil, count: SynthRack.capacity)
    private var inputs = [UInt64](repeating: 0, count: SynthRack.capacity)
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
        buffers.deallocate()
        gathered.deallocate()
        zeros.deallocate()
    }

    // MARK: - 主スレッド: 節を足す

    /// 音源の節を足す。置き場が埋まっていれば `nil`。
    func addSource(_ kind: SourceNode.Kind) -> RackNode? {
        add { SourceNode(id: $0, sampleRate: sampleRate, meter: Self.makeMeter(), kind: kind) }
    }

    /// 濾波器の節を足す。
    func addFilter(_ shape: FilterShape) -> RackNode? {
        add { FilterNode(id: $0, sampleRate: sampleRate, meter: Self.makeMeter(), shape: shape) }
    }

    /// リバーブの節を足す。
    func addReverb() -> RackNode? {
        add { ReverbNode(id: $0, sampleRate: sampleRate, meter: Self.makeMeter()) }
    }

    /// ディレイの節を足す。
    func addDelay() -> RackNode? {
        add { DelayNode(id: $0, sampleRate: sampleRate, meter: Self.makeMeter()) }
    }

    private static func makeMeter() -> SampleRing {
        SampleRing(capacity: meterCapacity)
    }

    private func add(_ make: (Int) -> RackNode) -> RackNode? {
        guard reserved < Self.capacity else { return nil }
        let node = make(reserved)
        // 置き場へ書いてから列へ載せる。音の側は、列を読んだ後でだけ置き場を読む
        slots[reserved] = Unmanaged.passRetained(node)
        guard post(SynthCommand(op: .activate, node: UInt8(reserved))) else {
            slots[reserved]?.release()
            slots[reserved] = nil
            return nil
        }
        reserved += 1
        return node
    }

    // MARK: - 主スレッド: 操作を渡す

    /// 操作を列へ載せる。列が埋まっていれば `false`。
    @discardableResult
    func post(_ command: SynthCommand) -> Bool {
        let end = tail.load(ordering: .relaxed)
        guard end - head.load(ordering: .acquiring) < Self.queueCapacity else { return false }
        queue[end & (Self.queueCapacity - 1)] = command
        tail.store(end + 1, ordering: .releasing)
        return true
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
                if inputs[id] == 0, command.bits != 0 { nodes[id]?.reset() }
                inputs[id] = command.bits
                rebuild = true
            }
        }
        head.store(position, ordering: .releasing)
        if rebuild { rebuildPlan() }
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
