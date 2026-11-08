// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 試作 (#3811): 公開の範囲は Double で受け、中では Float の範囲に直す。
nonisolated extension ClosedRange where Bound == Double {
    var asFloatRange: ClosedRange<Float> { Float(lowerBound)...Float(upperBound) }
}
