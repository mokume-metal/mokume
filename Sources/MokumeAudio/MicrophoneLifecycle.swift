// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore

/// マイクの状態の移り変わり。**機材にも OS にも触れない**純粋な型で、検査が直に回す。
///
/// 許可を待つ・拒まれる・機材が無い・抜かれた・挿し直された、の組み合わせは実機では
/// 再現しにくい (許可は 1 度答えると戻せず、抜き差しは手で行う)。移り変わりの判断を
/// ここに閉じ、実機に触れる ``MicrophoneSource`` は返された手を打つだけにする。
///
/// カメラの `CameraLifecycle` と同じ形をしている。**写しを 1 つに畳むのは、畳まないことの
/// 実害が出てから**にする (畳むことも仕組みを足すことに数える — AGENTS.md)。ターゲットを
/// またいで共有するには MokumeCore の公開面に出す必要があり、使う 2 つの他に読み手がいない。
nonisolated struct MicrophoneLifecycle: Equatable {
    /// OS の許可の答え。
    enum Authorization: Equatable {
        case notDetermined
        case authorized
        case denied
    }

    /// 呼んだ側が打つ手。
    enum Action: Equatable {
        case none
        case requestAccess
        case startEngine
        case stopEngine
    }

    private(set) var state: SourceState = .waitingForPermission

    /// 開いたとき。
    mutating func open(authorization: Authorization, deviceAvailable: Bool) -> Action {
        switch authorization {
        case .notDetermined:
            state = .waitingForPermission
            return .requestAccess
        case .denied:
            state = .denied
            return .none
        case .authorized:
            return startIfPossible(deviceAvailable)
        }
    }

    /// 許可のダイアログに答えが出たとき。待っていなければ何もしない。
    mutating func accessAnswered(granted: Bool, deviceAvailable: Bool) -> Action {
        guard state == .waitingForPermission else { return .none }
        guard granted else {
            state = .denied
            return .none
        }
        return startIfPossible(deviceAvailable)
    }

    /// 使っている機材が抜かれたとき。
    mutating func deviceDisconnected() -> Action {
        guard state == .running else { return .none }
        state = .disconnected
        return .stopEngine
    }

    /// 機材が挿されたとき。**機材が無い・抜かれた状態からだけ戻る** — 許可を待っている間や
    /// 拒まれている間に挿しても、許可の答えは変わらない。
    mutating func deviceConnected(deviceAvailable: Bool) -> Action {
        guard state == .unavailable || state == .disconnected else { return .none }
        return startIfPossible(deviceAvailable)
    }

    /// 止めるとき。
    mutating func stop() -> Action {
        let wasRunning = state == .running
        state = .stopped
        return wasRunning ? .stopEngine : .none
    }

    private mutating func startIfPossible(_ deviceAvailable: Bool) -> Action {
        guard deviceAvailable else {
            state = .unavailable
            return .none
        }
        state = .running
        return .startEngine
    }
}
