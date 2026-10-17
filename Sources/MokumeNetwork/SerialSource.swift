// SPDX-FileCopyrightText: 2026 mokume-metal
// SPDX-License-Identifier: MIT

import Darwin
import Foundation
import MokumeCore

// シリアルポートを開いて読む層。termios で開き、届いたバイト列を TCP の行と同じ決まり
// (``LineSplitter``・``TextDecoding``) で行に切って、落とさない列へ入れる。
//
// 読み取りの知らせ (`DispatchSourceRead`) は ``SerialReader`` の待ち行列の上で受け、読んだ行を
// 列へ入れるところで手を離す。境界を越えるのは行 (`Sendable`) と状態だけである ([ADR-0042]
// 決定 7 の条件)。
//
// [ADR-0042]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0042-camera-and-audio-standard.md

/// シリアルポートを termios で開く手続き。**開く手は差し替えられる** — 使用中 (`EBUSY`) は擬似端末
/// では作れない (`TIOCEXCL` が効かないことを 2026-10-10 に実測) ので、検査が開く手を差し替えて
/// 確かめる。
nonisolated enum SerialDevice {
    /// 開く手。開けたら読み書きの番号を、開けなければ理由を返す。
    typealias Opener = @Sendable (_ path: String, _ baudRate: Int) -> Result<Int32, Failure>

    /// 開けなかった理由。
    enum Failure: Error, Equatable, Sendable {
        /// 経路が無い (繋がっていない・抜かれた)。
        case absent
        /// 他のアプリが使っている。
        case busy
        /// ボーレートを受け付けない。`code` は `errno`。
        case rejectedRate(code: Int32)
        /// それ以外。`call` は転んだ呼び出し、`code` は `errno`。
        case failed(call: String, code: Int32)

        /// `open` が返した `errno` を読み替える。
        init(opening code: Int32) {
            switch code {
            case ENOENT, ENXIO, ENODEV: self = .absent
            case EBUSY: self = .busy
            default: self = .failed(call: "open", code: code)
            }
        }

        /// 同じ理由を 2 度言わないための鍵。
        var key: String {
            switch self {
            case .absent: "absent"
            case .busy: "busy"
            case .rejectedRate: "rejectedRate"
            case .failed(let call, let code): "\(call):\(code)"
            }
        }

        /// 開き直せば開けうるか。**ボーレートを受け付けないものは開き直さない** — 開くたびに DTR が
        /// 上がって、多くの Arduino がリセットされるからである。
        var retries: Bool {
            if case .rejectedRate = self { return false }
            return true
        }

        /// 診断の文面。
        func message(path: String, baudRate: Int, retryAfter: TimeInterval) -> String {
            switch self {
            case .absent:
                "The serial port \(path) is not connected. It starts receiving when it is plugged in"
            case .busy:
                "The serial port \(path) is in use by another app (the Serial Monitor of the Arduino "
                    + "IDE, for example). It starts receiving when the port is freed"
            case .rejectedRate(let code):
                "The serial port \(path) does not accept \(baudRate) baud (\(Self.text(code))). Pass "
                    + "a rate the device supports (9600 or 115200, for example) and start the sketch again"
            case .failed(let call, let code):
                "Could not open the serial port \(path) (\(call): \(Self.text(code))). It tries again "
                    + "every \(Int(retryAfter.rounded(.up))) second(s)"
            }
        }

        private static func text(_ code: Int32) -> String {
            String(cString: strerror(code))
        }
    }

    /// 開いて、8 ビット・パリティなし・ストップビット 1・流れ制御なしの raw にする。
    ///
    /// - `O_NONBLOCK` で開く。読み取りは知らせを受けてから読むので、待たない
    /// - **排他にする** (`TIOCEXCL`)。開いている間は、他のアプリが開くと `EBUSY` になる。2 つの
    ///   アプリが同じポートを読むと、届いたバイト列が両方へ割れて、どちらにも欠けた行が届く
    /// - 開く前に届いていた分は捨てる (前の速さで読んだかもしれないもの)
    static func open(_ path: String, baudRate: Int) -> Result<Int32, Failure> {
        let descriptor = Darwin.open(path, O_RDWR | O_NOCTTY | O_NONBLOCK)
        guard descriptor >= 0 else { return .failure(Failure(opening: errno)) }
        if let failure = configure(descriptor, baudRate: baudRate) {
            Darwin.close(descriptor)
            return .failure(failure)
        }
        return .success(descriptor)
    }

    private static func configure(_ descriptor: Int32, baudRate: Int) -> Failure? {
        guard ioctl(descriptor, exclusive) == 0 else {
            return .failed(call: "ioctl(TIOCEXCL)", code: errno)
        }
        var options = termios()
        guard tcgetattr(descriptor, &options) == 0 else {
            return .failed(call: "tcgetattr", code: errno)
        }
        cfmakeraw(&options)
        options.c_cflag &= ~tcflag_t(CSIZE | PARENB | CSTOPB | CRTSCTS)
        options.c_cflag |= tcflag_t(CS8 | CLOCAL | CREAD)
        // 1 バイトでも届けば読める。待つのは知らせのほうなので、時間切れは置かない
        withUnsafeMutableBytes(of: &options.c_cc) { characters in
            characters[Int(VMIN)] = 1
            characters[Int(VTIME)] = 0
        }
        cfsetspeed(&options, speed_t(baudRate))
        if tcsetattr(descriptor, TCSANOW, &options) != 0 {
            // 標準に無い速さ (250000 など) を termios では受けないドライバがある。そのときは
            // 標準の速さで設定してから、IOKit のシリアルの口 (IOSSIOSPEED) で速さだけ渡す
            cfsetspeed(&options, speed_t(B9600))
            guard tcsetattr(descriptor, TCSANOW, &options) == 0 else {
                return .failed(call: "tcsetattr", code: errno)
            }
            var speed = speed_t(baudRate)
            guard withUnsafeMutablePointer(to: &speed, { ioctl(descriptor, setSpeed, $0) }) == 0 else {
                return .rejectedRate(code: errno)
            }
        }
        tcflush(descriptor, TCIFLUSH)
        return nil
    }

    /// `TIOCEXCL` (`_IO('t', 13)`)。関数の形のマクロは Swift に来ないので、値で書く。
    static let exclusive: UInt = 0x2000_740D
    /// `IOSSIOSPEED` (`_IOW('T', 2, speed_t)`。`IOKit/serial/ioss.h`)。
    static let setSpeed: UInt = 0x8008_5402
}

