// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization

/// 絵をファイルにする係。**符号化と書き込みをフレームの外で行う。**
///
/// フレームの中で払うのは読み戻しだけである。符号化と書き込みまでフレームに載せると、
/// **ディスクの速さがフレームレートを縛る** — 撮っている間だけ絵が遅くなり、撮り終えると
/// 直る、という切り分けの難しい症状になる。
///
/// ## 抱える枚数に上限がある
///
/// 書き込みが追いつかないとき、待つのは**頼む側**である ([ADR-0023] 決定 5 と同じ姿勢 —
/// 長く回したときにだけ重くなる形を作らない)。上限に達すると ``write(_:to:)`` が返らなく
/// なるので、遅いディスクではフレームが遅くなる。**代わりにメモリは伸びない。**
///
/// ## 待ち方
///
/// 走らせる側は `Task.detached` で main actor の外へ出す ([ADR-0010] 決定 4)。
/// **待つ側は semaphore である** — 完了を待つのは main actor の上なので `await` が
/// 使えない。`DispatchQueue` は足さない (同 決定 4)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
final class FrameWriter {
    /// 同時に抱える枚数の既定の上限。
    ///
    /// 960x540 なら 1 枚あたり約 2 MB なので、既定では 8 MB を上限に抱える。
    static let defaultLimit = 4

    /// 空いている枠。**取れなければ待つ** — これが背圧そのものである。
    private let slots: DispatchSemaphore
    /// 書き終わった枚数。``drain()`` はこれを投げた本数ぶん受け取る。
    private let finished = DispatchSemaphore(value: 0)
    /// 直近の書き損じ。**隔離の外から書かれる**ので錠で守る。
    private let lastFailure = FailureSlot()

    /// 抱えている枚数の上限。
    let limit: Int
    /// いま抱えている枚数 (取り込み済みの完了を差し引いたもの)。
    private(set) var outstanding = 0
    /// 抱えた枚数の最大。**背圧が効いたことを検査から見るための目印。**
    private(set) var peakOutstanding = 0
    /// 頼まれた総数。
    private(set) var requested = 0

    init(limit: Int = FrameWriter.defaultLimit) {
        self.limit = max(1, limit)
        slots = DispatchSemaphore(value: self.limit)
    }

    /// 1 枚を書くよう頼む。**上限に達していたら、空くまで返らない。**
    ///
    /// 途中のディレクトリはここで作る — 撮る先を先に用意させると、名前を組み立てた
    /// 側と作る側が二重になる。
    func write(_ image: DisplayImage, to path: String) {
        harvest()
        // 背圧。ここで待つのは main actor なので、フレームが遅くなる代わりに
        // 抱える枚数は上限を超えない
        slots.wait()
        // 枠が空いたということは、書き終わったものが 1 枚以上ある。取り込んでおかないと
        // 抱えている枚数が実態より多いままになる
        harvest()

        outstanding += 1
        peakOutstanding = max(peakOutstanding, outstanding)
        requested += 1

        let url = URL(fileURLWithPath: path)
        let slots = slots
        let finished = finished
        let lastFailure = lastFailure
        let path = path
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PNGFile.write(image, to: url)
            } catch {
                lastFailure.set("\(path) を書けませんでした: \(error)")
            }
            // **終わりの合図を先に出す。** 枠を先に返すと、待っていた側が起きた時点で
            // まだ終わりの合図が出ておらず、抱えている枚数を数え損なう
            finished.signal()
            slots.signal()
        }
    }

    /// 頼んだ全部が**ファイルになるまで**待つ。
    ///
    /// 「呼んだら書かれる」ように見える面が「あとで書かれる」実装だと、止めるときに
    /// 壊れる。**始まりだけでなく終わりも面の一部**なので、待てる形をここに置く。
    ///
    /// 2 度呼んでも安全 (抱えている枚数が 0 なら何もしない)。
    func drain() {
        while outstanding > 0 {
            finished.wait()
            outstanding -= 1
        }
    }

    /// 直近の書き損じを取り出す。**取り出したら消える。**
    ///
    /// 書き込みは隔離の外で走るので、失敗が分かるのは頼んだフレームより後になる。
    /// 呼んだ側 (``FrameRecorder``) はこれを差込口の ``Outlet/failure`` へ載せ、
    /// 続けて転んだら外れる形へつなぐ ([ADR-0024] 決定 7)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    func takeFailure() -> String? { lastFailure.take() }

    /// 終わっているものを取り込む。**待たない。**
    private func harvest() {
        while outstanding > 0, finished.wait(timeout: .now()) == .success {
            outstanding -= 1
        }
    }
}

/// 隔離の外から書かれ、main actor から読まれる 1 つの値。
///
/// 錠そのもの (`Mutex`) は複製できないので、閉じた先の仕事へ渡すには参照になる器が要る。
/// **escape hatch は使わない** ([ADR-0010] 決定 3) — 中身が錠で守られていることを
/// 型として示す。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
nonisolated final class FailureSlot: Sendable {
    private let value = Mutex<String?>(nil)

    /// 書き損じを置く。**後から来たものが前を上書きする** — 続けて転んでいることは
    /// 差込口の健康状態が数えるので、ここに溜める理由が無い。
    func set(_ message: String) { value.withLock { $0 = message } }

    /// 置かれているものを取り出す。**取り出したら消える。**
    func take() -> String? {
        value.withLock { stored in
            defer { stored = nil }
            return stored
        }
    }
}
