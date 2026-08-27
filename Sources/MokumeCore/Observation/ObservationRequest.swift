// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 外から置かれる、1 枚の観測の要求。
///
/// 形の正典は `Schemas/observe-request.schema.json`。**知らない鍵は無視する**
/// ([ADR-0018] 決定 3) ので、書き手が新しい鍵を足しても古い実装は壊れない。
///
/// [ADR-0018]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0018-observation-and-control-surface.md
public struct ObservationRequest: Decodable, Equatable, Sendable {
    /// この要求の識別子。応答はこれを echo する。
    public let id: String
    /// 書き出す画像の縮小率 (1 = 実寸)。
    public let scale: Double

    public init(id: String, scale: Double = 1) {
        self.id = id
        self.scale = scale
    }

    private enum CodingKeys: String, CodingKey {
        case id, scale
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.scale = try container.decodeIfPresent(Double.self, forKey: .scale) ?? 1
    }
}
