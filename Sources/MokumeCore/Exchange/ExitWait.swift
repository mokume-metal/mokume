// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 子の終わりを、呼んだ糸の実行ループを回さずに待つ ([#1937])。
///
/// **`Process.waitUntilExit()` は、待つ間に呼んだ糸の実行ループを回す。** main で呼ぶと、そこに
/// 載った仕事 (タイマー・画面の駆動源) が待ちの中で走る。合図の受け口と宛先を持ったまま待つ口
/// (道具の `RunCommand.launch`) では、その前提が待ちの最中に書き換わる。道具は待つ間に実行
/// ループを要さない (`run` / `render` / `bundle` は窓も main の仕事も持たず、見張りは作り直しを
/// main の外で待つ) ので、回さずに塞ぐ。**子の終わりを待つ口は、道具も検査もこれ 1 つに寄せる。**
///
/// **子を起こす前に作る。** 知らせ (`terminationHandler`) は起こす前に置く。起こした後に置くと、
/// すぐ終わった子の知らせを取り逃しうる。
///
/// **呼び手が置いた知らせは消さない。** 既に `terminationHandler` があれば、それを先に呼んでから
/// 待ちを解く。上書きすると、呼び手の知らせが黙って来なくなる。
///
/// 道具 (`MokumeCLI`) と 2 つの検査ターゲットが分け持つので、置き場はパッケージの中で共通の
/// ここにする。
///
/// [#1937]: https://github.com/mokume-metal/mokume/issues/1937
package nonisolated struct ExitWait: Sendable {
    private let exited = DispatchSemaphore(value: 0)

    package init(for process: Process) {
        let exited = exited
        let earlier = process.terminationHandler
        process.terminationHandler = { process in
            earlier?(process)
            exited.signal()
        }
    }

    /// 子が終わるまで塞ぐ。戻った後は `terminationStatus` が読める。
    package func wait() {
        exited.wait()
    }
}
