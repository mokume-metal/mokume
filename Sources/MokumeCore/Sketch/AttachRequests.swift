// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 走っている実行へ入り口を足すことの頼みの窓口 (``SketchPart/requestSound(_:)`` など)。
///
/// 待つ読み込みの口は `Task` の続きで返る。そこでは ``runningSketch`` が外れているので、走っている実行へ
/// 足す口 (``SketchPart/attached(_:calledAs:making:)``) はそのままでは断る。**足すのは実行の側で、
/// 窓口はそれを頼んで待たせるだけ**にする — ``LaunchingSketch`` が持ち越すのはこの窓口で、実行ではない。
/// 描く口を `Task` から効かせると描く順が `Task` に番が回る時機で決まってしまうので
/// ([ADR-0010]・``LaunchingSketch``)、足す番も `Task` には渡さない。
///
/// 流れは ``SelectionBroker`` と同じ形である。頼みを控えて待たせ、**実行がフレームの頭で当てて**
/// (``serve(_:)``)、足し終えたところで待ちを終える。待つ側が戻るのは当てた後なので、返った入り口は
/// 足されている。実行の後片付けでは、残りの頼みを足せなかったとして終える (``end()``)。終わった実行の
/// `Task` は残りうるが、当てる者がもう居ないので、待たせると返らない。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
@MainActor
final class AttachRequests {
    private var waiting: [(inlet: any Inlet, continuation: CheckedContinuation<Bool, Never>)] = []
    /// 実行が終わったか (``end()``)。終わった後の頼みは待たずに断る。
    private(set) var isEnded = false

    /// 当てられるのを待っている頼みがあるか。
    var hasWaiting: Bool { !waiting.isEmpty }

    /// 足すことを頼んで、実行が当てるまで待つ。
    ///
    /// - Returns: 実行へ渡せたか。`false` は、実行が終わっていて当てる者が居ないとき (終わった後の頼み・
    ///   待っている最中に終わったとき)。`true` のとき、足した結果の良し悪しは入り口の `state` が言う。
    func request(_ inlet: any Inlet) async -> Bool {
        guard !isEnded else { return false }
        return await withCheckedContinuation { continuation in
            waiting.append((inlet, continuation))
        }
    }

    /// 控えた頼みを頼まれた順に当て、待ちを終える。**フレームの頭で、実行が呼ぶ。**
    ///
    /// - Parameter join: 入り口を足す。実行の足す口を渡す。
    func serve(_ join: (any Inlet) -> Void) {
        guard !waiting.isEmpty else { return }
        // 当てている最中に新しく頼まれた分は、次のフレームの頭へ回す
        let batch = waiting
        waiting = []
        for entry in batch {
            join(entry.inlet)
            entry.continuation.resume(returning: true)
        }
    }

    /// 実行が終わった。**残りの頼みを足せなかったとして終え、これからの頼みは待たせない。**
    func end() {
        isEnded = true
        let batch = waiting
        waiting = []
        for entry in batch { entry.continuation.resume(returning: false) }
    }
}
