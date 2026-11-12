// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 本体の中の最小の受け手 ([ADR-0049] 決定 7・#3922)。走っているスケッチの名前を引いて繋ぎ、届いた出来事を 1 行 1 JSON で
// 標準出力に出す。`FrameLinkContractTests` が子として起こし、別のプロセスとの往復を確かめる。product には含めない。
//
// 手順の正本は `Schemas/frame-link.md`。外のアプリが書く受け手と同じことだけをする (送り手の内部には触れない)。
//
//   frame-receiver --service <名前> --width <幅> --height <高さ> [--surfaces 3] [--name <名乗り>]
//                  [--exit-after <枚数>] [--timeout <秒>]
//   frame-receiver --listing <目録の 1 件のファイル> [--width <幅> --height <高さ>] [...]
//
// `--listing` は目録の 1 件から名前と大きさを読む (#3949)。大きさの無い旧い送り手の項目なら `--width`・`--height` を使い、
// それも無ければ `sizeUnknown` を言って終わる。`surfaceSize` (4) で断られたら目録を読み直し、大きさが変わっていれば
// その大きさの面で繋ぎ直す。`--service` の形は、目録の大きさを読まない従来の受け手として振る舞う。
//
// 答え (`accepted`・`refused`) は待ち行列が満杯なら落ちる (#3968)。繋ぐ前に自分の待ち行列を読み切り、答えを
// `--answer-timeout` 秒 (既定 1) 待つ。届かなければ、番号を知っていれば `disconnect` してから、知らなければ受信の port を
// 作り直してから繋ぎ直す (続けて 3 回で諦める)。答えを待つ間の frame は数えない。答えを落とす状況は検査用の
// `--clog-attempt <n>` (n 回目の connect の前に自分の待ち行列を詰め、標準入力の `resume` まで読まない) で作る。
// 大きさで断られたとき (#3949) は答えが届いているので、こちらではなく目録の読み直しに進む。
//
// 標準入力が `resume` 以外の 1 行を届けるか閉じると終わる (検査が、受け手の側から切る形を作れるように)。
//
// [ADR-0049]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0049-share-frames-to-other-processes.md

import Darwin
import Foundation
import IOSurface
import MokumeCore

func say(_ object: [String: Any]) {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
    FileHandle.standardOutput.write(data + Data("\n".utf8))
}

func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), index + 1 < arguments.count else { return nil }
    return arguments[index + 1]
}

/// 目録の 1 件を読む。読むのは名前と大きさだけで、他の欄 (知らない欄も) は読み飛ばす。読めなければ `nil`。
func readListing(at path: String) -> (service: String, width: Int?, height: Int?)? {
    guard let data = FileManager.default.contents(atPath: path),
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
        object["schemaVersion"] as? Int == 1, let service = object["serviceName"] as? String
    else { return nil }
    // 幅と高さは揃っていて 1 以上のときだけ使う (片方だけなら無いのと同じ)
    guard let width = object["width"] as? Int, let height = object["height"] as? Int, width > 0, height > 0 else {
        return (service, nil, nil)
    }
    return (service, width, height)
}

let listingPath = argument("--listing")
var service = argument("--service")
var width = argument("--width").flatMap(Int.init)
var height = argument("--height").flatMap(Int.init)
if let listingPath {
    guard let listed = readListing(at: listingPath) else {
        say(["event": "listingUnreadable"])
        exit(3)
    }
    service = listed.service
    if let listedWidth = listed.width, let listedHeight = listed.height {
        width = listedWidth
        height = listedHeight
    }
}
guard let service else {
    FileHandle.standardError.write(
        Data("usage: frame-receiver (--service <name> | --listing <file>) --width <w> --height <h>\n".utf8))
    exit(64)
}
guard let width, let height else {
    // 目録に寸法が無い (旧い送り手) か、従来の形で寸法を渡していない。利用者に指定を頼む
    say([
        "event": "sizeUnknown",
        "message": "The sketch's listing has no width and height (it was written by an older mokume). "
            + "Give --width and --height to connect.",
    ])
    exit(6)
}
say(["event": "size", "width": width, "height": height])
let surfaceCount = argument("--surfaces").flatMap(Int.init) ?? 3
let exitAfter = argument("--exit-after").flatMap(Int.init) ?? 0
let deadline = Date().addingTimeInterval(argument("--timeout").flatMap(Double.init) ?? 30)
let name = argument("--name")

/// 検査用: この回数目の connect (1 から数える。`,` で区切って複数) の直前に、自分の受信の待ち行列を詰め物で満杯にして、
/// 送り手の答えを落とさせる (#3968)。詰めた後は、標準入力に `resume` が届くまで読まない (検査が送り手に答えさせてから)。
let clogAttempts = Set((argument("--clog-attempt") ?? "").split(separator: ",").compactMap { Int($0) })
/// 検査用: この枚数を受けたら、同じ大きさの面を作り直して同じ port から繋ぎ直す。
let reconnectAfter = argument("--reconnect-after").flatMap(Int.init) ?? 0

