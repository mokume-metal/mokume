// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// 差込口 1 つが動いているか。
///
/// [ADR-0024] 決定 7 の「フレームごとに呼ばれるものは投げない。続けて失敗したら
/// その差込口を外し、外したことを診断に出す」を数える側。
///
/// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
struct SeamHealth {
    /// 何回**続けて**転んだら外すか。
    ///
    /// **1 回では外さない。** 資源の取り合いのような一時的な失敗で機能が消えると、
    /// 状況が直っても戻らない。逆に何度でも許すと、転び続ける差込口が毎フレーム
    /// 費用を払い続ける。
    static let limit = 3

    /// 続けて転んだ回数。順調に終わるたびに 0 へ戻る。
    private(set) var failures = 0
    /// まだ呼ばれるか。
    private(set) var isAttached = true

    /// 直近の呼び出しの結果を取り込む。
    ///
    /// - Parameter failure: 転んだ理由。順調なら `nil`。
    /// - Returns: **この呼び出しで外れたとき**だけ `true` (診断は 1 度だけ出す)。
    mutating func note(_ failure: String?) -> Bool {
        guard isAttached else { return false }
        guard failure != nil else {
            failures = 0
            return false
        }
        failures += 1
        guard failures >= Self.limit else { return false }
        isAttached = false
        return true
    }
}