/// シリアルポートを 1 つ開いて、届いた行を渡す。
///
/// **開けなくても投げない。** 繋がっていない・使用中・失敗したときは理由ごとに 1 度だけ知らせ、
/// ``retryAfter`` 秒ごとに開き直す。抜かれた (読み取りが終わった・転んだ) ら ``SourceState/disconnected``
/// を名乗って開き直し続け、挿し直されて開けたら受け始める ([ADR-0028] 決定 3 の、起動後の抜き差しへの
/// 追随)。他のアプリがポートを手放したことには OS の知らせが無いので、開き直しは抜き差しの知らせ
/// (IOKit) を受けても要る。1 つの仕組みで両方を覆う。
///
/// 手続きはすべて ``queue`` の上で走る。
///
/// [ADR-0028]: https://github.com/mokume-metal/mokume/blob/main/docs/decisions/0028-external-inputs.md
nonisolated final class SerialReader: @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態 (``reading``・``lines``・``hasRun``・``stopped``・``told``) は
    // ``queue`` の上でだけ触る。

    /// 1 行のバイト数の上限。TCP の行と同じ。
    static let lineLimit = 65536
    /// 1 回に読むバイト数。読めるものが無くなるまで繰り返す。
    static let chunk = 4096

    let path: String
    let baudRate: Int
    let retryAfter: TimeInterval
    private let opener: SerialDevice.Opener
    private let received: @Sendable (_ texts: [String], _ unreadable: Int, _ hostTime: UInt64) -> Void
    private let changed: @Sendable (SourceState) -> Void
    private let warn: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "org.mokume.network.serial")
    /// 開いたポートの読み取りの知らせ。開いていなければ `nil`。
    private var reading: DispatchSourceRead?
    /// 行の途中で切れた残り。開くたびに作り直す。
    private var lines = LineSplitter(limit: SerialReader.lineLimit)
    /// 1 度でも開けたか。開けた後に開けなくなったら、抜かれたと名乗る。
    private var hasRun = false
    private var stopped = false
    /// 知らせた開けない理由。同じものは 2 度言わない。開けたら、また言えるように戻る。
    private var told: Set<String> = []
    /// 開いている番号を閉じ終えたか (読み取りの知らせを畳むと閉じる)。
    private let closing = DispatchGroup()

    /// - Parameters:
    ///   - path: ポートの経路。
    ///   - baudRate: ボーレート。
    ///   - retryAfter: 開けなかった・抜かれたとき、何秒後に開き直すか。
    ///   - opener: 開く手。
    ///   - received: 届いた行・読めずに捨てた数・届いた瞬間の host time。``queue`` の上で呼ばれる。
    ///   - changed: 状態の移り変わり。``queue`` の上で呼ばれる。
    ///   - warn: 診断の行き先。
    init(
        path: String, baudRate: Int, retryAfter: TimeInterval, opener: @escaping SerialDevice.Opener,
        received: @escaping @Sendable (_ texts: [String], _ unreadable: Int, _ hostTime: UInt64) -> Void,
        changed: @escaping @Sendable (SourceState) -> Void,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.path = path
        self.baudRate = baudRate
        self.retryAfter = retryAfter
        self.opener = opener
        self.received = received
        self.changed = changed
        self.warn = warn
    }

    /// 止めずに手放されたときも、開いている番号を閉じる (知らせを畳めば閉じる)。
    deinit {
        reading?.cancel()
    }

    /// 開き始める。待たずに返る。
    func start() {
        queue.async { [self] in attempt() }
    }

    /// 閉じる。**閉じ終わるまで待つ** — 返った後に届いたものは渡さず、ポートも空いている。
    func stop() {
        queue.sync { [self] in
            stopped = true
            reading?.cancel()
            reading = nil
        }
        _ = closing.wait(timeout: .now() + 1)
    }

    // MARK: - 待ち行列の上

    private func attempt() {
        guard !stopped, reading == nil else { return }
        switch opener(path, baudRate) {
        case .success(let descriptor):
            begin(descriptor)
        case .failure(let failure):
            changed(hasRun ? .disconnected : .unavailable)
            if told.insert(failure.key).inserted {
                warn(failure.message(path: path, baudRate: baudRate, retryAfter: retryAfter))
            }
            if failure.retries { retryLater() }
        }
    }

    private func retryLater() {
        queue.asyncAfter(deadline: .now() + retryAfter) { [weak self] in self?.attempt() }
    }

    private func begin(_ descriptor: Int32) {
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        closing.enter()
        source.setEventHandler { [weak self] in self?.drain(descriptor) }
        // 番号は知らせを畳み終えてから閉じる。先に閉じると、同じ番号を別のものが使い始めうる
        source.setCancelHandler { [closing] in
            Darwin.close(descriptor)
            closing.leave()
        }
        reading = source
        lines = LineSplitter(limit: Self.lineLimit)
        hasRun = true
        told.removeAll()
        changed(.running)
        source.resume()
    }

    /// 読めるものが無くなるまで読む。終わり (0) か転んだら、抜かれたとみなす。
    private func drain(_ descriptor: Int32) {
        guard !stopped, reading != nil else { return }
        var buffer = [UInt8](repeating: 0, count: Self.chunk)
        while true {
            let count = read(descriptor, &buffer, buffer.count)
            if count > 0 {
                deliver(buffer[..<count])
                continue
            }
            let code = errno
            if count < 0, code == EINTR { continue }
            if count < 0, code == EAGAIN { return }
            lost()
            return
        }
    }

    private func deliver(_ bytes: ArraySlice<UInt8>) {
        let hostTime = mach_absolute_time()
        let cut = lines.append(bytes)
        guard !cut.lines.isEmpty || cut.overlong > 0 else { return }
        let read = TextDecoding.lines(cut.lines, overlong: cut.overlong)
        received(read.texts, read.unreadable, hostTime)
    }

    /// 抜かれた。**行の途中で切れた残りは渡さず、読めなかった数に入れる** — TCP は相手が閉じたら
    /// 残りを 1 行として渡すが、シリアルの残りは途中で切れた値で、`"51"` のように黙って別の数として
    /// 読める。
    private func lost() {
        reading?.cancel()
        reading = nil
        if lines.finish() != nil { received([], 1, mach_absolute_time()) }
        changed(.disconnected)
        retryLater()
    }
}

