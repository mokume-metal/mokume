// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
import MokumeDiagnostics
import simd

/// 粒 1 つぶんの状態。
///
/// **GPU 側の同名の構造体と一致していなければならない**
/// (`Shaders/Computations/Particles.metal`)。ずれても例外は出ず、絵が「それらしく」
/// 壊れるだけなので、**一致は GPU 自身に自分の見ている配置を書かせて確かめる**
/// (`ParticleTests` の「配置」) — 大きさを手で書いた定数と突き合わせる形は、
/// 両側の手書きが同時にずれたときに黙って通る。
///
/// 全部が `Float` なのは詰め物を作らないためである。3 成分の組を混ぜると、CPU 側と
/// GPU 側で境界の揃え方が変わりうる。
struct Particle {
    var x: Float = 0
    var y: Float = 0
    var z: Float = 0
    var vx: Float = 0
    var vy: Float = 0
    var vz: Float = 0
    /// 残りの寿命 (秒)。**0 以下なら死んでいる。**
    var life: Float = 0
    /// 生まれたときの寿命。
    var span: Float = 0
    /// 大きさ (1 辺の長さ)。
    var size: Float = 0
    /// 塗り。**乗算済み** ([ADR-0012] — 作業空間は乗算済みで運ぶ)。
    ///
    /// [ADR-0012]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0012-alpha-semantics.md
    var red: Float = 0
    var green: Float = 0
    var blue: Float = 0
    var alpha: Float = 0
    /// 粒ごとの個体差。揺らぎが粒ごとに違う向きを向くための種。
    var seed: Float = 0
}

/// 端数を繰り越しながら、1 フレームに出す数を決める。
///
/// **繰り越さないと、低いレートで 1 個も出なくなる。** 毎秒 0.5 個を 60 分の 1 秒ずつ
/// 数えると毎回 0.008 個で、切り捨てれば永久に 0 である。しかも**単発の検査では出ない** —
/// 数百フレーム回して初めて「出るはずの数が出ていない」が見える。
struct EmissionCadence {
    /// まだ出していない端数。
    ///
    /// **倍精度で貯める。** 単精度だと 60 分の 1 秒を数百回足す間に誤差が積もり、
    /// 10 秒で 5 個出るはずのものが 4 個になる — 繰り越しを入れた意味が消える。
    private(set) var carried: Double = 0

    /// この 1 フレームで出す数。`limit` を超えるぶんは繰り越さずに捨てる。
    mutating func take(rate: Float, over seconds: Float, upTo limit: Int) -> Int {
        guard rate > 0, seconds > 0, rate.isFinite, seconds.isFinite, limit > 0 else {
            return 0
        }
        carried += Double(rate) * Double(seconds)
        guard carried >= 1 else { return 0 }
        let whole = carried.rounded(.down)
        guard whole < Double(limit) else {
            // **貯めたぶんを捨てる。** 捨てないと、容量を超える注文が続いたときに
            // 端数が際限なく積もり、レートを下げても出続ける
            carried = 0
            return limit
        }
        carried -= whole
        return Int(whole)
    }
}

/// たくさんの粒。
///
/// 使い方は ``Sketch/makeParticles(count:)`` にある。
///
/// ## 置き場は 3 本の数の並び
///
/// 状態・描画へ渡す置き場所・毎フレームの指定を、**既にある ``Numbers`` として持つ**。
/// 粒のために新しい置き場の仕組みを作らないので、計算の段の同期がそのまま効く
/// ([ADR-0023] 決定 3 — 同期の話を 2 つ持たない)。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
public final class Particles {
    /// 同時に持てる粒の数。
    public let capacity: Int

    /// 1 回に渡せる力の数。
    static let maximumForces = 8
    /// 指定の置き場の頭。**並びの正本はここ** — 読む側は
    /// `Shaders/Computations/Particles.metal` の冒頭にある。
    ///
    ///   [0…15] いまの変換 (4x4) / [16] 1 フレームの長さ / [17] フレーム番号 /
    ///   [18] 効かせる力の数 / [19] 予備 / [20…] 力 (1 つ ``Force/slotCount`` 個)
    static let headerFloats = 20

    /// 粒の状態。
    let state: Numbers
    /// 描画へ渡す置き場所の並び。``SolidInstance`` と同じ並びを数として持つ。
    let instances: Numbers
    /// 毎フレームの指定 (変換と力)。
    let parameters: Numbers
    /// 粒 1 つを描く形。**保持した形をそのまま使う**ので、粒だけ別の頂点経路を持たない。
    let quad: Shape
    /// 1 フレーム進める計算。
    let update: Computation

    /// 次に書き込む枠。**環状に回る。**
    private var cursor = 0
    private var cadence = EmissionCadence()
    /// 枠ごとの「いつまで生きるか」。
    ///
    /// **CPU だけが読む。** 寿命を配ったのは CPU なので、GPU から読み戻さなくても
    /// 「まだ生きている粒を上書きした」が分かる。
    private var deadline: [Float]
    /// 生きている粒を上書きしたことを知らせたか。**検査が読む。**
    private(set) var warnedOverwrite = false
    private(set) var warnedTooManyForces = false
    /// この フレームで積まれた力。**進めるときに空になる。**
    private var pendingForces: [Force] = []

    init(
        capacity: Int, state: Numbers, instances: Numbers, parameters: Numbers,
        quad: Shape, update: Computation
    ) {
        self.capacity = capacity
        self.state = state
        self.instances = instances
        self.parameters = parameters
        self.quad = quad
        self.update = update
        self.deadline = Array(repeating: -.greatestFiniteMagnitude, count: capacity)
    }

