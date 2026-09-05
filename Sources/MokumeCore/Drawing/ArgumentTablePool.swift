// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Metal

/// 位置ごとの引数テーブルを、要るところまで伸ばしながら貸す。
///
/// **位置ごとに 1 枚を持ち、要るところまで伸ばしてからは作り直さない** ([ADR-0023] 決定 5)。
/// 1 枚を使い回して番地を書き換えると、走っている段の足元で束ね先が変わる。
///
/// **計算の段と効果の段が同じものを持つ** ([#949](https://github.com/mokume-metal/mokume/issues/949))。
/// 以前は 2 つの実装が並んでおり、失敗の言い方だけが割れていた — 片方は土台の理由を
/// そのまま渡し、もう片方は「効果の段 N 枚目」という場所だけの文言に差し替えていて、
/// **なぜ作れなかったかが読み手に届かなかった**。土台の理由を渡す側に揃えてある。
///
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
struct ArgumentTablePool {
    private let gpu: RenderDevice
    private let label: String
    private let bufferBindCount: Int
    private let textureBindCount: Int
    private var tables: [any MTL4ArgumentTable] = []
    /// テーブルを作った回数 (組んでから通算)。**毎フレーム確保していないことを数える。**
    ///
    /// 読むのは検査である — `ParticleTests`「長く回しても、置き場の確保が積み上がらない」と
    /// `UpscaleTests`「長く回しても、段の置き場が積み上がらない」が、回す前後でこの数が
    /// 動かないことを見ている。**数が動かないことがそのまま ADR-0023 決定 5 の担保になる。**
    private(set) var built = 0

    /// - Parameters:
    ///   - label: テーブルの名前の前置き。`"<label>.<位置>"` が土台へ渡る
    ///   - bufferBindCount: 束ねる置き場の上限
    ///   - textureBindCount: 束ねる面の上限。既定の 0 は
    ///     `MTL4ArgumentTableDescriptor` の初期値と同じで、面を束ねない段のためのもの
    init(gpu: RenderDevice, label: String, bufferBindCount: Int, textureBindCount: Int = 0) {
        self.gpu = gpu
        self.label = label
        self.bufferBindCount = bufferBindCount
        self.textureBindCount = textureBindCount
    }

    /// 位置に対応するテーブル。**足りなければ伸ばす。**
    mutating func table(at index: Int) throws(RenderFailure) -> any MTL4ArgumentTable {
        while tables.count <= index {
            let descriptor = MTL4ArgumentTableDescriptor()
            descriptor.label = "\(label).\(tables.count)"
            descriptor.maxBufferBindCount = bufferBindCount
            descriptor.maxTextureBindCount = textureBindCount
            do {
                tables.append(try gpu.device.makeArgumentTable(descriptor: descriptor))
            } catch {
                throw .argumentTableUnavailable(reason: error.localizedDescription)
            }
            built += 1
        }
        return tables[index]
    }
}
