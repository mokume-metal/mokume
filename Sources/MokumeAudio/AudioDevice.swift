// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import CoreAudio

/// 繋がっている音の入力の機材 1 つ。``Sketch/audioInputDevices()`` が返し、
/// ``Sketch/createAudioIn(device:)`` で使う 1 つを選ぶ。
///
/// **一覧の位置では選ばない** ([ADR-0028] 決定 3)。抜き差しで並びが変わるので、一覧から得た
/// 識別子で選ぶ。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
public nonisolated struct AudioDevice: Sendable, Equatable, Hashable {
    /// 識別子。抜いて挿し直しても同じ値になる。
    public let id: String
    /// 人が読む名前 (`"MacBook Pro Microphone"` など)。
    public let name: String

    init(id: String, name: String) {
        self.id = id
        self.name = name
    }

    /// 繋がっている入力の機材。OS が返す順に並べる。
    static func connected() -> [AudioDevice] {
        CoreAudioDevices.inputs().map(\.device)
    }
}

/// Core Audio の機材の問い合わせ。**Core Audio の型はここと ``MicrophoneSource`` の外へ出さない**
/// ([ADR-0042] 決定 7)。
///
/// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md
nonisolated enum CoreAudioDevices {
    /// 入力を持つ機材 1 つと、その Core Audio の番号。
    struct Entry: Equatable {
        let object: AudioObjectID
        let device: AudioDevice
    }

    /// 入力を持つ機材。
    static func inputs() -> [Entry] {
        allObjects().compactMap { object in
            guard hasInput(object), let id = string(kAudioDevicePropertyDeviceUID, of: object)
            else { return nil }
            let name = string(kAudioObjectPropertyName, of: object) ?? id
            return Entry(object: object, device: AudioDevice(id: id, name: name))
        }
    }

    /// 既定の入力の機材。無ければ `nil`。
    static func defaultInput() -> AudioObjectID? {
        var address = globalAddress(kAudioHardwarePropertyDefaultInputDevice)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &object)
        guard status == noErr, object != kAudioObjectUnknown, hasInput(object) else { return nil }
        return object
    }

    /// 繋がっている機材すべての番号。
    static func allObjects() -> [AudioObjectID] {
        var address = globalAddress(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0
        else { return [] }
        var objects = [AudioObjectID](
            repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr
        else { return [] }
        return objects
    }

    /// 番号の機材が入力の流れを持つか。
    private static func hasInput(_ object: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreams, mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size) == noErr && size > 0
    }

    private static func string(_ selector: AudioObjectPropertySelector, of object: AudioObjectID)
        -> String?
    {
        var address = globalAddress(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    static func globalAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }
}
