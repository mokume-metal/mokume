// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Testing

@testable import MokumeAudio
import MokumeCore

/// マイクの状態の移り変わり (ADR-0028 決定 3・4)。機材も OS も要らない。
///
/// 許可は 1 度答えると戻せず、抜き差しは手で行うので、実機では組み合わせを回せない。
/// 判断を ``MicrophoneLifecycle`` に閉じてあるので、ここで全部の道を通す。
@Suite("マイクの状態の移り変わり")
struct MicrophoneLifecycleTests {
    @Test("許可が未決定なら、許可を求めて待つ")
    func undecidedAsksAndWaits() {
        var lifecycle = MicrophoneLifecycle()
        #expect(lifecycle.open(authorization: .notDetermined, deviceAvailable: true) == .requestAccess)
        #expect(lifecycle.state == .waitingForPermission)
    }

    @Test("許されたら始め、拒まれたら拒まれたまま")
    func answerDecides() {
        var granted = MicrophoneLifecycle()
        _ = granted.open(authorization: .notDetermined, deviceAvailable: true)
        #expect(granted.accessAnswered(granted: true, deviceAvailable: true) == .startEngine)
        #expect(granted.state == .running)

        var refused = MicrophoneLifecycle()
        _ = refused.open(authorization: .notDetermined, deviceAvailable: true)
        #expect(refused.accessAnswered(granted: false, deviceAvailable: true) == .none)
        #expect(refused.state == .denied)
    }

    @Test("既に拒まれていれば、求めずに拒まれたまま")
    func alreadyDenied() {
        var lifecycle = MicrophoneLifecycle()
        #expect(lifecycle.open(authorization: .denied, deviceAvailable: true) == .none)
        #expect(lifecycle.state == .denied)
    }

    @Test("マイクが無ければ機材なしになり、挿されたら始まる")
    func noDeviceThenPluggedIn() {
        var lifecycle = MicrophoneLifecycle()
        #expect(lifecycle.open(authorization: .authorized, deviceAvailable: false) == .none)
        #expect(lifecycle.state == .unavailable)
        // 別の機材が挿されたが、使える 1 台はまだ無い
        #expect(lifecycle.deviceConnected(deviceAvailable: false) == .none)
        #expect(lifecycle.state == .unavailable)
        #expect(lifecycle.deviceConnected(deviceAvailable: true) == .startEngine)
        #expect(lifecycle.state == .running)
    }

    @Test("抜かれたら止めて切断になり、挿し直せば戻る")
    func unpluggedThenBack() {
        var lifecycle = MicrophoneLifecycle()
        _ = lifecycle.open(authorization: .authorized, deviceAvailable: true)
        #expect(lifecycle.deviceDisconnected() == .stopEngine)
        #expect(lifecycle.state == .disconnected)
        // 2 度目の知らせでは止め直さない
        #expect(lifecycle.deviceDisconnected() == .none)
        #expect(lifecycle.deviceConnected(deviceAvailable: true) == .startEngine)
        #expect(lifecycle.state == .running)
    }

    @Test("許可を待っている間や拒まれている間に挿しても、許可の答えは変わらない")
    func pluggingDoesNotAnswerPermission() {
        var waiting = MicrophoneLifecycle()
        _ = waiting.open(authorization: .notDetermined, deviceAvailable: false)
        #expect(waiting.deviceConnected(deviceAvailable: true) == .none)
        #expect(waiting.state == .waitingForPermission)

        var denied = MicrophoneLifecycle()
        _ = denied.open(authorization: .denied, deviceAvailable: true)
        #expect(denied.deviceConnected(deviceAvailable: true) == .none)
        #expect(denied.state == .denied)
    }

    @Test("止めると、動いていたときだけ止める手を返す")
    func stopping() {
        var running = MicrophoneLifecycle()
        _ = running.open(authorization: .authorized, deviceAvailable: true)
        #expect(running.stop() == .stopEngine)
        #expect(running.state == .stopped)
        // 止めた後に答えが来ても始めない
        #expect(running.accessAnswered(granted: true, deviceAvailable: true) == .none)
        #expect(running.deviceConnected(deviceAvailable: true) == .none)

        var unavailable = MicrophoneLifecycle()
        _ = unavailable.open(authorization: .authorized, deviceAvailable: false)
        #expect(unavailable.stop() == .none)
        #expect(unavailable.state == .stopped)
    }
}
