// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import Synchronization
import mokume

/// `run` と `watch` が受ける `--record <path>` ([#3570])。
///
/// ## なぜ値を必須にするのか
///
/// 「値を省略できる旗」は `Arguments` に無く、あっても位置引数 `[<directory>]` と紛れる
/// (2026-10-31 の決定)。そこで**行き先は旗が必ず指し、既定の行き先は持たない** — `render --out <path>` と
/// 同じ形である。`.mokume/` の下へ勝手に置かないので、回帰に使う記録はそのまま残る場所にある。
///
/// ## 渡し方
///
/// 道具が走らせた場所から絶対パスに解き、子へ環境変数で渡す (``StartupReads/record``・`MOKUME_RENDER` と
/// 同じ形)。`watch` は作り直すたびに新しい世代の行き先を渡す (``ReplayRequest/generation(of:number:)``)。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
enum RecordOption {
    static let flags = ["--record"]

    /// 選択肢の宣言。``Command/valueOptions`` が `doctor` に同じ宣言を渡す。
    @MainActor static var options: [Arguments.Option] {
        [
            Arguments.Option(flags, takesPlace: true) {
                "\($0) needs somewhere to write the record after it (a file, such as take.json)"
            }
        ]
    }

    /// 解いた値から、記録の行き先 (絶対パス) を取り出す。**旗が無ければ `nil`。**
    ///
    /// 行き先がフォルダなら、ビルドの前に断る。
    static func destination(
        in values: [String: String], from currentDirectory: URL? = GivenPath.currentDirectory
    ) throws(CommandFailure) -> String? {
        guard let given = values[flags[0]] else { return nil }
        // 末尾の `/` はフォルダの綴りで、ファイルの行き先ではない
        guard !given.hasSuffix("/") else {
            throw .usage("\(flags[0]) takes a file to write, not a directory: \(given)")
        }
        let path = try GivenPath.resolve(given, from: currentDirectory, isDirectory: false).path
        var isDirectory: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue {
            throw .usage("\(flags[0]) takes a file to write, but this is a directory: \(given)")
        }
        return path
    }
}

/// `watch --record` が起こした子の数を数え、**世代ごとに別の行き先**を渡す ([#3570])。
///
/// 作り直しは記録の切れ目で、新しい世代の記録が 1 本始まる。番号は子を起こすたびに 1 から進み、
/// 作り直しに失敗して子を起こさなかった回は進まない。起こす口は作り直しの糸から呼ばれるので、数えるのは錠で守る。
///
/// [#3570]: https://github.com/mokume-metal/mokume/issues/3570
nonisolated final class RecordGenerations: Sendable {
    private let destination: String
    private let started = Mutex(0)

    init(destination: String) {
        self.destination = destination
    }

    /// 次の子の行き先。
    func next() -> String {
        let number = started.withLock { count -> Int in
            count += 1
            return count
        }
        return ReplayRequest.generation(of: destination, number: number)
    }
}
