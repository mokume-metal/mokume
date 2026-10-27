// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

/// 固定回帰は毎回、全探索は日次と版の前に同じ入力・判定で走らせる (#3338)。
/// 手元は `make test-geometry-exploration` (debug) / `make test-release` (release)。
/// 環境変数の付け忘れは、入口の XML 照合が skipped として赤にする。
nonisolated enum GeometryExploration {
    static let enabled = ProcessInfo.processInfo.environment["MOKUME_GEOMETRY_EXPLORATION"] == "1"
    static let reason: Comment = "全探索は make test-geometry-exploration / make test-release で実行する (#3338)"
}
