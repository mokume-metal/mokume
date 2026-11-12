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
// 標準入力が 1 行届くか閉じると終わる (検査が、受け手の側から切る形を作れるように)。
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
    // 幅と高さは揃っていて 1 以上の整数のときだけ使う (片方だけ・それ以外の値なら無いのと同じ)
    guard let width = pixels(object["width"]), let height = pixels(object["height"]) else {
        return (service, nil, nil)
    }
    return (service, width, height)
}

/// 大きさの欄を読む。**1 以上の整数だけ** — `JSONSerialization` の `true` は `as? Int` で 1 と読めてしまうので、真偽値を
/// 先に除く。小数・文字列・0 以下も大きさとして受けない。
func pixels(_ value: Any?) -> Int? {
    guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), let whole = value as? Int,
        whole >= 1
    else { return nil }
    return whole
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
var surfaces = makeSurfaces(width: width, height: height)
let sent = FrameLink.connect(to: sketch, reply: port, surfaces: surfaces, name: name)
say(["event": "connected", "result": Int(sent)])

// 標準入力が 1 行届くか閉じたら終わる。受信の権利ごと消えるので、送り手は dead-name で知る
Thread.detachNewThread {
    _ = readLine()
    exit(0)
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

var receiverID: UInt32 = 0
var frames = 0
/// 大きさで断られて目録を読み直した回数。送り手の大きさが変わり続けても、3 回で諦める。
var retries = 0
while Date() < deadline {
    guard let message = FrameLink.receive(on: port, timeout: 100) else { continue }
    var reader = message.payload.reader
    switch message.kind {
    case FrameLink.Kind.accepted.rawValue:
        receiverID = reader.uint32() ?? 0
        say(["event": "accepted", "receiver": Int(receiverID), "width": Int(reader.uint32() ?? 0),
             "height": Int(reader.uint32() ?? 0)])
    case FrameLink.Kind.refused.rawValue:
        let reason = reader.uint32() ?? 0
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
            FrameLink.connect(to: sketch, reply: port, surfaces: surfaces, name: name)
            continue
        }
        exit(4)
    case FrameLink.Kind.frame.rawValue:
        guard let receiver = reader.uint32(), let slot = reader.uint32(), let frameCount = reader.int64(),
            let writes = reader.int64(), let hostTime = reader.uint64(), Int(slot) < surfaces.count
        else { continue }
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
    case FrameLink.Kind.resized.rawValue:
        let newWidth = Int(reader.uint32() ?? 0)
        let newHeight = Int(reader.uint32() ?? 0)
        say(["event": "resized", "width": newWidth, "height": newHeight])
        surfaces = makeSurfaces(width: newWidth, height: newHeight)
        FrameLink.connect(to: sketch, reply: port, surfaces: surfaces, name: name)
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
