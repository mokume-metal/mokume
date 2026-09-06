// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

// **行ごとに吐き出す。** 既定では、出力先が端末でないときにまとめて溜められるので、
// 見張っている最中の記録をファイルへ落とすと何も見えない (走り終えるまで出ない)。
// 見張る道具は動いている間ずっと読まれるものなので、ここを既定に任せない
setvbuf(stdout, nil, _IOLBF, 0)

do {
    try Command.dispatch(Array(CommandLine.arguments.dropFirst()))
} catch {
    // **終わる場所はここ 1 つ。** 途中で exit を呼ぶと、名乗りも後始末もこの
    // catch を素通りする — 素通りしたことは出力からは読めない (#994 の 9)
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(error.exitCode)
}
