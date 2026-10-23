// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeDiagnostics
import Synchronization

/// 「初回だけ知らせる」注意の控え。
///
/// ## なぜ 1 つの型に畳むのか
///
/// 毎フレーム起きうる事情は繰り返さない (``Diagnostics/warn(_:)`` の但し書き)。その
/// 規律を旗で守ると、注意 1 種類につき `Bool` の宣言・`guard`・代入の 3 か所が要り、
/// `Drawing` だけで 31 個並んでいた ([#734])。**控えを 1 つ持って種類を鍵で数えれば、
/// 注意を足すときに増えるのは鍵 1 つと呼び出し 1 行だけになる。**
///
/// ## 鍵は呼ぶ側が enum で決める
///
/// 綴りと網羅性をコンパイラに見せるためである。文字列を鍵にすると、離れた 2 か所で
/// 同じ綴りを書いた時点で**片方が永久に黙る**うえ、黙ったことは絵にもログにも出ない。
/// enum なら、鍵を共有していることは定義を見れば分かる。
///
/// [#734]: https://github.com/mokume-metal/mokume/issues/734
///
/// **隔離を持たない。** 持っているのは自分の控えだけで、``Diagnostics`` と同じく
/// 共有する状態が無いため、置かれた側の隔離に合わせる理由が無い。
nonisolated struct WarningLog<Key: Hashable> {
    /// 言った注意と、そのとき出した文面。
    ///
    /// 集合ではなく対応表で持つ。**出した文面をそのまま控える**ためで、こうすると
    /// 「1 度しか言わない」も「何と言ったか」も、標準エラーを覗かずに確かめられる。
    /// 控えるのは高々鍵の種類の数で、フレームでは増えない (鍵が値を持つ注意は、呼ぶ側が
    /// 言う数に上限を置く — ``count(where:)``)。
    private var said: [Key: String] = [:]

    /// まだ言っていなければ、その注意を 1 度だけ言う。2 度目からは何もしない。
    ///
    /// 文面は `@autoclosure` で受ける。**言わない回は組み立てない** — 呼ばれる場所は
    /// 頂点 1 つごとの経路まで含むので、黙る回に文字列を確保すると、畳んだぶんだけ
    /// 遅くなる。旗で守っていたときと同じく、確保が起きるのは最初の 1 回だけである。
    mutating func warnOnce(_ key: Key, _ message: @autoclosure () -> String) {
        guard said[key] == nil else { return }
        let text = message()
        said[key] = text
        Diagnostics.warn(text)
    }

    /// その注意を既に言ったか。**検査が読む。**
    func hasWarned(_ key: Key) -> Bool { said[key] != nil }

    /// その注意で出した文面。まだ言っていなければ `nil`。**検査が文言を読む。**
    func message(for key: Key) -> String? { said[key] }

    /// 言った注意のうち、条件に合う鍵の数。
    ///
    /// 鍵が値を持つ注意 (行き先ごとに 1 度言う書き損じ・``FrameRecorder``) の、言った数に
    /// 上限を置くためにある。数を別に持つと、控えと数の 2 つを揃えて空に戻す必要が出る。
    func count(where isIncluded: (Key) -> Bool) -> Int { said.keys.count(where: isIncluded) }
}

nonisolated extension WarningLog: Sendable where Key: Sendable {}

/// 複数のスレッドから言える「初回だけ知らせる」控え ([#2389])。
///
/// 値だけを扱う数と色の関数 (``map(_:_:_:_:_:)`` や ``color(_:_:_:_:)``) は、持ち主の面が無いので
/// 控えをプロセスで 1 つ持つ。これらを `nonisolated` にして、`concurrentPerform` や TaskGroup から
/// 並べて呼べるようにすると、**同じ注意を同時に言いうる**。控えの確かめと書き込みを `Mutex` の
/// 1 つの区間に入れて、どのスレッドから何本呼んでも、注意は 1 度だけ出る。
///
/// 面が持つ控え (``Canvas/warnings`` など) は main actor の中だけで触るので、``WarningLog`` のまま
/// 持つ。ここへ寄せるのは、持ち主が無く、隔離の外から呼ばれうる口だけである。
///
/// **文面の組み立てと標準エラーへの 1 行は、区間の中で行う。** 言う回は最初の 1 回だけで、
/// 黙る回は鍵を見るだけで抜ける (区間は短い)。
///
/// [#2389]: https://github.com/mokume-metal/mokume/issues/2389
nonisolated final class SharedWarningLog<Key: Hashable & Sendable>: Sendable {
    private let log = Mutex(WarningLog<Key>())

    /// まだ言っていなければ、その注意を 1 度だけ言う。
    func warnOnce(_ key: Key, _ message: @autoclosure () -> String) {
        log.withLock { $0.warnOnce(key, message()) }
    }

    /// いま言ってある注意の写し。**検査が読む。**
    var snapshot: WarningLog<Key> { log.withLock { $0 } }
}
