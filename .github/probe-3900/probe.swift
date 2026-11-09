// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

// #3900 の実測用 (使い捨て)。bootstrap の名前空間で、送り手 (スケッチ) が check_in した名前を
// 受け手が look_up し、受け手の port と受け手が用意した IOSurface を mach port で渡して、
// 送り手が面を引けるかを確かめる。向きは #3900 の決定 B (待つのはスケッチ、面は受け手)。
//
//   probe sketch <name>          check_in して 1 通受け、面を引いて ID を返す (送り手)
//   probe viewer <name>          look_up して port と面を送り、返事の ID を照らす (受け手)
//   probe pair                   自分が sketch になり、子プロセスで viewer を起こす
import Darwin
import Foundation
import IOSurface

typealias BootstrapCall = @convention(c) (mach_port_t, UnsafePointer<CChar>, UnsafeMutablePointer<mach_port_t>) -> kern_return_t
let libSystem = dlopen(nil, RTLD_NOW)
let checkIn = unsafeBitCast(dlsym(libSystem, "bootstrap_check_in"), to: BootstrapCall.self)
let lookUp = unsafeBitCast(dlsym(libSystem, "bootstrap_look_up"), to: BootstrapCall.self)

func bootstrapPort() -> mach_port_t {
    var port: mach_port_t = 0
    task_get_special_port(mach_task_self_, TASK_BOOTSTRAP_PORT, &port)
    return port
}

func say(_ s: String) { print("[\(CommandLine.arguments.dropFirst().first ?? "?") pid=\(getpid())] \(s)"); fflush(stdout) }

let headerSize = 24, bodySize = 4, descSize = 12
let complexBits: UInt32 = 0x8000_0000
let copySend: UInt32 = 19, makeSend: UInt32 = 20, moveSend: UInt32 = 17

func writeDescriptor(_ p: UnsafeMutableRawPointer, port: mach_port_t, disposition: UInt32) {
    p.storeBytes(of: port, as: UInt32.self)
    p.storeBytes(of: 0, toByteOffset: 4, as: UInt32.self)
    // pad2 (16 bit) / disposition (8 bit) / type (8 bit, MACH_MSG_PORT_DESCRIPTOR = 0)
    p.storeBytes(of: disposition << 16, toByteOffset: 8, as: UInt32.self)
}

func sketch(_ name: String) -> Int32 {
    var receive: mach_port_t = 0
    let kr = checkIn(bootstrapPort(), name, &receive)
    say("check_in \(name) -> \(kr) (\(String(cString: mach_error_string(kr))))")
    guard kr == KERN_SUCCESS else { return 2 }
    FileManager.default.createFile(atPath: "/tmp/\(name).ready", contents: nil)
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 1024, alignment: 8)
    let r = mach_msg(buffer.assumingMemoryBound(to: mach_msg_header_t.self),
                     MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 1024, receive, 30_000, 0)
    say("receive -> \(r)")
    guard r == KERN_SUCCESS else { return 3 }
    let count = buffer.load(fromByteOffset: headerSize, as: UInt32.self)
    let replyPort = buffer.load(fromByteOffset: headerSize + bodySize, as: UInt32.self)
    let surfacePort = buffer.load(fromByteOffset: headerSize + bodySize + descSize, as: UInt32.self)
    say("descriptors=\(count) reply=\(replyPort) surface=\(surfacePort)")
    guard let surface = IOSurfaceLookupFromMachPort(surfacePort) else { say("IOSurfaceLookupFromMachPort -> nil"); return 4 }
    let id = IOSurfaceGetID(surface)
    say("surface id=\(id) \(IOSurfaceGetWidth(surface))x\(IOSurfaceGetHeight(surface))")
    let reply = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
    reply.initializeMemory(as: UInt8.self, repeating: 0, count: 32)
    reply.storeBytes(of: moveSend, as: UInt32.self)
    reply.storeBytes(of: UInt32(headerSize + 4), toByteOffset: 4, as: UInt32.self)
    reply.storeBytes(of: replyPort, toByteOffset: 8, as: UInt32.self)
    reply.storeBytes(of: 2, toByteOffset: 20, as: Int32.self)
    reply.storeBytes(of: id, toByteOffset: headerSize, as: UInt32.self)
    let s = mach_msg(reply.assumingMemoryBound(to: mach_msg_header_t.self),
                     MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(headerSize + 4), 0, 0, 5_000, 0)
    say("reply -> \(s)")
    return s == KERN_SUCCESS ? 0 : 5
}

