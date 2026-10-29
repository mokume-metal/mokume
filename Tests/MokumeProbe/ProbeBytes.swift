// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Foundation

/// **読み込みの口へ壊した入力を当てる** ための、``Probe`` の上の層 (#3207 の提案 5・#3220)。
///
/// 正しい見本のバイト列から、1 バイトの反転・切り詰め・NUL の挿入・桁の巨大化のどれかをした入力を
/// 作る。壊し方は ``ProbeAxis`` の座標 (見本の番号・種類・位置・量) で持つので、seed からの生成も縮小も
/// ``Probe/run(_:suite:key:axes:cases:shrinkSteps:environment:check:)`` の仕組みのまま働く。赤になれば、
/// 縮んだ座標の入力を ``describe(_:)`` で名乗る。
///
/// 約束は検査が持つ — 「落ちない・止まらない・成功か名乗りつきの失敗のどちらかで答える」。落ちる
/// (`fatalError`・範囲外) のはプロセスごとなので述語では捕まえられない。``Guarded`` が、落ちる直前の入力を
/// 標準エラーへ名乗り、止まる入力は期限を持って切り離す。
public nonisolated enum ProbeBytes {
    /// 壊し方。座標の `kind` の値 (0 から) の並びと同じ。
    public enum Kind: Int, CaseIterable, Sendable {
        /// 1 バイトを反転する (量が半分未満なら 1 bit、それ以上なら 8 bit)。
        case flip
        /// 先頭からの一部だけを残す (位置が残す割合)。
        case truncate
        /// NUL を 1 つ挿す。
        case insertNUL
        /// 位置に近い数字の並びを、量に応じた桁数 (3〜400) の `9` に替える。数字が無ければ挿す。
        case bigNumber
    }

    /// 座標。`samples` は見本の数。縮める先は、残る入力が最も短い切り詰めの先頭 (`kind` = 切り詰め・位置 0)。
    public static func axes(samples: Int) -> [ProbeAxis] {
        [
            ProbeAxis("sample", 0..<Double(max(1, samples)), simplest: 0, step: 1),
            ProbeAxis("kind", 0..<Double(Kind.allCases.count), simplest: Double(Kind.truncate.rawValue), step: 1),
            ProbeAxis("at", 0..<1, simplest: 0),
            ProbeAxis("amount", 0..<1, simplest: 0),
        ]
    }

    /// 見本の 1 つを、座標どおりに壊す。
    public static func mutate(_ samples: [[UInt8]], _ input: ProbeInput) -> [UInt8] {
        let sample = samples[min(samples.count - 1, Int(input["sample"]))]
        let kind = Kind(rawValue: Int(input["kind"])) ?? .flip
        return mutate(sample, kind, at: input["at"], amount: input["amount"])
    }

    public static func mutate(_ sample: [UInt8], _ kind: Kind, at: Double, amount: Double) -> [UInt8] {
        var out = sample
        let index = min(max(0, Int(at * Double(sample.count))), max(0, sample.count - 1))
        switch kind {
        case .flip:
            guard !out.isEmpty else { return out }
            out[index] ^= amount < 0.5 ? UInt8(1) << UInt8(min(7, Int(amount * 16))) : 0xFF
        case .truncate:
            out = Array(sample.prefix(Int(at * Double(sample.count))))
        case .insertNUL:
            out.insert(0, at: min(out.count, Int(at * Double(out.count + 1))))
        case .bigNumber:
            let digits = [UInt8](repeating: UInt8(ascii: "9"), count: 3 + Int(amount * 397))
            // 位置の後ろで最初の数字の並びを探し、無ければ前へ戻って探す
            let isDigit: (UInt8) -> Bool = { (0x30...0x39).contains($0) }
            let start = sample[index...].firstIndex(where: isDigit) ?? sample[..<index].lastIndex(where: isDigit)
            if let start {
                var end = start
                while end < sample.count, isDigit(sample[end]) { end += 1 }
                var first = start
                while first > 0, isDigit(sample[first - 1]) { first -= 1 }
                out.replaceSubrange(first..<end, with: digits)
            } else {
                out.insert(contentsOf: digits, at: index)
            }
        }
        return out
    }

    /// 入力を赤の文面へ載せる短い表記。大きさと、頭の `limit` バイトを制御文字を逃がして示す。
    public static func describe(_ bytes: [UInt8], limit: Int = 100) -> String {
        var text = ""
        for byte in bytes.prefix(limit) {
            switch byte {
            case 0x0A: text += "\\n"
            case 0x0D: text += "\\r"
            case 0x09: text += "\\t"
            case 0x20...0x7E: text.append(Character(UnicodeScalar(byte)))
            default: text += String(format: "\\x%02X", byte)
            }
        }
        let tail = bytes.count > limit ? "…" : ""
        return "入力 (\(bytes.count) バイト) \"\(text)\(tail)\""
    }

    /// 壊した入力を文字として渡す口へ (UTF-8 として読めない並びは U+FFFD に直る)。
    public static func text(_ bytes: [UInt8]) -> String { String(decoding: bytes, as: UTF8.self) }
}

