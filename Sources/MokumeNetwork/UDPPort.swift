// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import MokumeCore
import MokumeDiagnostics

/// UDP で文字列を受けて送る入り口。``Sketch/createUDP(listen:send:)`` が作り、走っているスケッチへ足す。
///
/// 1 つの datagram が 1 つのメッセージになる。受け方・状態・止め方は ``TextPort`` のとおり。
///
/// **ちょうど 9216 バイトの datagram は捨てて数える。** macOS の受け口は、ループバック (`127.0.0.1`・`::1`)
/// で届いた 9216 バイトを超える datagram を先頭 9216 バイトに黙って切る (別の機械から届いたものは全長で
/// 渡す)。切れたものはちょうど 9216 バイトで届き、本物の 9216 バイトと見分けられないので、ちょうど
/// 9216 バイトの datagram は丸ごと捨てて数え、次のフレームで診断に出す。9217 バイト以上のものは全長で届く。
/// **送りは 9215 バイトまで。** ``send(_:)`` は、UTF-8 で 9216 バイト以上の文字列は送らない。
///
/// **空の datagram (0 バイト) は空の文字列 `""` になる。** ただし macOS の受け口は、空の datagram を
/// 受けるとその送り元の流れを閉じることがあり、そのとき空の直後 (1 ミリ秒ほどの間) に同じ送り元から
/// 届いたものは届かない。この落ちた数は受け口から見えないので数えない。代わりに、空で流れが閉じたとき、
/// 落ちたかもしれないことを**送り元ごとに 1 度だけ**診断に出す (受け口と送り元を名乗る。覚える送り元は 256 までで、
/// 超えたら先に覚えた送り元から忘れる。実際には何も落ちていなくても出る)。``send(_:)`` で
/// `""` を送った直後に同じポートから送ったものも、相手が mokume の受け口なら落ちうる。
///
/// ```swift
/// final class Remote: Sketch {
///     var udp: UDPPort?
///     var size: Float = 0.5
///     func setup() throws { udp = try createUDP(listen: 6000, send: ("127.0.0.1", 6001)) }
///     func draw() {
///         for text in udp?.messages ?? [] { size = Float(text) ?? size }
///         circle(width / 2, height / 2, size * height)
///     }
///     func mousePressed() { udp?.send("hit") }
/// }
/// ```
///
/// 端末から `nc -u 127.0.0.1 6000` で繋いで `0.3` と打つと円が変わり、`nc -u -l 6001` で
/// 待っていればクリックの `hit` が出る。
///
/// **送れないことは ``TextPort/state`` に出ない。** ``TextPort/state`` が名乗るのは受けるほうの
/// 様子である。送れないとき (宛先で誰も受けていない・このアプリにローカルネットワークの許可が
/// 無い・ネットワークが落ちている) は、1 度だけ診断に出す。送れたら、また言えるように戻る (UDP の送信の
/// 完了は届いたことを言わず、拒否は次の送信の失敗として返るので、宛先に拒まれた後は、間 (既定 0.5 秒) を
/// 空けた次の送信まで拒まれずに終わって初めて「送れた」と読む)。
public final class UDPPort: TextPort {
    private let outbound: (any DatagramSending)?

    /// 送り手が見たことの跡。送り手が跡を持たなければ (記録するだけの送り手・送り先の無い入り口) `nil`。
    /// 検査が、送ったものが受け口で読まれなかった回の名乗りに載せる (#3001)。読むだけで、振る舞いを決めない。
    var sendTrace: SendTrace? { (outbound as? SendTracing)?.sendTrace }

    init(
        port: Int?, name: String, source: any MessageSource<String>,
        outbound: (any DatagramSending)?, owner: (any Sketch)?,
        warn: @escaping (String) -> Void = Diagnostics.warn
    ) {
        self.outbound = outbound
        super.init(port: port, name: name, source: source, owner: owner, warn: warn)
    }

    /// 作るときに決めた送り先 (``Sketch/createUDP(listen:send:)`` の `send`) へ、文字列を
    /// 1 つの datagram として送る。
    ///
    /// <!-- example: 文脈 var udp: UDPPort? -->
    /// ```swift
    /// udp?.send("hit")
    /// udp?.send("size 0.5")
    /// ```
    ///
    /// UTF-8 のバイト列をそのまま送り、改行は足さない。**投げない。** 送り先が無い・止めた後は、
    /// 理由ごとに 1 度だけ知らせて何もしない。UTF-8 で 9216 バイト以上 (1 つの datagram は
    /// 9215 バイトまで) のときも送らずに知らせ、続く間は 1 度だけ言う。送れないとき (宛先で誰も
    /// 受けていない・このアプリにローカルネットワークの許可が無い・ネットワークが落ちている) は
    /// 1 度だけ診断に出し、``TextPort/state`` には出ない。どちらも、送れたら、また言えるように
    /// 戻る (宛先に拒まれた後は、間 (既定 0.5 秒) を空けた次の送信まで拒まれずに終わって初めて「送れた」と
    /// 読む)。待たずに返る。
    ///
    /// - Parameter text: 送る文字列。
    public func send(_ text: String) {
        guard !closed else {
            tellOnce("stopped", "This UDP port is stopped, so \(Self.preview(text)) was not sent")
            return
        }
        guard let outbound else {
            if port == nil {
                tellOnce(
                    "recorded",
                    "This UDP port replays recorded messages and has nowhere to send, so "
                        + "\(Self.preview(text)) was not sent")
            } else {
                tellOnce(
                    "nowhere",
                    "This UDP port has nowhere to send, so \(Self.preview(text)) was not sent. "
                        + "Pass send: (host, port) to createUDP(listen:send:)")
            }
            return
        }
        let bytes = Array(text.utf8)
        // 送り手へ渡せば `Message too long` で送れず、受け手が居ない見当で名乗って繋ぎを捨てる
        guard Datagram.fits(bytes.count) else {
            tellOnce(
                "tooLarge",
                "\(Self.preview(text)) was not sent because it is \(bytes.count) bytes in UTF-8, "
                    + "and one UDP datagram carries \(Datagram.largest) bytes at most")
            return
        }
        // 大きすぎる送りが続く間は 1 度だけ言い、上限以内を送れたら、また言えるように戻す
        forget("tooLarge")
        outbound.send(bytes)
    }

    override func closeOutbound() {
        outbound?.stop()
    }
}
