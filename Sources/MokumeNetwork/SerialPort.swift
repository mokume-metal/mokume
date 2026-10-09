// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation
import IOKit
import IOKit.serial

/// 繋がっているシリアルポート 1 つ。``Sketch/serialPorts()`` が返し、
/// ``Sketch/createSerial(_:baudRate:)`` で使う 1 つを選ぶ。
///
/// **一覧から得た識別子で選ぶ** ([ADR-0028] 決定 3)。``CaptureDevice``・``AudioDevice`` と
/// 同じ形である。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public nonisolated struct SerialPort: Sendable, Equatable, Hashable {
    /// 識別子。ポートの経路 (`"/dev/cu.usbmodem14101"` など)。同じ USB の口に挿し直せば同じ値に
    /// なる (機材によっては、別の口に挿すと変わる)。
    public let id: String
    /// 人が読む名前。USB で繋いだものは機材が名乗る製品名 (`"Arduino Uno"` など)、それ以外は
    /// 経路の名前 (`"Bluetooth-Incoming-Port"` など)。
    public let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// 繋がっているポート。並び方は ``ordered(_:)`` のとおり。
    static func connected() -> [SerialPort] {
        ordered(IOSerialPorts.entries())
    }

    /// 一覧の並び。**USB で繋いだものを先に、残りを後に**置き、どちらの組の中も識別子の順にする。
    ///
    /// Mac は自分のポート (`/dev/cu.Bluetooth-Incoming-Port`・`/dev/cu.debug-console`) を持って
    /// いて、OS が返す順ではそれが先に来る (2026-10-10 に、USB の機材を挿していない機械で実測)。
    /// そのままでは、作例の `serialPorts().first` が Arduino ではなく Mac 自身のポートを掴む。
    /// 並べ方を決めるだけで、位置や役割で選ぶ口は置かない ([ADR-0028] 決定 3)。
    ///
    /// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
    static func ordered(_ entries: [IOSerialPorts.Entry]) -> [SerialPort] {
        entries.sorted { left, right in
            if left.isUSB != right.isUSB { return left.isUSB }
            return left.port.id < right.port.id
        }.map(\.port)
    }
}

/// IOKit のシリアルポートの問い合わせ。**IOKit の型はここの外へ出さない** ([ADR-0020] 決定 6)。
///
/// [ADR-0020]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0020-api-naming-and-surface.md
nonisolated enum IOSerialPorts {
    /// ポート 1 つと、USB で繋いだものか。
    struct Entry: Equatable {
        let port: SerialPort
        let isUSB: Bool
    }

    /// 開けるポート (`IOSerialBSDClient`) の全部。経路はコールアウトの側 (`/dev/cu.*`) を使う —
    /// `/dev/tty.*` の側は、相手が搬送の信号を上げるまで開くのを待つ。
    static func entries() -> [Entry] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return [] }
        defer { IOObjectRelease(iterator) }
        var entries: [Entry] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(kIOCalloutDeviceKey, of: service) as? String else { continue }
            let product = ancestor(usbProductKey, of: service) as? String
            let tty = property(kIOTTYDeviceKey, of: service) as? String
            entries.append(
                Entry(
                    port: SerialPort(id: path, name: product ?? tty ?? path),
                    isUSB: ancestor(usbVendorKey, of: service) != nil))
        }
        return entries
    }

    /// USB の機材が名乗る製品名の鍵 (`kUSBProductString`)。
    static let usbProductKey = "USB Product Name"
    /// USB の機材の売り手の番号の鍵。USB で繋いだものかの見分けに使う。
    static let usbVendorKey = "idVendor"

    private static func property(_ key: String, of service: io_object_t) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    /// 自分か、先祖 (ポートを載せている USB の機材など) が持つ値。
    private static func ancestor(_ key: String, of service: io_object_t) -> Any? {
        IORegistryEntrySearchCFProperty(
            service, kIOServicePlane, key as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
    }
}
