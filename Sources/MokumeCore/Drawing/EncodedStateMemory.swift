// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 溜めた列を積むとき、encoder と引数表に**最後に設定した値**の記録 ([#2364])。
///
/// 列ごとに状態を全部設定し直すと、列が多い絵で固定費が積み上がる (矩形 2 万本の交互で
/// submit だけ 21 ms)。前の列と同じ値の設定し直しは、積む側が `changes…` で問い、`true` の
/// ときだけ呼ぶ。**問うことが記録を更新する** — 呼ばずに記録だけを進めると、encoder の状態と
/// 食い違う。
///
/// 記録は積む呼び出し (`Canvas.encodeBatches`) ごとに空から始める。引数表は Canvas が使い回し、
/// 前の encoder (影の焼き付け・控えへの描き切り) が別の値を束ねているので、前の呼び出しの
/// 設定を当てにしない。空の記録に問えば、どの設定も `true` (= 設定する) になる。
///
/// **記録が写すのは引数表の中身である。** 基本図形の列のように束ねない口があっても、その口の
/// 記録は動かない (引数表の中身が動かないため)。
///
/// [#2364]: https://github.com/mokume-metal/mokume/issues/2364
struct EncodedStateMemory {
    private var addresses: [UInt64?]
    private var textures: [ObjectIdentifier?]
    private var pipeline: ObjectIdentifier?
    private var depth: ObjectIdentifier??
    private var frontFacing: MTLWinding?
    private var cullMode: MTLCullMode?
    private var clip: Canvas.ClipRect??

    init(
        bufferSlots: Int = ShapePipeline.bufferBindCount,
        textureSlots: Int = ShapePipeline.textureBindCount
    ) {
        addresses = Array(repeating: nil, count: bufferSlots)
        textures = Array(repeating: nil, count: textureSlots)
    }

    /// その口に束ねる番地が、最後に束ねたものと違うか。
    mutating func changes(address: UInt64, index: Int) -> Bool {
        guard addresses[index] != address else { return false }
        addresses[index] = address
        return true
    }

    /// その口に束ねる面が、最後に束ねたものと違うか。**面の同一性で比べる** (``HeldTexture`` の
    /// 比べ方と同じ) ので、`gpuResourceID` の取得も省ける。
    mutating func changes(texture: ObjectIdentifier, index: Int) -> Bool {
        guard textures[index] != texture else { return false }
        textures[index] = texture
        return true
    }

    /// パイプラインの状態が、最後に設定したものと違うか。**同一性で比べる。**
    mutating func changes(pipeline identity: ObjectIdentifier) -> Bool {
        guard pipeline != identity else { return false }
        pipeline = identity
        return true
    }

    /// 深度の状態が、最後に設定したものと違うか。**状態なし (`nil`) も 1 つの値**である。
    mutating func changes(depth identity: ObjectIdentifier?) -> Bool {
        guard depth != Optional(identity) else { return false }
        depth = Optional(identity)
        return true
    }

    mutating func changes(frontFacing winding: MTLWinding) -> Bool {
        guard frontFacing != winding else { return false }
        frontFacing = winding
        return true
    }

    mutating func changes(cullMode mode: MTLCullMode) -> Bool {
        guard cullMode != mode else { return false }
        cullMode = mode
        return true
    }

    /// 切り抜きが、最後に設定したものと違うか。**切り抜きなし (`nil`) も 1 つの値**である。
    mutating func changes(clip rect: Canvas.ClipRect?) -> Bool {
        guard clip != Optional(rect) else { return false }
        clip = Optional(rect)
        return true
    }

    /// 捨て方を忘れる。置き場所ごとに捨て方を変えて描く経路 (`Canvas.encodeBackThenFront`) が
    /// encoder の捨て方を書き換えるので、通った後は列の捨て方を設定し直す。
    mutating func forgetCullMode() {
        cullMode = nil
    }
}
