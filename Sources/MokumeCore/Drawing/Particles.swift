// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal
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
/// ## 置き場はすべて数の並び
///
/// 状態・描画へ渡す置き場所・毎フレームの指定・生存数を数える段・描く引数を、**既にある
/// ``Numbers`` として持つ**。粒のために新しい置き場の仕組みを作らないので、計算の段の
/// 同期も、書き込みを描き切りが届ける控え (#749) もそのまま効く ([ADR-0023] 決定 3 —
/// 同期の話を 2 つ持たない)。
///
/// ## 描く個数は GPU が決める
///
/// 死んだ粒の枠を頂点段に通さないよう、生きている粒だけを**枠の番号順に**詰めて置き、
/// 個数は indirect draw の引数として GPU が書く ([#760])。詰める順序を固定するのは、
/// 半透明の粒が奥行きつきで描かれるためで、順序が動けば重なりが動いて絵が動く。
/// 順位は並列スキャン (prefix sum) で求める — 結果が実行順に依らないので、同じ入力
/// からは同じ絵が出る。段の数は容量から決まり、1 段が 256 倍を数える。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
/// [#760]: https://github.com/mokume-metal/mokume/issues/760
public final class Particles {
    /// 同時に持てる粒の数。
    public let capacity: Int

    /// 1 回に渡せる力の数。
    static let maximumForces = 8
    /// 指定の置き場の頭。**並びの正本はここ** — 読む側は
    /// `Shaders/Computations/Particles.metal` の冒頭にある。
    ///
    ///   [0…15] いまの変換 (4x4) / [16] 1 フレームの長さ / [17] フレーム番号 /
    ///   [18] 効かせる力の数 / [19] スキャンの段の数 / [20] 描く頂点の頭 /
    ///   [21] 描く頂点の数 / [22…26] 段 0…4 の置き場の頭 /
    ///   [27…35] 視点の枠 (横・上・手前を 3 つずつ。``Camera/basis``) / [36…39] 予備 /
    ///   [40…] 力 (1 つ ``Force/slotCount`` 個)
    ///
    /// [19…26] の整数は `UInt32` のビット列として置く (`Float` に直すと 2^24 を超えた
    /// ところで丸まる)。
    static let headerFloats = 40
    /// 視点の枠の頭。
    static let basisOffset = 27
    /// スキャンの区画の大きさ。**GPU 側の `MOKUME_PARTICLE_BLOCK` と一致していなければ
    /// ならない** (一致は `ParticleTests` の「配置」が見る)。
    static let scanBlock = 256
    /// 段の置き場の頭を渡せる数 (段 0…4)。256^4 = 2^32 個までの粒を数えられる —
    /// `UInt32` で数える上限と同じところで尽きる。
    static let maximumLevels = 5
    /// 描く引数の長さ (`MTLDrawPrimitivesIndirectArguments` の 4 語)。
    static let argumentFloats = 4

    /// 粒の状態。
    let state: Numbers
    /// 描画へ渡す置き場所の並び。``SolidInstance`` と同じ並びを数として持つ。
    /// **先頭から生存数ぶんだけが意味を持つ。**
    let instances: Numbers
    /// 毎フレームの指定 (変換と力)。
    let parameters: Numbers
    /// 生存数を数える段の置き場。段 k は ``levelLengths`` の k 番目の長さで、
    /// ``levelOffsets`` の位置から並ぶ。**最上段は 1 個で、それが生存数。**
    let levels: Numbers
    /// 段ごとの頭 [長さ, 読む段の頭, 書く段の頭]。**作るときに 1 度書く。**
    let levelHeaders: [Numbers]
    /// 描く引数 (`MTLDrawPrimitivesIndirectArguments` と同じ並び)。GPU が書き、描く側が
    /// そのまま indirect draw に渡す。**CPU は読まない。**
    let arguments: Numbers
    /// 段ごとの長さ。先頭が容量、末尾が 1。
    let levelLengths: [Int]
    /// 段ごとの、``levels`` の中での頭。
    let levelOffsets: [Int]
    /// 粒 1 つを描く形。**保持した形をそのまま使う**ので、粒だけ別の頂点経路を持たない。
    let quad: Shape
    /// 生き残る粒に旗を立てる計算。
    let flag: Computation
    /// 旗を数える 1 段ぶんの計算。段の数だけ積む。
    let scan: Computation
    /// 1 フレーム進めて、生き残る粒を詰めて置く計算。
    let update: Computation

