// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 基盤層 — 何にも依存しない要素だけを置く ([ADR-0016] 決定 1 の最下層)。
///
/// 骨格の段階では、層が存在し依存の向きが成立していることを示す以上のものを持たない。
/// 診断・ログの具体は、実際に必要になった時点で設計する ([ADR-0001] 原則 4)。
///
/// [ADR-0016]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0016-package-structure.md
/// [ADR-0001]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0001-founding-principles.md
public enum Diagnostics {
    /// 層の名前。骨格が組み上がっていることを示すだけの目印で、
    /// この層に最初の実 API が入った時点で消す。
    public static let layerName = "foundation"
}
