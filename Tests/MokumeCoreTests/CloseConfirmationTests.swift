// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Testing

@testable import MokumeCore

/// 窓の × を押した人に確かめる合図 ([#1120](https://github.com/mokume-metal/mokume/issues/1120))。
///
/// **窓を建てずに見る。** ここで見たいのは「合図をどう読み、何と言うか」であって、窓の
/// 建ち方ではない — そちらは `SketchApplicationTests` が実際の窓で見る。
@Suite("窓の × を確かめる合図")
struct CloseConfirmationTests {
    @Test("合図が無ければ、問いを持たない")
    func noSignalMeansNoQuestion() {
        #expect(CloseConfirmation.startupQuestion(environment: [:]) == nil)
    }

    /// **空白だけの値は、書かれていないものとして扱う。** 環境変数は空で渡されうるので、
    /// 中身の無い名乗りで「\() ends with it.」という文を作らない。
    @Test("空白だけの値は、渡されていないものとして扱う")
    func blankSignalIsNotASignal() {
        #expect(CloseConfirmation.tool(environment: [key: "   "]) == nil)
        #expect(CloseConfirmation.startupQuestion(environment: [key: " \n "]) == nil)
        #expect(CloseConfirmation.tool(environment: [key: " mokume run "]) == "mokume run")
    }

    /// **押した後どうなるかは、起こし方で違う。** 名乗りを文面へ入れるのはそのためで、
    /// 入っていなければ「窓を閉じたら端末の道具も終わる」ことが誰にも伝わらない。
    @Test("問いの文面に、渡した道具の名乗りが入る")
    func theQuestionNamesTheTool() throws {
        let question = try #require(
            CloseConfirmation.startupQuestion(environment: [key: "mokume run"]))
        #expect(question.detail.contains("mokume run"))
        #expect(!question.message.isEmpty)
        // **倒れる先は続ける側である。** 綴りは出し方 (`CloseQuestion.presentSheet`) が
        // ボタンの順序で担うので、ここでは両方が別の言葉であることだけを見る
        #expect(question.confirm != question.cancel)
    }

    /// **綴りの正典は一覧である** ([StartupReads])。読み手が書き写すと、一覧を動かしても
    /// 読み手が古い綴りを見続ける。
    @Test("合図は道具が決めるものとして、一覧に載っている")
    func theSignalIsOnTheList() {
        #expect(StartupReads.closeConfirmation.origin == .environment)
        #expect(StartupReads.closeConfirmation.decidedBy == .tool)
        #expect(StartupReads.all.contains { $0.key == key })
    }

    private var key: String { StartupReads.closeConfirmation.key }
}