    /// 1 フレームに積む計算の数。旗 1 + 段の数 + 進める 1。
    var dispatchCount: Int { 2 + scanCount }
    /// スキャンの段の数。容量 1 なら 0 (旗そのものが生存数)。
    var scanCount: Int { levelLengths.count - 1 }

    /// 段ごとの長さ。**容量から一意に決まる** — 256 で割り上げて 1 になるまで重ねる。
    static func levelLengths(capacity: Int) -> [Int] {
        var lengths = [max(1, capacity)]
        while let last = lengths.last, last > 1 {
            lengths.append((last + scanBlock - 1) / scanBlock)
        }
        return lengths
    }

    /// 次に書き込む枠。**環状に回る。**
    ///
    /// **検査が読む。**
    private(set) var cursor = 0
    private var cadence = EmissionCadence()
    /// 枠ごとの「いつまで生きるか」。
    ///
    /// **CPU だけが読む。** 寿命を配ったのは CPU なので、GPU から読み戻さなくても
    /// 「まだ生きている粒を上書きした」が分かる。
    private var deadline: [Float]
    /// この フレームで積まれた力。**進めるときに空になる。**
    private var pendingForces: [Force] = []

    /// 1 度だけ言う注意の種類。仕組みは ``WarningLog`` が持つ ([#734])。
    ///
    /// [#734]: https://github.com/mokume-metal/mokume/issues/734
    enum Warning: Hashable {
        /// まだ生きている粒を上書きした。
        case overwrite
        /// 効かせられる数を超えた力を渡された。
        case tooManyForces
    }

    /// 言った注意の控え。**検査が読む。**
    private(set) var warnings = WarningLog<Warning>()

    /// まだ言っていなければ、その注意を 1 度だけ言う。
    private func warnOnce(_ warning: Warning, _ message: @autoclosure () -> String) {
        warnings.warnOnce(warning, message())
    }

