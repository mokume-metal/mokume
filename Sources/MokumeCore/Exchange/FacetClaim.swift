// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import Synchronization

/// 区画の要求に応える権利。**1 つの区画に応えるのは 1 プロセスだけである。**
///
/// 見張り (`watch`) は切り替えの瞬間だけ 2 世代の子を重ねる
/// ([#1150](https://github.com/mokume-metal/mokume/pull/1150))。権利を分けていなかった頃は
/// 両方の世代が同じ要求に応え、列の観測では**次の世代が撮り始めに前の世代の絵を消し、
/// 2 つの列が区画の上で並走した** — 実測では 50 回中 5 回で、`complete` の目録が別の世代の
/// 絵や存在しない絵を指した。エラーにも警告にもならない
/// ([#1162](https://github.com/mokume-metal/mokume/issues/1162))。
///
/// ## 先に居る世代が、消えるまで持つ
///
/// 権利は区画の中の錠ファイル (``WorkDirectory/claimURL(under:)``) への `flock` で表す。
/// 次の世代は、前の世代が消えて錠が外れた時点で引き継ぐ。
///
/// - **重なっている間に応えるのは前の世代である。** 画面に出ているのもそちらなので、
///   標準入力の宛先 (`WatchSession.send(_:)`) と揃う
/// - **退く側へは何も伝えない。** 錠はプロセスの終わりにカーネルが外す — `SIGTERM` で
///   即座に終わっても `SIGKILL` でも外れるので、道具からの合図も pid も要らない。`watch`
///   の外で同じ場所に 2 つ走らせたときにも同じ規則が効く
///
/// ## プロセスの中では 1 つを共有する
///
/// 世代はプロセスなので、権利の単位もプロセスである。`flock` は**開いた記述ごと**の錠で、
/// 同じプロセスでも開き直せば競合する — 区画ごとに記述を 1 つだけ開き、同じ区画を見る
/// 持ち手はそれを共有する。最後の持ち手が消えたら閉じる (検査が区画を大量に作っても
/// 記述が溜まらない)。
///
/// ## 確かめられなければ持っていることにする
///
/// 錠ファイルを作れない・`flock` が使えないファイルシステムでは、権利を分けずに応える。
/// **この型が無かった頃の振る舞いに倒す** — 応えないほうに倒すと、区画が黙って効かなくなる。
nonisolated final class FacetClaim: Sendable {
    private struct State {
        /// 開いた記述。まだ開いていなければ `nil`。
        var descriptor: Int32?
        var held = false
    }

    let url: URL
    private let state = Mutex(State())

    /// 区画ごとの持ち手。**弱く持つ** — 表が持ち続けると、最後の持ち手が消えても閉じない。
    private static let table = Mutex<[String: Weak]>([:])

    private struct Weak {
        weak var claim: FacetClaim?
    }

    private init(url: URL) {
        self.url = url
    }

    /// その区画の権利。同じプロセスで同じ区画を見る持ち手は、同じものを受け取る。
    static func shared(for facet: URL) -> FacetClaim {
        let url = WorkDirectory.claimURL(under: facet)
        let key = url.standardizedFileURL.path
        return table.withLock { table in
            if let existing = table[key]?.claim { return existing }
            let made = FacetClaim(url: url)
            table[key] = Weak(claim: made)
            return made
        }
    }

    /// 権利を持っているか。**持っていなければ、取りに行く。**
    ///
    /// 持った後は何もしない — 手放すのはプロセスが終わるときだけである。持つまでの
    /// 取りに行く費用は、錠を 1 回試すだけ (待たない)。
    func holds() -> Bool {
        state.withLock { state in
            if state.held { return true }
            if state.descriptor == nil {
                let opened = open(url.path, O_RDONLY | O_CREAT | O_CLOEXEC, 0o644)
                // 錠ファイルを置けない。確かめられないので持っていることにする
                guard opened >= 0 else {
                    state.held = true
                    return true
                }
                state.descriptor = opened
            }
            guard let descriptor = state.descriptor else { return true }
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 {
                state.held = true
                return true
            }
            // 他のプロセスが持っている。**それ以外の失敗は確かめられないので持っていることにする**
            guard errno == EWOULDBLOCK else {
                state.held = true
                return true
            }
            return false
        }
    }

    deinit {
        state.withLock { state in
            if let descriptor = state.descriptor { close(descriptor) }
        }
        let key = url.standardizedFileURL.path
        Self.table.withLock { table in
            // **自分の後に同じ区画で作られたものは消さない。** 弱い参照は解体中の自分を
            // 既に `nil` と読むので、`nil` のときだけ除く
            if table[key]?.claim == nil { table[key] = nil }
        }
    }
}