func viewer(_ name: String) -> Int32 {
    var server: mach_port_t = 0
    let kr = lookUp(bootstrapPort(), name, &server)
    say("look_up \(name) -> \(kr) (\(String(cString: mach_error_string(kr))))")
    guard kr == KERN_SUCCESS else { return 2 }
    var replyPort: mach_port_t = 0
    mach_port_allocate(mach_task_self_, MACH_PORT_RIGHT_RECEIVE, &replyPort)
    let props: [String: Any] = [kIOSurfaceWidth as String: 64, kIOSurfaceHeight as String: 32,
                                kIOSurfaceBytesPerElement as String: 8, kIOSurfacePixelFormat as String: 0x5247_6841]
    guard let surface = IOSurfaceCreate(props as CFDictionary) else { say("IOSurfaceCreate -> nil"); return 3 }
    let surfacePort = IOSurfaceCreateMachPort(surface)
    let size = headerSize + bodySize + 2 * descSize
    let msg = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
    msg.initializeMemory(as: UInt8.self, repeating: 0, count: size)
    msg.storeBytes(of: copySend | complexBits, as: UInt32.self)
    msg.storeBytes(of: UInt32(size), toByteOffset: 4, as: UInt32.self)
    msg.storeBytes(of: server, toByteOffset: 8, as: UInt32.self)
    msg.storeBytes(of: 1, toByteOffset: 20, as: Int32.self)
    msg.storeBytes(of: 2, toByteOffset: headerSize, as: UInt32.self)
    writeDescriptor(msg + headerSize + bodySize, port: replyPort, disposition: makeSend)
    writeDescriptor(msg + headerSize + bodySize + descSize, port: surfacePort, disposition: copySend)
    let s = mach_msg(msg.assumingMemoryBound(to: mach_msg_header_t.self),
                     MACH_SEND_MSG | MACH_SEND_TIMEOUT, mach_msg_size_t(size), 0, 0, 5_000, 0)
    say("send -> \(s)")
    guard s == KERN_SUCCESS else { return 4 }
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: 256, alignment: 8)
    let r = mach_msg(buffer.assumingMemoryBound(to: mach_msg_header_t.self),
                     MACH_RCV_MSG | MACH_RCV_TIMEOUT, 0, 256, replyPort, 10_000, 0)
    guard r == KERN_SUCCESS else { say("receive reply -> \(r)"); return 5 }
    let echoed = buffer.load(fromByteOffset: headerSize, as: UInt32.self)
    let mine = IOSurfaceGetID(surface)
    say("reply id=\(echoed) mine=\(mine) -> \(echoed == mine ? "OK" : "MISMATCH")")
    return echoed == mine ? 0 : 6
}

func pair() -> Int32 {
    let name = "dev.mokume.probe3900.pair.\(getpid())"
    var child: pid_t = 0
    let me = CommandLine.arguments[0]
    let argv: [UnsafeMutablePointer<CChar>?] = [strdup(me), strdup("viewer-wait"), strdup(name), nil]
    let spawned = posix_spawn(&child, me, nil, nil, argv, environ)
    say("spawn viewer -> \(spawned) pid=\(child)")
    let result = sketch(name)
    var status: Int32 = 0
    waitpid(child, &status, 0)
    say("viewer exit=\((status >> 8) & 0xff)")
    return result == 0 && (status >> 8) & 0xff == 0 ? 0 : 1
}

let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "sketch": exit(sketch(args[2]))
case "viewer": exit(viewer(args[2]))
case "viewer-wait":
    // 親が check_in するまで待つ (印のファイル。最大 10 秒)
    let deadline = Date().addingTimeInterval(10)
    while !FileManager.default.fileExists(atPath: "/tmp/\(args[2]).ready") && Date() < deadline { usleep(10_000) }
    exit(viewer(args[2]))
case "pair": exit(pair())
default: print("usage: probe sketch|viewer|pair <name>"); exit(64)
}