/// シリアルポートから行を受ける出どころ。届いた行を落とさない列へ入れる。
nonisolated final class SerialSource: MessageSource, @unchecked Sendable {
    // `@unchecked Sendable`: 可変の状態は ``reader`` だけで、main actor (start / stop) でだけ触る。
    // 読む層の手続きが触るのは列 (それ自身が錠を持つ) だけ。

    let path: String
    let baudRate: Int
    let retryAfter: TimeInterval
    private let opener: SerialDevice.Opener
    private let warn: @Sendable (String) -> Void
    private var reader: SerialReader?

    /// 開けなかった・抜かれたとき、何秒後に開き直すか (既定)。
    static var defaultRetry: TimeInterval { 1 }

    init(
        path: String, baudRate: Int, retryAfter: TimeInterval = defaultRetry,
        opener: @escaping SerialDevice.Opener = SerialDevice.open,
        warn: @escaping @Sendable (String) -> Void
    ) {
        self.path = path
        self.baudRate = baudRate
        self.retryAfter = retryAfter
        self.opener = opener
        self.warn = warn
    }

    func start(into queue: ExternalQueue<String>) {
        queue.setState(.unavailable)
        let reader = SerialReader(
            path: path, baudRate: baudRate, retryAfter: retryAfter, opener: opener,
            received: { texts, unreadable, hostTime in
                for text in texts { queue.send(text, hostTime: hostTime) }
                queue.discardUnreadable(unreadable)
            },
            changed: { state in queue.setState(state) },
            warn: warn)
        self.reader = reader
        reader.start()
    }

    func pump(into queue: ExternalQueue<String>) {}

    func stop() {
        reader?.stop()
        reader = nil
    }
}
