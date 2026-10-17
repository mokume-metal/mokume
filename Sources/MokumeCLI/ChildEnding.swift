// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// 終わった子 (`Process`) の終わり方。**自分で終わったか、合図で落ちたか。**
///
/// ## なぜ 1 か所にするのか
///
/// `Process.terminationStatus` は、自分で終わった子には終了コードを返し、**合図で落ちた子には
/// 合図の番号を返す** (Foundation の仕様)。`terminationReason` を見ずに読むと、`fatalError` の
/// SIGTRAP (5) が「exited with code 5」になり、`exit(5)` で自分から終わった子と見分けが
/// つかない ([#2315](https://github.com/mokume-metal/mokume/issues/2315))。読み手が
/// 口ごとに散っていた — スケッチ (`run`・`render`)・道具立て (`swift`・`codesign`)・止めた
/// 作り直しの記録 — ので、読むのはここだけにする。
///
/// **合図で終わった子の終了コードは、シェルの慣例どおり `128 + 番号`** (``shellStatus``)。
/// 道具自身が合図で止めた回 (``CommandFailure/stopped(signal:)``・#1193) がすでに採っている値で、
/// シェルで子を直に走らせたときの `$?` と同じである。
nonisolated enum ChildEnding: Equatable {
    /// 自分で終わった。値は終了コード。
    case exited(Int32)
    /// 合図で落ちた。値は合図の番号。
    case signalled(Int32)

    /// 終わった子の終わり方。**走っている子へ呼ばない** (`terminationStatus` が例外で落ちる)。
    init(of process: Process) {
        let status = process.terminationStatus
        self = process.terminationReason == .uncaughtSignal ? .signalled(status) : .exited(status)
    }

    /// シェルの `$?` と同じ形の数。合図なら `128 + 番号`。**記録に載せる数はこれにする。**
    var shellStatus: Int32 {
        switch self {
        case .exited(let status): status
        case .signalled(let signal): 128 + signal
        }
    }

    /// 人へ見せる 1 句 (`exited with code 3` / `ended by signal 5 (SIGTRAP)`)。
    var phrase: String {
        switch self {
        case .exited(let status): "exited with code \(status)"
        case .signalled(let signal): "ended by signal \(Self.describe(signal: signal))"
        }
    }

    /// 合図を `5 (SIGTRAP)` の形にする。**名前を持つのはスケッチが落ちうる合図だけ** — 知らない
    /// 合図は番号だけを言う。名前は C の文面 (`strsignal`) を引かず、ここに書く: 言語の設定に
    /// 左右されず、番号を含めて返す版 (Darwin) と含めない版の差も出ない (ADR-0038 決定 1・2)。
    static func describe(signal: Int32) -> String {
        guard let name = signalNames[signal] else { return "\(signal)" }
        return "\(signal) (\(name))"
    }

    private static let signalNames: [Int32: String] = [
        SIGHUP: "SIGHUP", SIGINT: "SIGINT", SIGQUIT: "SIGQUIT", SIGILL: "SIGILL",
        SIGTRAP: "SIGTRAP", SIGABRT: "SIGABRT", SIGFPE: "SIGFPE", SIGKILL: "SIGKILL",
        SIGBUS: "SIGBUS", SIGSEGV: "SIGSEGV", SIGSYS: "SIGSYS", SIGPIPE: "SIGPIPE",
        SIGALRM: "SIGALRM", SIGTERM: "SIGTERM",
    ]
}
