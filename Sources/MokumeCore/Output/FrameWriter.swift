// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import MokumeDiagnostics
import Synchronization

/// 絵をファイルにする係。**符号化と書き込みをフレームの外で行う。**
///
/// フレームの中で払うのは読み戻しだけである。符号化と書き込みまでフレームに載せると、
/// **ディスクの速さがフレームレートを縛る** — 撮っている間だけ絵が遅くなり、撮り終えると
/// 直る、という切り分けの難しい症状になる。
///
/// ## 抱える枚数に上限がある
///
/// 上限と待ち方は ``Backpressure`` が持つ。上限に達すると ``write(_:to:)`` が返らなく
/// なるので、遅いディスクではフレームが遅くなる。**代わりにメモリは伸びない。**
///
/// ## 待ち方
///
/// 走らせる側は `Task.detached` で main actor の外へ出す ([ADR-0010] 決定 4)。
/// **待つ側は semaphore である** — 完了を待つのは main actor の上なので `await` が
/// 使えない (`endRecord()` が同期の `draw()` から呼ばれる public API なので、`await` は
/// 利用者のスケッチに現れてしまう。同 決定 1)。`DispatchQueue` は足さない (同 決定 4)。
///
/// [ADR-0010]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0010-concurrency-model.md
/// [ADR-0023]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0023-frame-stages-and-outputs.md
final class FrameWriter {
    /// 同時に抱える枚数の既定の上限。
    static let defaultLimit = Backpressure.defaultLimit

    /// 抱える枚数の上限と、終わったものの数え方。
    private let pressure: Backpressure
    /// 直近の書き損じ。**隔離の外から書かれる**ので錠で守る。
    private let lastFailure = FailureSlot()

    /// 抱えている枚数の上限。
    var limit: Int { pressure.limit }
    /// いま抱えている枚数 (取り込み済みの完了を差し引いたもの)。
    var outstanding: Int { pressure.outstanding }
    /// 抱えた枚数の最大。**背圧が効いたことを検査から見るための目印。**
    var peakOutstanding: Int { pressure.peak }
    /// 頼まれた総数。
    private(set) var requested = 0

    init(limit: Int = FrameWriter.defaultLimit) {
        pressure = Backpressure(limit: limit)
    }

    /// 1 枚を書くよう頼む。**上限に達していたら、空くまで返らない。**
    ///
    /// 途中のディレクトリはここで作る — 撮る先を先に用意させると、名前を組み立てた
    /// 側と作る側が二重になる。
    func write(_ image: DisplayImage, to path: String) {
        // 背圧。ここで待つのは main actor なので、フレームが遅くなる代わりに
        // 抱える枚数は上限を超えない
        pressure.take()
        requested += 1

        let url = URL(fileURLWithPath: path)
        let release = pressure.release
        let lastFailure = lastFailure
        let path = path
        Task.detached(priority: .utility) {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try PNGFile.write(image, to: url)
            } catch {
                lastFailure.set("Could not write \(path): \(error)")
            }
            release()
        }
    }

    /// 頼んだ全部が**ファイルになるまで**待つ。
    ///
    /// 「呼んだら書かれる」ように見える面が「あとで書かれる」実装だと、止めるときに
    /// 壊れる。**始まりだけでなく終わりも面の一部**なので、待てる形をここに置く。
    ///
    /// 2 度呼んでも安全 (抱えている枚数が 0 なら何もしない)。
    ///
    /// **1 枚も進まなくなったら諦める** (``Backpressure/drain()``)。返らないディスクを
    /// 相手に永久に待つと、main actor が固まって絵も観測も入力も一緒に黙る。諦めても
    /// 書き込みは走り続けるので、失うのは「返ってきた時点で書けている」という保証だけ。
    func drain() {
        guard let stranded = pressure.drain() else { return }
        Diagnostics.warn(
            "Writing images has not moved for \(Int(pressure.stallLimitSeconds)) seconds "
                + "(\(stranded) are still waiting) — no longer waiting for it. Writing is still going")
    }

    /// 直近の書き損じを取り出す。**取り出したら消える。**
    ///
    /// 書き込みは隔離の外で走るので、失敗が分かるのは頼んだフレームより後になる。
    /// 呼んだ側 (``FrameRecorder``) はこれを差込口の ``Outlet/failure`` へ載せ、
    /// 続けて転んだら外れる形へつなぐ ([ADR-0024] 決定 7)。
    ///
    /// [ADR-0024]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0024-extension-seams.md
    func takeFailure() -> String? { lastFailure.take() }
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