    /// 力を積む。**上限を超えたぶんは受け取らない** — 進めずに積み続けても際限なく
    /// 増えないようにするため。
    func add(_ forces: [Force]) {
        for force in forces {
            guard pendingForces.count < Self.maximumForces else {
                return warnTooManyForces(pendingForces.count + 1)
            }
            pendingForces.append(force)
        }
    }

    /// 積まれた力を取り出して空にする。
    func takeForces() -> [Force] {
        defer { pendingForces.removeAll(keepingCapacity: true) }
        return pendingForces
    }

    /// この 1 フレームで出す数。
    func count(rate: Float, over seconds: Float) -> Int {
        cadence.take(rate: rate, over: seconds, upTo: capacity)
    }

    /// 粒を `count` 個置く。
    ///
    /// **書く直前に GPU の完了を待つ。** 前のフレームで頼んだ計算がまだ同じ場所を
    /// 読んでいるかもしれない — 描き切りは待たずに返る (#727) — ので、待ってから
    /// 書く。全部終わっていれば待ちは無い。かつては「フレームの末尾が必ず待つ」ことに
    /// 寄りかかっていたが、その前提はもう無い。
    func emit(
        _ count: Int, from source: Emitter, speed: ClosedRange<Float>,
        angle: ClosedRange<Float>, life: ClosedRange<Float>, size: ClosedRange<Float>,
        color: LinearRGBA, at now: Float, using randomness: inout Randomness
    ) {
        guard count > 0 else { return }
        state.gpu.settleQuietly(before: "粒を置く")
        let slots = state.storage.contents().assumingMemoryBound(to: Particle.self)
        for _ in 0..<count {
            let slot = cursor % capacity
            cursor += 1
            if deadline[slot] > now { warnOverwrite() }

            let place = source.sample(using: &randomness)
            let heading = randomness.value(from: angle.lowerBound, to: angle.upperBound)
            let rate = randomness.value(from: speed.lowerBound, to: speed.upperBound)
            let span = max(0, randomness.value(from: life.lowerBound, to: life.upperBound))
            let extent = max(0, randomness.value(from: size.lowerBound, to: size.upperBound))

            slots[slot] = Particle(
                x: place.x, y: place.y, z: place.z,
                vx: cos(heading) * rate, vy: sin(heading) * rate, vz: 0,
                life: span, span: span, size: extent,
                red: color.red, green: color.green, blue: color.blue, alpha: color.alpha,
                seed: randomness.unitValue())
            deadline[slot] = now + span
        }
    }

    /// この 1 フレームの指定を置く。
    ///
    /// **数値も同じ置き場から渡す。** 計算に値を渡す口 (`Values`) を使うと、値を渡さない
    /// 形で組み立てるビルド時のシェーダ検査から外れてしまう — 組み込みの計算こそ、
    /// 走らせる前に壊れていることが分かってほしい。
    func write(transform: simd_float4x4, step: Float, frame: Int, forces: [Force]) {
        // 前のフレームの計算がまだ指定を読んでいるかもしれない。書く直前に待つ (#727)
        parameters.gpu.settleQuietly(before: "粒の指定を書く")
        let values = parameters.storage.contents().assumingMemoryBound(to: Float.self)
        for column in 0..<4 {
            let vector = transform[column]
            for row in 0..<4 { values[column * 4 + row] = vector[row] }
        }
        if forces.count > Self.maximumForces { warnTooManyForces(forces.count) }
        let used = min(forces.count, Self.maximumForces)
        values[16] = step
        values[17] = Float(frame)
        values[18] = Float(used)
        values[19] = 0
        for (index, force) in forces.prefix(used).enumerated() {
            for (offset, value) in force.packed.enumerated() {
                values[Self.headerFloats + index * Force.slotCount + offset] = value
            }
        }
    }

    /// 生きている粒を、番号の順に読む。**参照の描画経路だけが使う。**
    func living(from values: [Float]) -> [Placement] {
        var places: [Placement] = []
        places.reserveCapacity(capacity / 8)
        values.withUnsafeBytes { raw in
            let slots = raw.bindMemory(to: Particle.self)
            for index in 0..<min(capacity, slots.count) {
                let particle = slots[index]
                guard particle.life > 0 else { continue }
                places.append(
                    Placement(
                        x: particle.x, y: particle.y, z: particle.z, scale: particle.size,
                        fill: LinearRGBA(
                            premultipliedRed: particle.red, green: particle.green,
                            blue: particle.blue, alpha: particle.alpha)))
            }
        }
        return places
    }

    private func warnOverwrite() {
        guard !warnedOverwrite else { return }
        warnedOverwrite = true
        Diagnostics.warn(
            "粒の枠 \(capacity) 個をひと回りして、まだ生きている粒を上書きしました。"
                + "出す数 (rate) × 寿命 (life) が枠より多いので、"
                + "makeParticles(count:) を増やすか、rate か life を下げてください")
    }

    private func warnTooManyForces(_ count: Int) {
        guard !warnedTooManyForces else { return }
        warnedTooManyForces = true
        Diagnostics.warn(
            "1 回に渡せる力は \(Self.maximumForces) 個までです (\(count) 個渡されました)。"
                + "先頭から \(Self.maximumForces) 個だけ効かせました")
    }
}