// 標準入力が `resume` 以外の 1 行を届けるか閉じたら終わる。受信の権利ごと消えるので、送り手は dead-name で知る
let resumed = DispatchSemaphore(value: 0)
Thread.detachNewThread {
    while let line = readLine() {
        if line == "resume" {
            resumed.signal()
            continue
        }
        exit(0)
    }
    exit(0)
}

// 1. 名前を引く
guard let sketch = Bootstrap.lookUp(service) else {
    say(["event": "lookupFailed"])
    exit(3)
}
// 2. 送り手が消えたら知らせてもらう
var port: mach_port_t = 0
mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
var previous: mach_port_t = 0
mach_port_request_notification(
    mach_task_self_, sketch, MACH_NOTIFY_DEAD_NAME, 0, port,
    mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND_ONCE), &previous)

// 3. 面を作って繋ぐ
func makeSurfaces(width: Int, height: Int) -> [IOSurfaceRef] {
    (0..<surfaceCount).compactMap { _ in
        IOSurfaceCreate(
            [
                kIOSurfaceWidth: width, kIOSurfaceHeight: height, kIOSurfacePixelFormat: FrameLink.surfaceFormat,
                kIOSurfaceBytesPerElement: 8,
            ] as [CFString: Any] as CFDictionary)
    }
}
/// 自分の待ち行列を詰め物 (受け手には届かない種類の 1 通) で満杯にする。詰めた数を返す。
func clogQueue() -> Int {
    mach_port_insert_right(mach_task_self_, port, port, mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND))
    defer { mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_SEND, -1) }
    var count = 0
    while count < 256, FrameLink.send(.disconnect, to: port) == KERN_SUCCESS { count += 1 }
    return count
}

var surfaces = makeSurfaces(width: width, height: height)
/// 送った connect の数。
var attempts = 0
/// `accepted` で知った自分の番号。まだ知らない (または `disconnect` した) なら 0。
var receiverID: UInt32 = 0
/// 答え (`accepted`・`refused`) を待っている connect を送った時刻。答えが届けば `nil`。
var awaitingSince: Date?
/// 答えを待つ期限 (秒)。答えは待ち行列が満杯なら落ちる (#3968)。
let answerTimeout = argument("--answer-timeout").flatMap(Double.init) ?? 1
/// 答えが届かずに繋ぎ直した回数 (答えが届けば 0 に戻す)。3 回続けば諦める。
var lostAnswers = 0

/// いまの面で繋ぐ。
func connect() {
    // **繋ぐ前に自分の待ち行列を読み切る** (#3968)。残っているのは前の繋がりの知らせで、捨てる。読み切らないと、
    // 送り手の答えが満杯の待ち行列で落ちる
    while let stale = FrameLink.receive(on: port) {
        if stale.kind == Int32(MACH_NOTIFY_DEAD_NAME) {
            say(["event": "senderGone"])
            exit(0)
        }
    }
    attempts += 1
    awaitingSince = Date()
    let clogged = clogAttempts.contains(attempts) ? clogQueue() : 0
    let sent = FrameLink.connect(to: sketch, reply: port, surfaces: surfaces, name: name)
    say(["event": "connected", "result": Int(sent), "attempt": attempts, "clogged": clogged])
    if clogged > 0, resumed.wait(timeout: .now() + deadline.timeIntervalSinceNow) == .timedOut {
        say(["event": "timeout"])
        exit(5)
    }
}
connect()

/// 答えが期限までに届かなかった (#3968)。番号を知っていれば `disconnect` してから、知らなければ受信の port を作り直して
/// から繋ぎ直す。送り手は、`disconnect` か古い port の dead-name で、古い繋がりの枠を回収する。
func recoverFromALostAnswer() {
    lostAnswers += 1
    guard lostAnswers <= 3 else {
        say(["event": "gaveUp"])
        exit(7)
    }
    if receiverID != 0 {
        say(["event": "answerTimedOut", "known": true, "receiver": Int(receiverID)])
        var payload = FrameLink.Payload()
        payload.append(receiverID)
        FrameLink.send(.disconnect, to: sketch, payload: payload)
        receiverID = 0
    } else {
        say(["event": "answerTimedOut", "known": false])
        mach_port_mod_refs(mach_task_self_, port, MACH_PORT_RIGHT_RECEIVE, -1)
        mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &port)
        // 送り手が消えた知らせは古い port に頼んでいたので、新しい port に頼み直す
        var previous: mach_port_t = 0
        mach_port_request_notification(
            mach_task_self_, sketch, MACH_NOTIFY_DEAD_NAME, 0, port,
            mach_msg_type_name_t(MACH_MSG_TYPE_MAKE_SEND_ONCE), &previous)
        if previous != mach_port_t(MACH_PORT_NULL) { mach_port_deallocate(mach_task_self_, previous) }
    }
    surfaces = makeSurfaces(width: IOSurfaceGetWidth(surfaces[0]), height: IOSurfaceGetHeight(surfaces[0]))
    connect()
}

