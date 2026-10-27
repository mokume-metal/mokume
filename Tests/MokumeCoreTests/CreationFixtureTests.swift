// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

/// ``creating(_:sourceLocation:)`` 自身の検査 (#3345)。
///
/// 補助が失敗を記録しなくなると、作る口が壊れても検査は黙って緑に戻る。
/// 記録を外せば、ここが赤になる。
@Suite("検査の対象を作る口の補助")
struct CreationFixtureTests {
    struct Broken: Error {}

    @Test("作る口が throw したら、失敗を記録して nil を返す")
    func recordsAndReturnsNilWhenTheMakerThrows() {
        var made: Int? = 0
        // 記録されなければ「既知の問題が記録されなかった」で赤になる
        withKnownIssue {
            made = creating { throw Broken() }
        }
        #expect(made == nil)
    }

    @Test("作る口が throw しなければ、値を返して何も記録しない")
    func returnsTheValueAndRecordsNothingWhenTheMakerSucceeds() {
        // 何か記録されれば、この検査自身が赤になる
        let made = creating { 42 }
        #expect(made == 42)
    }
}