/// 述語を期限つきで走らせ、落ちる直前の入力を名乗る。
///
/// **待つ側が期限を持つ** (止まる入力は、走らせた側が待ちを切って赤にする)。走らせた本体は殺せない
/// ので別のスレッドに残るが、検査のプロセスはその終わりで閉じる。**落ちる入力は、信号の handler が
/// 標準エラーに入力を名乗ってから、元の信号で終える** (`fatalError` は `SIGTRAP`・範囲外などは
/// `SIGILL`・`SIGSEGV`)。名乗りはスレッドごとに持つので、並んで走る別の検査の入力と取り違えない。
public nonisolated enum Guarded {
    /// 期限内に返った結果。期限を越えたら `nil`。
    public static func run<Result: Sendable>(
        _ label: @autoclosure () -> String, limit: TimeInterval = 10, _ body: @escaping @Sendable () -> Result
    ) -> Result? {
        installHandlerOnce()
        let box = Box<Result>()
        let name = label()
        let finished = DispatchSemaphore(value: 0)
        let thread = Thread {
            mark(name)
            box.value = body()
            unmark()
            finished.signal()
        }
        // 主のスレッドと同じ深さまで再帰できるようにする (既定の 512 KiB は浅い)
        thread.stackSize = 8 << 20
        thread.start()
        guard finished.wait(timeout: .now() + limit) == .success else { return nil }
        return box.value
    }

    private final class Box<Value>: @unchecked Sendable {
        var value: Value?
    }

    /// スレッドごとの印の置き場 (C の文字列。信号の handler から読む)。
    nonisolated(unsafe) private static var key: pthread_key_t = {
        var key = pthread_key_t()
        pthread_key_create(&key) { free($0) }
        return key
    }()

    /// いまのスレッドが渡されている入力を控える (``run(_:limit:_:)`` を通らない口、たとえば主の actor の
    /// 上でしか呼べない口から使う)。落ちたとき、信号の handler がこの文を標準エラーに書く。
    public static func mark(_ text: String) {
        installHandlerOnce()
        if let old = pthread_getspecific(key) { free(old) }
        pthread_setspecific(key, strdup(text))
    }

    /// ``mark(_:)`` した入力を忘れる。
    public static func unmark() {
        if let old = pthread_getspecific(key) { free(old) }
        pthread_setspecific(key, nil)
    }

    private static let installed: Void = {
        _ = key
        let handler: @convention(c) (Int32) -> Void = { signal in
            // 印の無いスレッド (生成器を通らない別の検査) の落ちは名乗らない — 入力の取り違えに見える
            if let label = pthread_getspecific(Guarded.key)?.assumingMemoryBound(to: CChar.self) {
                let prefix = "\n[probe] 落ちる直前に渡していた "
                _ = prefix.withCString { write(2, $0, strlen($0)) }
                _ = write(2, label, strlen(label))
                _ = "\n".withCString { write(2, $0, 1) }
            }
            // 既定の動きへ戻して、同じ信号で終える
            Foundation.signal(signal, SIG_DFL)
            raise(signal)
        }
        for signal in [SIGILL, SIGTRAP, SIGSEGV, SIGBUS, SIGABRT, SIGFPE] {
            Foundation.signal(signal, handler)
        }
    }()

    private static func installHandlerOnce() { _ = installed }
}