func centre(of surface: IOSurfaceRef) -> [Double] {
    IOSurfaceLock(surface, .readOnly, nil)
    defer { IOSurfaceUnlock(surface, .readOnly, nil) }
    let offset = (IOSurfaceGetHeight(surface) / 2) * IOSurfaceGetBytesPerRow(surface)
        + (IOSurfaceGetWidth(surface) / 2) * 8
    let components = IOSurfaceGetBaseAddress(surface).advanced(by: offset).assumingMemoryBound(to: Float16.self)
    return (0..<4).map { Double(components[$0]) }
}

func attribute(_ name: String, of surface: IOSurfaceRef) -> Any {
    IOSurfaceCopyValue(surface, name as CFString) ?? NSNull()
}

var frames = 0
/// 大きさで断られて目録を読み直した回数。送り手の大きさが変わり続けても、3 回で諦める。
var retries = 0
while Date() < deadline {
    if let since = awaitingSince, Date().timeIntervalSince(since) > answerTimeout {
        recoverFromALostAnswer()
        continue
    }
    guard let message = FrameLink.receive(on: port, timeout: 100) else { continue }
    var reader = message.payload.reader
    switch message.kind {
    case FrameLink.Kind.accepted.rawValue:
        receiverID = reader.uint32() ?? 0
        awaitingSince = nil
        lostAnswers = 0
        say(["event": "accepted", "receiver": Int(receiverID), "width": Int(reader.uint32() ?? 0),
             "height": Int(reader.uint32() ?? 0)])
    case FrameLink.Kind.refused.rawValue:
        let reason = reader.uint32() ?? 0
        awaitingSince = nil
        say(["event": "refused", "reason": Int(reason)])
        // 大きさで断られたら、目録を読み直して送り手がいま受け付ける大きさで繋ぎ直す (#3949)。送り手は断る前に目録を
        // 書き換えるので、読み直した大きさが試した大きさと同じなら、それ以上待っても変わらない
        if reason == FrameLink.Refusal.surfaceSize.rawValue, let listingPath, retries < 3,
            let listed = readListing(at: listingPath), listed.service == service,
            let newWidth = listed.width, let newHeight = listed.height,
            newWidth != IOSurfaceGetWidth(surfaces[0]) || newHeight != IOSurfaceGetHeight(surfaces[0])
        {
            retries += 1
            say(["event": "reread", "width": newWidth, "height": newHeight])
            surfaces = makeSurfaces(width: newWidth, height: newHeight)
            connect()
            continue
        }
        exit(4)
    case FrameLink.Kind.frame.rawValue:
        guard let receiver = reader.uint32(), let slot = reader.uint32(), let frameCount = reader.int64(),
            let writes = reader.int64(), let hostTime = reader.uint64(), Int(slot) < surfaces.count
        else { continue }
        // 答えを待つ間と、前の番号の frame は、前の繋がりの面のことなので数えない (返しもしない)
        guard awaitingSince == nil, receiver == receiverID else { continue }
        let surface = surfaces[Int(slot)]
        say([
            "event": "frame", "receiver": Int(receiver), "slot": Int(slot), "frameCount": frameCount,
            "writes": writes, "hostTime": hostTime, "pixel": centre(of: surface),
            "attributes": [
                "frameCount": attribute(FrameLink.Attribute.frameCount, of: surface),
                "frame": attribute(FrameLink.Attribute.writes, of: surface),
                "hostTime": attribute(FrameLink.Attribute.hostTime, of: surface),
                "colorSpace": attribute(FrameLink.Attribute.colorSpace, of: surface),
                "alpha": attribute(FrameLink.Attribute.alpha, of: surface),
            ],
        ])
        var payload = FrameLink.Payload()
        payload.append(receiver)
        payload.append(slot)
        FrameLink.send(.release, to: sketch, payload: payload)
        frames += 1
        if exitAfter > 0, frames >= exitAfter {
            say(["event": "done"])
            exit(0)
        }
        if reconnectAfter > 0, frames == reconnectAfter {
            surfaces = makeSurfaces(width: IOSurfaceGetWidth(surfaces[0]), height: IOSurfaceGetHeight(surfaces[0]))
            connect()
        }
    case FrameLink.Kind.resized.rawValue:
        let newWidth = Int(reader.uint32() ?? 0)
        let newHeight = Int(reader.uint32() ?? 0)
        say(["event": "resized", "width": newWidth, "height": newHeight])
        surfaces = makeSurfaces(width: newWidth, height: newHeight)
        connect()
    case FrameLink.Kind.disconnect.rawValue:
        // 詰め物 (`--clog-attempt`)。送り手からは届かない種類
        continue
    case Int32(MACH_NOTIFY_DEAD_NAME):
        // 6. 送り手が消えた
        say(["event": "senderGone"])
        exit(0)
    default:
        say(["event": "unknown", "kind": Int(message.kind)])
    }
}
say(["event": "timeout"])
exit(5)
