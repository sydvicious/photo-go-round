// Pictures from the agent. `Wallpaper Plan.md`, *The fourth probe: pictures from
// the agent*.
//
// Its own small port read and request rather than `PhotoGoRoundDisplay`'s: the
// probe is built with swiftc from its own sources. The port is read both ways for
// both domains, and each read is logged on its own, so the two come apart the way
// the saver's did in `legacyScreenSaver`.

import ColorSync
import CoreGraphics
import Foundation
import ImageIO

enum AgentPicture {
    static let consumer = "system-wallpaper"
    static let domains = ["com.sydpolk.photogoround.dev", "com.sydpolk.photogoround"]

    struct Found: Sendable {
        let port: UInt16
        let domain: String
        let read: String
    }

    enum Reading {
        case port(UInt16)
        case nothing(String)
        case refused(String)

        var description: String {
            switch self {
            case .port(let port): "servicePort \(port)"
            case .nothing(let why): "no port: \(why)"
            case .refused(let why): "unreadable: \(why)"
            }
        }
    }

    /// Every port found, each domain's suite first and then its plist, without
    /// repeating a port already found.
    static func ports() -> [Found] {
        var found: [Found] = []
        for domain in domains {
            for (read, reading) in [("suite", suitePort(domain)), ("plist", filePort(domain))] {
                probe("agent: \(domain) \(read): \(reading.description)")
                if case .port(let port) = reading, !found.contains(where: { $0.port == port }) {
                    found.append(Found(port: port, domain: domain, read: read))
                }
            }
        }
        return found
    }

    /// Through `cfprefsd`. In `legacyScreenSaver`'s sandbox this came back as a
    /// suite that opened and held nothing, rather than a refusal.
    static func suitePort(_ domain: String) -> Reading {
        guard let defaults = UserDefaults(suiteName: domain) else { return .refused("the suite did not open") }
        guard let value = defaults.object(forKey: "servicePort") else {
            return .nothing("the suite opened with no servicePort in it")
        }
        guard let number = value as? Int, number > 0, number <= Int(UInt16.max) else {
            return .refused("servicePort is \(type(of: value)) \(value)")
        }
        return .port(UInt16(number))
    }

    /// The plist read as a file, from the real home: `NSHomeDirectory()` is the
    /// container inside a sandbox. No `fileExists` first, since a sandbox denial
    /// makes a present file look absent; the read's own error says which it was.
    static func filePort(_ domain: String) -> Reading {
        let url = URL(filePath: realHome()).appending(path: "Library/Preferences/\(domain).plist")
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            let cocoa = error as NSError
            let posix = (cocoa.userInfo[NSUnderlyingErrorKey] as? NSError).map { " (\($0.domain) \($0.code))" } ?? ""
            return .refused("\(url.path(percentEncoded: false)): Cocoa \(cocoa.code)\(posix)")
        }
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            return .refused("\(data.count) bytes that would not parse")
        }
        guard let value = plist["servicePort"] else { return .nothing("\(data.count) bytes with no servicePort") }
        guard let number = value as? Int, number > 0, number <= Int(UInt16.max) else {
            return .refused("servicePort is \(type(of: value)) \(value)")
        }
        return .port(UInt16(number))
    }

    static func realHome() -> String {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return NSHomeDirectory() }
        return String(cString: directory)
    }

    /// The display's UUID as the app's wallpaper and the saver spell it.
    static func displayUUID(_ display: UInt32?) -> String? {
        guard let display, let uuid = CGDisplayCreateUUIDFromDisplayID(display)?.takeRetainedValue() else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }

    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    /// Asks each port in turn until one answers. A transport failure moves to the
    /// next port; any HTTP answer is final, since it came from an agent.
    static func fetch(display: UInt32?, pixels: CGSize, done: @escaping @Sendable (CGImage?) -> Void) {
        let found = ports()
        guard !found.isEmpty else {
            probe("agent: no port found in any domain, so nothing asked")
            done(nil)
            return
        }
        let uuid = displayUUID(display)
        if uuid == nil { probe("agent: no UUID for display \(display.map { String($0) } ?? "unknown"); asking without one") }
        ask(found, at: 0, uuid: uuid, pixels: pixels, done: done)
    }

    private static func ask(
        _ found: [Found], at index: Int, uuid: String?, pixels: CGSize, done: @escaping @Sendable (CGImage?) -> Void
    ) {
        guard index < found.count else {
            probe("agent: every port found was unreachable")
            done(nil)
            return
        }
        let target = found[index]
        var components = URLComponents()
        components.scheme = "http"
        components.host = "localhost"
        components.port = Int(target.port)
        components.path = "/v1/next"
        let width = max(Int(pixels.width), 1)
        let height = max(Int(pixels.height), 1)
        var query = [URLQueryItem(name: "consumer", value: consumer)]
        if let uuid { query.append(URLQueryItem(name: "display", value: uuid)) }
        query.append(URLQueryItem(name: "w", value: String(width)))
        query.append(URLQueryItem(name: "h", value: String(height)))
        components.queryItems = query
        guard let url = components.url else {
            probe("agent: no URL could be made for port \(target.port)")
            done(nil)
            return
        }
        probe("agent: asking \(url.absoluteString), port from the \(target.domain) \(target.read)")
        let started = ContinuousClock.now
        session.dataTask(with: url) { data, response, error in
            let elapsed = started.duration(to: .now)
            let milliseconds = elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000
            if let error {
                probe("agent: port \(target.port) unreachable after \(milliseconds) ms: \(error.localizedDescription)")
                ask(found, at: index + 1, uuid: uuid, pixels: pixels, done: done)
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            let bytes = data?.count ?? 0
            probe("agent: port \(target.port) answered \(status), \(bytes) bytes, \(milliseconds) ms")
            guard status == 200, let data else {
                done(nil)
                return
            }
            done(decode(data, longestSide: max(width, height)))
        }.resume()
    }

    /// Decoded at no more than the desktop's longest side, with the file's
    /// orientation applied.
    static func decode(_ data: Data, longestSide: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            probe("agent: the picture would not open as an image")
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: longestSide,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            probe("agent: the picture would not decode")
            return nil
        }
        probe("agent: decoded \(image.width)x\(image.height)")
        return image
    }
}
