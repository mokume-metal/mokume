// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

/// OSC のメッセージ 1 つ。宛名 (``address``) と、引数の並び (``arguments``) を持つ。
///
/// 届いたものは ``OSCPort/messages`` から読む。値を取り出す口 (``float(_:)`` ほか) は、
/// 型が合わない・その番号の引数が無いときに `nil` を返す。**黙って別の値を返さない。**
///
/// ```swift
/// final class Remote: Sketch {
///     var osc: OSCPort?
///     var size: Float = 0.5
///     func setup() { osc = try? createOSC(listen: 9000) }
///     func draw() {
///         for message in osc?.messages ?? [] where message.address == "/size" {
///             size = message.float(0) ?? size
///         }
///         circle(width / 2, height / 2, size * height)
///     }
/// }
/// ```
///
/// 注入する列 (``Sketch/createOSC(messages:)``) を組むときは、自分で作る。
///
/// ```swift
/// let wave = OSCMessage("/size", 0.25)
/// let hit = OSCMessage("/hit", 1)
/// ```
public nonisolated struct OSCMessage: Sendable, Equatable {
    /// 宛名。`/` で始まる (`/size`・`/layer/1/opacity`)。
    public let address: String
    /// 引数。届いた順。
    public let arguments: [OSCValue]

    /// メッセージを組む。
    ///
    /// - Parameters:
    ///   - address: 宛名。`/` で始める。
    ///   - arguments: 引数。`Int`・`Float`・`Double`・`String`・`Bool` か ``OSCValue``
    ///     (書き方は ``OSCArgument``)。
    public init(_ address: String, _ arguments: any OSCArgument...) {
        self.init(address, arguments: arguments.map(\.oscValue))
    }

    /// 引数を並びで渡して組む (読み取りの側が使う)。
    init(_ address: String, arguments: [OSCValue]) {
        self.address = address
        self.arguments = arguments
    }

    /// `index` 番目の引数を数として読む。整数 (`i`・`h`) も小数 (`f`・`d`) も読み、
    /// 数でなければ・その番号が無ければ `nil`。
    public func float(_ index: Int) -> Float? {
        guard arguments.indices.contains(index) else { return nil }
        switch arguments[index] {
        case .float(let value): return value
        case .double(let value): return Float(value)
        case .int(let value): return Float(value)
        case .int64(let value): return Float(value)
        default: return nil
        }
    }

    /// `index` 番目の引数を整数として読む。整数 (`i`・`h`) だけを読み、小数は丸めずに `nil`。
    public func int(_ index: Int) -> Int? {
        guard arguments.indices.contains(index) else { return nil }
        switch arguments[index] {
        case .int(let value): return Int(value)
        case .int64(let value): return Int(value)
        default: return nil
        }
    }

    /// `index` 番目の引数を文字列として読む。文字列 (`s`・`S`) でなければ・その番号が無ければ `nil`。
    public func string(_ index: Int) -> String? {
        guard arguments.indices.contains(index), case .string(let value) = arguments[index] else {
            return nil
        }
        return value
    }
}

/// OSC の引数 1 つ。括弧の中は、送られてくるときの型の印。
///
/// ここに無い型 (時刻・色・MIDI・配列など) を含むメッセージは読まずに捨てる
/// (``OSCPort`` の「読めないものは打ち切る」)。
public nonisolated enum OSCValue: Sendable, Equatable {
    /// 32 bit の整数 (`i`)。
    case int(Int32)
    /// 32 bit の小数 (`f`)。
    case float(Float)
    /// 文字列 (`s`。届いたときは記号 `S` もここに入る)。
    case string(String)
    /// バイトの並び (`b`)。
    case blob([UInt8])
    /// 64 bit の整数 (`h`)。
    case int64(Int64)
    /// 64 bit の小数 (`d`)。
    case double(Double)
    /// 真偽 (`T` / `F`)。値は型の印そのもので、中身のバイトを持たない。
    case bool(Bool)
    /// 空 (`N`)。
    case null
    /// 合図 (`I`)。値を持たない「いま」の印。
    case impulse
}

/// メッセージの引数として渡せる値。
///
/// `Int`・`Float`・`Double`・`String`・`Bool` と ``OSCValue`` が準拠している。小数は既定で
/// 32 bit (`f`) で送る — 受け手 (TouchDesigner・Max など) が最も広く読む形だからである。
/// 64 bit で送るときは ``OSCValue/double(_:)`` を渡す。
///
/// ```swift
/// let message = OSCMessage("/layer", 2, 0.5, "fade", true)
/// ```
public nonisolated protocol OSCArgument {
    /// 送るときの値。
    var oscValue: OSCValue { get }
}

nonisolated extension OSCValue: OSCArgument {
    /// そのまま送る。
    public var oscValue: OSCValue { self }
}

nonisolated extension Int: OSCArgument {
    /// 32 bit に収まれば `i`、収まらなければ 64 bit の `h` で送る。値は丸めない。
    public var oscValue: OSCValue {
        if let narrow = Int32(exactly: self) { return .int(narrow) }
        return .int64(Int64(self))
    }
}

nonisolated extension Float: OSCArgument {
    /// 32 bit の小数 (`f`) で送る。
    public var oscValue: OSCValue { .float(self) }
}

nonisolated extension Double: OSCArgument {
    /// 32 bit の小数 (`f`) で送る。小数を書いただけの値 (`0.5`) は `Double` になるので、
    /// `Float` と同じ形で送る。64 bit で送るなら ``OSCValue/double(_:)`` を渡す。
    public var oscValue: OSCValue { .float(Float(self)) }
}

nonisolated extension String: OSCArgument {
    /// 文字列 (`s`) で送る。
    public var oscValue: OSCValue { .string(self) }
}

nonisolated extension Bool: OSCArgument {
    /// 真偽 (`T` / `F`) で送る。
    public var oscValue: OSCValue { .bool(self) }
}