    init(
        capacity: Int, state: Numbers, instances: Numbers, parameters: Numbers,
        levels: Numbers, levelHeaders: [Numbers], arguments: Numbers, levelLengths: [Int],
        quad: Shape, flag: Computation, scan: Computation, update: Computation
    ) {
        self.capacity = capacity
        self.state = state
        self.instances = instances
        self.parameters = parameters
        self.levels = levels
        self.levelHeaders = levelHeaders
        self.arguments = arguments
        self.levelLengths = levelLengths
        var offsets: [Int] = []
        var offset = 0
        for length in levelLengths {
            offsets.append(offset)
            offset += length
        }
        self.levelOffsets = offsets
        self.quad = quad
        self.flag = flag
        self.scan = scan
        self.update = update
        self.deadline = Array(repeating: -.greatestFiniteMagnitude, count: capacity)

        // 段の頭は容量から決まるので、**ここで 1 度だけ書く**。控えに積まれ、最初の
        // 描き切りが計算より前に届ける
        for (level, header) in levelHeaders.enumerated() {
            header.set([
                Float(bitPattern: UInt32(levelLengths[level])),
                Float(bitPattern: UInt32(levelOffsets[level])),
                Float(bitPattern: UInt32(levelOffsets[level + 1])),
                0,
            ])
        }
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
    /// **待たない。** 状態の並びへの書き込みは控えに積まれ、描き切りが計算より前に
    /// GPU 側のコピーで届ける ([#749])。前のフレームの計算がまだ同じ並びを読み書き
    /// していても、コピーはそれが終わってから走る — かつては書く直前に投入済みの全部を
    /// 待っていて、粒を使うフレームでは CPU と GPU が重ならなかった。
    ///
    /// 枠と寿命はここで進む。控えは描き切りが待てなくても捨てずに持ち越す ([#934]) ので、
    /// 進めた枠は必ずいつか書かれる。
    ///
    /// [#749]: https://github.com/mokume-metal/mokume/issues/749
    /// [#934]: https://github.com/mokume-metal/mokume/issues/934
    func emit(
        _ count: Int, from source: Emitter, speed: ClosedRange<Float>,
        angle: ClosedRange<Float>, life: ClosedRange<Float>, size: ClosedRange<Float>,
        color: LinearRGBA, at now: Float, using randomness: inout Randomness
    ) {
        guard count > 0 else { return }
        let floats = Self.particleFloats
        for _ in 0..<count {
            let slot = cursor % capacity
            cursor += 1
            if deadline[slot] > now { warnOverwrite() }

            let place = source.sample(using: &randomness)
            let heading = randomness.value(from: angle.lowerBound, to: angle.upperBound)
            let rate = randomness.value(from: speed.lowerBound, to: speed.upperBound)
            let span = max(0, randomness.value(from: life.lowerBound, to: life.upperBound))
            let extent = max(0, randomness.value(from: size.lowerBound, to: size.upperBound))

            let particle = Particle(
                x: place.x, y: place.y, z: place.z,
                vx: cos(heading) * rate, vy: sin(heading) * rate, vz: 0,
                life: span, span: span, size: extent,
                red: color.red, green: color.green, blue: color.blue, alpha: color.alpha,
                seed: randomness.unitValue())
            // **区間を丸ごと書く** (`Numbers.write` の約束)。粒は全部が `Float` なので
            // 詰め物が無く、並びの 1 区画がそのまま粒 1 つになる
            state.write(at: slot * floats, count: floats) { target in
                withUnsafeBytes(of: particle) { raw in
                    _ = target.update(fromContentsOf: raw.bindMemory(to: Float.self))
                }
            }
            deadline[slot] = now + span
        }
    }

    /// 粒 1 つが並びの中で占める数。
    static let particleFloats = MemoryLayout<Particle>.stride / MemoryLayout<Float>.stride

    /// この 1 フレームの指定を置く。
    ///
    /// **数値も同じ置き場から渡す。** 計算に値を渡す口 (`Values`) を使うと、値を渡さない
    /// 形で組み立てるビルド時のシェーダ検査から外れてしまう — 組み込みの計算こそ、
    /// 走らせる前に壊れていることが分かってほしい。
    ///
    /// `vertexStart` / `vertexCount` は描く側が四角を置いた区間で、GPU がそのまま描く引数へ
    /// 写す。参照の経路 (CPU が置く) では使われないので 0 でよい。
    ///
    /// `basis` は視点の枠 (``Camera/basis``) で、GPU が板をそれに沿って置く。
    ///
    /// **待たない。** 粒を置くのと同じく控えに積み、描き切りが届ける (#749)。
    func write(
        transform: simd_float4x4, basis: simd_float3x3, step: Float, frame: Int,
        forces: [Force], vertexStart: Int, vertexCount: Int
    ) {
        if forces.count > Self.maximumForces { warnTooManyForces(forces.count) }
        let used = min(forces.count, Self.maximumForces)
        // 読まれるのは頭と、効かせる数ぶんの力だけ。**書く区間はそこまでで、全部を書く**
        parameters.write(at: 0, count: Self.headerFloats + used * Force.slotCount) { values in
            for column in 0..<4 {
                let vector = transform[column]
                for row in 0..<4 { values[column * 4 + row] = vector[row] }
            }
            values[16] = step
            values[17] = Float(frame)
            values[18] = Float(used)
            // 整数は **ビット列のまま**置く (上の `headerFloats` の理由)
            values[19] = Float(bitPattern: UInt32(scanCount))
            values[20] = Float(bitPattern: UInt32(clamping: vertexStart))
            values[21] = Float(bitPattern: UInt32(clamping: vertexCount))
            for slot in 0..<Self.maximumLevels {
                let offset = slot < levelOffsets.count ? levelOffsets[slot] : 0
                values[22 + slot] = Float(bitPattern: UInt32(offset))
            }
            for column in 0..<3 {
                let vector = basis[column]
                for row in 0..<3 { values[Self.basisOffset + column * 3 + row] = vector[row] }
            }
            for index in (Self.basisOffset + 9)..<Self.headerFloats { values[index] = 0 }
            for (index, force) in forces.prefix(used).enumerated() {
                for (offset, value) in force.packed.enumerated() {
                    values[Self.headerFloats + index * Force.slotCount + offset] = value
                }
            }
        }
    }

    /// 生きている粒の置き場所を、番号の順に作る。**参照の描画経路と検査が使う。**
    ///
    /// GPU の `mokume_particles` と**同じ式**で組む (``billboard(x:y:z:size:transform:basis:)``)。
    func living(
        from values: [Float], transform: simd_float4x4, basis: simd_float3x3
    ) -> [SolidInstance] {
        var places: [SolidInstance] = []
        places.reserveCapacity(capacity / 8)
        values.withUnsafeBytes { raw in
            let slots = raw.bindMemory(to: Particle.self)
            for index in 0..<min(capacity, slots.count) {
                let particle = slots[index]
                guard particle.life > 0 else { continue }
                places.append(
                    SolidInstance(
                        matrix: Self.billboard(
                            x: particle.x, y: particle.y, z: particle.z, size: particle.size,
                            transform: transform, basis: basis),
                        normalMatrix: basis,
                        color: LinearRGBA(
                            premultipliedRed: particle.red, green: particle.green,
                            blue: particle.blue, alpha: particle.alpha)))
            }
        }
        return places
    }

    /// 粒 1 つの板を置く行列。**板は視点の枠に沿う** (#1043)。
    ///
    /// 板の縦横は視点の横・上へ向け、変換からは**各軸の倍率 (列の長さ) だけ**を受け取る。
    /// 変換の回転まで受け取ると、視点を回したときと同じく `rotateY()` で雲ごと回した
    /// ときにも板が横を向いて痩せる。位置だけは変換をそのまま通す。
    ///
    /// 既定の視点では枠が厳密に単位行列で、回さない変換の列の長さも厳密に倍率なので、
    /// 板を軸に沿って置いていた頃と**値が 1 ビットも変わらない**。
    ///
    /// **GPU 側 (`Shaders/Computations/Particles.metal`) と同じ式でなければならない。**
    static func billboard(
        x: Float, y: Float, z: Float, size: Float, transform: simd_float4x4,
        basis: simd_float3x3
    ) -> simd_float4x4 {
        func span(_ column: SIMD4<Float>) -> Float {
            length(SIMD3(column.x, column.y, column.z))
        }
        let center = transform * SIMD4(x, y, z, 1)
        return simd_float4x4(
            SIMD4(basis.columns.0 * (size * span(transform.columns.0)), 0),
            SIMD4(basis.columns.1 * (size * span(transform.columns.1)), 0),
            SIMD4(basis.columns.2 * (size * span(transform.columns.2)), 0),
            center)
    }

    private func warnOverwrite() {
        warnOnce(
            .overwrite,
            "The ring of \(capacity) particle slots came all the way round and overwrote particles "
                + "that were still alive. rate × life is larger than the ring, so raise "
                + "makeParticles(count:), or lower rate or life")
    }

    private func warnTooManyForces(_ count: Int) {
        warnOnce(
            .tooManyForces,
            "At most \(Self.maximumForces) forces can go in one call (\(count) were passed). "
                + "Only the first \(Self.maximumForces) took effect")
    }
}
