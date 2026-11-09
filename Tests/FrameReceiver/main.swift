// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// 本体の中の最小の受け手 ([ADR-0049] 決定 7・#3922)。走っているスケッチの名前を引いて繋ぎ、届いた出来事を 1 行 1 JSON で
// 標準出力に出す。`FrameLinkContractTests` が子として起こし、別のプロセスとの往復を確かめる。product には含めない。
//
// 手順の正本は `Schemas/frame-link.md`。外のアプリが書く受け手と同じことだけをする (送り手の内部には触れない)。
//
//   frame-receiver --service <名前> --width <幅> --height <高さ> [--surfaces 3] [--name <名乗り>]
//                  [--exit-after <枚数>] [--timeout <秒>]
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

guard let service = argument("--service"), let width = argument("--width").flatMap(Int.init),
    let height = argument("--height").flatMap(Int.init)
else {
    FileHandle.standardError.write(Data("usage: frame-receiver --service <name> --width <w> --height <h>\n".utf8))
    exit(64)
}
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
while Date() < deadline {
    guard let message = FrameLink.receive(on: port, timeout: 100) else { continue }
    var reader = message.payload.reader
    switch message.kind {
    case FrameLink.Kind.accepted.rawValue:
        receiverID = reader.uint32() ?? 0
        say(["event": "accepted", "receiver": Int(receiverID), "width": Int(reader.uint32() ?? 0),
             "height": Int(reader.uint32() ?? 0)])
    case FrameLink.Kind.refused.rawValue:
        say(["event": "refused", "reason": Int(reader.uint32() ?? 0)])
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
