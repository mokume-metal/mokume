// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics

/// 描画コア — 基盤層にのみ依存する ([ADR-0016] 決定 1)。
///
/// 描画 API はここに載るが、骨格の段階では層の構造だけを持つ。
/// 何をどう描くかは実際の作品制作で必要になった順に設計する ([ADR-0001] 原則 4)。
///
/// [ADR-0016]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0016-package-structure.md
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
public enum Mokume {
    /// 依存が下の層へ向かっていることを示すだけの目印。
    /// 描画コアに最初の実 API が入った時点で消す。
    public static let foundationLayerName = Diagnostics.layerName
}
