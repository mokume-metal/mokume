// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin

/// bootstrap の名前空間で名前を登録し、引く ([ADR-0049] 決定 3)。
///
/// **`bootstrap_check_in` と `bootstrap_look_up` は `dlsym` で引く。** Swift の `Darwin` モジュールは
/// `servers/bootstrap.h` を含まないので、そのままでは呼べない。C のターゲットを 1 つ足して包めば型を
/// コンパイラが確かめるが、本体で初めての C のターゲットになる (ADR-0049 決定 3 が退けた案)。代償として
/// 関数の型は誰も確かめないので、型の誤りは検査 (`FrameListingTests` の登録と引きの往復) が捕まえる。
///
/// 型は `kern_return_t f(mach_port_t bp, const char *name, mach_port_t *sp)` で、2 つとも同じ形である
/// (#3917 の実測で、hosted の runner と専用機の両方で通った)。
///
/// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md
package nonisolated enum Bootstrap {
    private typealias Call = @convention(c) (
        mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>
    ) -> kern_return_t

    /// 引いた関数。**引けなければ `nil`** で、名乗れない環境として扱う (投げない)。
    private static let calls: (checkIn: Call, lookUp: Call)? = {
        guard let handle = dlopen(nil, RTLD_NOW),
            let checkIn = dlsym(handle, "bootstrap_check_in"),
            let lookUp = dlsym(handle, "bootstrap_look_up")
        else { return nil }
        return (unsafeBitCast(checkIn, to: Call.self), unsafeBitCast(lookUp, to: Call.self))
    }()

    /// 登録に失敗した理由。
    package enum Failure: Error, Equatable, CustomStringConvertible {
        /// 関数を引けなかった。
        case unavailable
        /// 名前空間が断った (App Sandbox の中など)。値は戻り値。
        case refused(kern_return_t)

        package var description: String {
            switch self {
            case .unavailable: "bootstrap_check_in is not available"
            case .refused(let code): String(cString: mach_error_string(code))
            }
        }
    }

    /// このプロセスの bootstrap の port。
    private static var port: mach_port_t {
        var port: mach_port_t = 0
        task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &port)
        return port
    }

    /// 名前を登録して、受信の権利を得る。
    static func checkIn(_ name: String) -> Result<mach_port_t, Failure> {
        guard let calls else { return .failure(.unavailable) }
        var receive: mach_port_t = 0
        let code = name.withCString { calls.checkIn(port, $0, &receive) }
        guard code == KERN_SUCCESS else { return .failure(.refused(code)) }
        return .success(receive)
    }

    /// 名前を引いて、送信の権利を得る。**引けなければ `nil`** (登録されていない・別の名前空間)。
    ///
    /// 得た送信の権利は、呼んだ側が ``releaseSend(_:)`` で手放す。
    static func lookUp(_ name: String) -> mach_port_t? {
        guard let calls else { return nil }
        var send: mach_port_t = 0
        let code = name.withCString { calls.lookUp(port, $0, &send) }
        guard code == KERN_SUCCESS, send != 0 else { return nil }
        return send
    }

    /// 受信の権利を手放す。**名前は名前空間から消える** (受信の権利が死ぬと、launchd が名前を外す)。
    static func releaseReceive(_ port: mach_port_t) {
        mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
    }

    /// 送信の権利を手放す。
    static func releaseSend(_ port: mach_port_t) {
        mach_port_deallocate(mach_task_self_, port)
    }
}
