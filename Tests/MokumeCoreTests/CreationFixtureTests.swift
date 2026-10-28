// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

/// ``creating(_:sourceLocation:)`` 自身の検査 (#3345)。
///
/// 補助が失敗を記録しなくなると、作る口が壊れても検査は黙って緑に戻る。
/// 記録を外せば、ここが赤になる。
@Suite("検査の対象を作る口の補助")
struct CreationFixtureTests {
    struct Broken: Error, CustomStringConvertible {
        var description: String { "壊れた口のしるし" }
    }

    @Test("作る口が throw したら、失敗を記録して nil を返す")
    func recordsAndReturnsNilWhenTheMakerThrows() {
        var made: Int? = 0
        // 記録されなければ「既知の問題が記録されなかった」で赤になる
        withKnownIssue {
            made = creating { throw Broken() }
        }
        #expect(made == nil)
    }

    @Test("記録は、補助の中ではなく呼んだ行に付く")
    func theIssueIsRecordedOnTheCallersLine() {
        // 行が違う記録は既知の問題に数えず、そのまま赤にする。呼ぶ行は、次の 1 行
        let callerLine = #line + 1
        withKnownIssue { _ = creating { throw Broken() } } matching: { $0.sourceLocation?.line == callerLine }
    }

    @Test("記録の文面に、作る口が投げた元の失敗が入る")
    func theIssueCarriesTheOriginalError() {
        withKnownIssue {
            _ = creating { throw Broken() }
        } matching: { issue in
            String(describing: issue).contains("壊れた口のしるし")
        }
    }

    @Test("作る口が throw しなければ、値を返して何も記録しない")
    func returnsTheValueAndRecordsNothingWhenTheMakerSucceeds() {
        // 何か記録されれば、この検査自身が赤になる
        let made = creating { 42 }
        #expect(made == 42)
    }
}
