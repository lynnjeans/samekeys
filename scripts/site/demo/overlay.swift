// Puts keycaps on the demo video (SK-294): reads a screen recording and the
// key log keylog.swift wrote while it was made, and shows each shortcut as
// keycaps at the bottom center, one at a time.
//
//   swift scripts/site/demo/overlay.swift <recording.mov> <keys.jsonl> <out> [options]
//
// Writes <out>.mp4 (H.264, at most 1920 wide, for the site) and <out>.gif
// (under 5 MB if it can, for the README). Needs ffmpeg, ffprobe and gifski.
//
//   --shift <s>     move the keycaps later (or earlier, if negative) by s seconds
//   --start <t>     the recording's first frame in seconds since 1970; by
//                   default its creation time, which QuickTime keeps to the second
//   --lang zh-Hans  Chinese names for mouse buttons and the wheel
//   --dry-run       list the keycaps with their times, and write nothing
//
// Only shortcuts appear: combos with Ctrl, Win, Alt or fn, function and
// navigation keys, the right, middle and side buttons, and scrolling with a
// modifier held. Plain typing and left clicks never do.

import AppKit

// MARK: Arguments

var positional: [String] = []
var shift = 0.0
var startOverride: Double?
var lang = "en"
var dryRun = false
var arguments = CommandLine.arguments.dropFirst().makeIterator()
while let argument = arguments.next() {
    switch argument {
    case "--shift": shift = Double(arguments.next() ?? "") ?? 0
    case "--start": startOverride = Double(arguments.next() ?? "")
    case "--lang": lang = arguments.next() ?? "en"
    case "--dry-run": dryRun = true
    default: positional.append(argument)
    }
}
guard positional.count == 3 else {
    FileHandle.standardError.write("usage: overlay.swift <recording.mov> <keys.jsonl> <out> [--shift s] [--start t] [--lang zh-Hans] [--dry-run]\n".data(using: .utf8)!)
    exit(2)
}
let (recording, keyLog, out) = (positional[0], positional[1], positional[2])

func fail(_ message: String) -> Never {
    FileHandle.standardError.write("overlay: \(message)\n".data(using: .utf8)!)
    exit(1)
}

@discardableResult
func run(_ tool: String, _ args: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = [tool] + args
    let pipe = Pipe()
    process.standardOutput = pipe
    do { try process.run() } catch { fail("cannot run \(tool): \(error)") }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { fail("\(tool) failed (\(process.terminationStatus))") }
    return String(decoding: data, as: UTF8.self)
}

// MARK: The recording

struct Probe: Decodable {
    struct Stream: Decodable { let width: Int?; let height: Int? }
    struct Format: Decodable { let duration: String?; let tags: [String: String]? }
    let streams: [Stream]
    let format: Format
}
let probe = try! JSONDecoder().decode(Probe.self, from: Data(run("ffprobe", [
    "-v", "error", "-select_streams", "v:0", "-show_entries", "stream=width,height:format=duration:format_tags",
    "-of", "json", recording,
]).utf8))
guard let sourceWidth = probe.streams.first?.width, let sourceHeight = probe.streams.first?.height,
      let duration = Double(probe.format.duration ?? "") else { fail("\(recording) has no video") }

/// QuickTime writes com.apple.quicktime.creationdate ("2026-10-08T09:12:33+1300");
/// other tools write creation_time in UTC.
func creationTime() -> Double? {
    let tags = probe.format.tags ?? [:]
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    for (tag, format) in [("com.apple.quicktime.creationdate", "yyyy-MM-dd'T'HH:mm:ssZ"),
                          ("creation_time", "yyyy-MM-dd'T'HH:mm:ss.SSSSSSZ"),
                          ("creation_time", "yyyy-MM-dd'T'HH:mm:ssZ")] {
        formatter.dateFormat = format
        if let value = tags[tag], let date = formatter.date(from: value) { return date.timeIntervalSince1970 }
    }
    return nil
}
guard let start = startOverride ?? creationTime() else { fail("\(recording) has no creation time; pass --start") }

// Even sizes, as H.264 needs.
let width = min(1920, sourceWidth) / 2 * 2
let height = Int((Double(sourceHeight) * Double(width) / Double(sourceWidth)) / 2) * 2

// MARK: Key log → keycaps

struct Event: Decodable { let t: Double; let kind: String; let name: String; let down: Bool? }
guard let log = try? String(contentsOfFile: keyLog, encoding: .utf8) else { fail("cannot read \(keyLog)") }
let events = log.split(separator: "\n")
    .compactMap { try? JSONDecoder().decode(Event.self, from: Data($0.utf8)) }
    .sorted { $0.t < $1.t }

let modifierNames = [
    "Left Control": "Ctrl", "Right Control": "Ctrl", "Left GUI": "Win", "Right GUI": "Win",
    "Left Alt": "Alt", "Right Alt": "Alt", "Left Shift": "Shift", "Right Shift": "Shift", "fn": "fn",
]
let modifierOrder = ["fn", "Win", "Ctrl", "Shift", "Alt"]
/// Keys worth showing on their own, without a modifier.
let navigationKeys = Set([
    "Esc", "Tab", "Enter", "Backspace", "Delete", "Insert", "Home", "End", "Page Up", "Page Down",
    "Left", "Right", "Up", "Down", "Print Screen", "Menu",
] + (1...12).map { "F\($0)" })
let keyLabels = ["Left": "←", "Right": "→", "Up": "↑", "Down": "↓", "Page Up": "PgUp", "Page Down": "PgDn"]
let mouseLabels: [String: [String: String]] = [
    "en": ["2": "Right click", "3": "Middle click", "4": "Back button", "5": "Forward button", "wheel": "Scroll"],
    "zh-Hans": ["2": "右键", "3": "中键", "4": "后退键", "5": "前进键", "wheel": "滚轮"],
]
guard let mouse = mouseLabels[lang] else { fail("--lang is en or zh-Hans") }

struct Keycaps { var keys: [String]; var start: Double; var end: Double; var count = 1 }
/// How long a keycap stays at least, and after its key is let go.
let minimumShow = 0.9, afterRelease = 0.35
/// Scroll steps closer than this belong to one scroll.
let scrollGap = 0.4

var items: [Keycaps] = []
var held: [String: String] = [:]      // raw modifier name → label
var openKeys: [String: Int] = [:]     // a key still down → its item
var lastScroll = -Double.infinity

func combo(_ label: String) -> [String] {
    Set(held.values).sorted { modifierOrder.firstIndex(of: $0)! < modifierOrder.firstIndex(of: $1)! } + [label]
}
func show(_ keys: [String], at time: Double) -> Int {
    if var last = items.last, last.keys == keys, time < last.end {
        last.count += 1
        last.end = max(last.end, time + minimumShow)
        items[items.count - 1] = last
    } else {
        items.append(Keycaps(keys: keys, start: time, end: time + minimumShow))
    }
    return items.count - 1
}

for event in events {
    let modifiers = Set(held.values)
    let hasCommandModifier = !modifiers.subtracting(["Shift"]).isEmpty
    switch event.kind {
    case "key":
        if let label = modifierNames[event.name] {
            if event.down == true { held[event.name] = label } else { held[event.name] = nil }
        } else if event.down == true {
            guard hasCommandModifier || navigationKeys.contains(event.name) else { continue }
            openKeys[event.name] = show(combo(keyLabels[event.name] ?? event.name), at: event.t)
        } else if let index = openKeys.removeValue(forKey: event.name) {
            items[index].end = max(items[index].end, event.t + afterRelease)
        }
    case "button":
        guard let label = mouse[event.name] else { continue }
        let key = "button \(event.name)"
        if event.down == true {
            openKeys[key] = show(combo(label), at: event.t)
        } else if let index = openKeys.removeValue(forKey: key) {
            items[index].end = max(items[index].end, event.t + afterRelease)
        }
    case "wheel":
        guard hasCommandModifier else { continue }
        let keys = combo(mouse["wheel"]!)
        if let last = items.last, last.keys == keys, event.t - lastScroll < scrollGap {
            items[items.count - 1].end = max(last.end, event.t + afterRelease)
        } else {
            _ = show(keys, at: event.t)
            items[items.count - 1].count = 1
        }
        lastScroll = event.t
    default:
        continue
    }
}

// One at a time: a keycap leaves when the next one comes. Then the recording's clock.
for index in items.indices.dropLast() {
    items[index].end = min(items[index].end, items[index + 1].start)
}
let timed = items.compactMap { item -> Keycaps? in
    var item = item
    item.start = item.start - start + shift
    item.end = min(item.end - start + shift, duration)
    return item.end > max(item.start, 0) ? item : nil
}

func text(_ item: Keycaps) -> String {
    item.keys.joined(separator: " + ") + (item.count > 1 ? " ×\(item.count)" : "")
}
print("\(timed.count) keycaps on a \(String(format: "%.1f", duration)) s recording, \(width)×\(height):")
for item in timed {
    print(String(format: "  %6.2f–%6.2f  ", item.start, item.end) + text(item))
}
if dryRun { exit(0) }
guard !timed.isEmpty else { fail("no shortcuts fall inside the recording; check --start and --shift") }

// MARK: Keycap images

/// Keycaps as on the website (site.css kbd), on a dark panel so they read on
/// any window.
func render(_ item: Keycaps, keyHeight k: CGFloat) -> Data {
    let font = NSFont.systemFont(ofSize: k * 0.46, weight: .medium)
    let small = NSFont.systemFont(ofSize: k * 0.4, weight: .medium)
    let keyText: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor(white: 0.114, alpha: 1)]
    let lightText: [NSAttributedString.Key: Any] = [.font: small, .foregroundColor: NSColor(white: 1, alpha: 0.8)]
    let padX = k * 0.42, gap = k * 0.22, panelPadX = k * 0.4, panelPadY = k * 0.3, drop = k * 0.06

    var parts: [(String, isKey: Bool, width: CGFloat)] = []
    for (index, key) in item.keys.enumerated() {
        if index > 0 { parts.append(("+", false, ("+" as NSString).size(withAttributes: lightText).width)) }
        parts.append((key, true, max(k * 0.95, (key as NSString).size(withAttributes: keyText).width + 2 * padX)))
    }
    if item.count > 1 {
        let label = "×\(item.count)"
        parts.append((label, false, (label as NSString).size(withAttributes: lightText).width))
    }
    let contentWidth = parts.map(\.width).reduce(0, +) + gap * CGFloat(parts.count - 1)
    let size = NSSize(width: ceil(contentWidth + 2 * panelPadX), height: ceil(k + drop + 2 * panelPadY))

    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(white: 0, alpha: 0.6).setFill()
    NSBezierPath(roundedRect: NSRect(origin: .zero, size: size), xRadius: k * 0.4, yRadius: k * 0.4).fill()

    // AppKit's y runs up: the key sits above its drop shadow.
    let keyY = panelPadY + drop
    var x = panelPadX
    for part in parts {
        if part.isKey {
            let key = NSRect(x: x, y: keyY, width: part.width, height: k)
            let radius = k * 0.17
            NSColor(srgbRed: 0xb8 / 255, green: 0xb8 / 255, blue: 0xbf / 255, alpha: 1).setFill()
            NSBezierPath(roundedRect: key.offsetBy(dx: 0, dy: -drop), xRadius: radius, yRadius: radius).fill()
            let face = NSBezierPath(roundedRect: key, xRadius: radius, yRadius: radius)
            NSColor.white.setFill()
            face.fill()
            NSColor(srgbRed: 0xc7 / 255, green: 0xc7 / 255, blue: 0xcc / 255, alpha: 1).setStroke()
            face.lineWidth = max(1, k * 0.025)
            face.stroke()
            let label = part.0 as NSString
            let textSize = label.size(withAttributes: keyText)
            label.draw(at: NSPoint(x: key.midX - textSize.width / 2, y: key.midY - textSize.height / 2), withAttributes: keyText)
        } else {
            let label = part.0 as NSString
            let textSize = label.size(withAttributes: lightText)
            label.draw(at: NSPoint(x: x, y: keyY + k / 2 - textSize.height / 2), withAttributes: lightText)
        }
        x += part.width + gap
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let work = FileManager.default.temporaryDirectory.appendingPathComponent("samekeys-overlay-\(ProcessInfo.processInfo.processIdentifier)")
try! FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: work) }

let keyHeight = (CGFloat(height) * 0.055).rounded()
var inputs: [String] = ["-i", recording]
var filters = ["[0:v]fps=30,scale=\(width):\(height):flags=lanczos[v0]"]
let fade = 0.12
for (index, item) in timed.enumerated() {
    let image = work.appendingPathComponent("keycaps-\(index).png")
    try! render(item, keyHeight: keyHeight).write(to: image)
    let shown = max(item.start, 0)
    let length = item.end - shown
    inputs += ["-loop", "1", "-framerate", "30", "-t", String(format: "%.3f", length), "-i", image.path]
    filters.append(
        "[\(index + 1):v]format=rgba,fade=t=in:st=0:d=\(fade):alpha=1,"
            + "fade=t=out:st=\(String(format: "%.3f", max(0, length - fade))):d=\(fade):alpha=1,"
            + "setpts=PTS-STARTPTS+\(String(format: "%.3f", shown))/TB[k\(index)]")
    filters.append(
        "[v\(index)][k\(index)]overlay=x=(main_w-overlay_w)/2:y=main_h-overlay_h-\(Int(Double(height) * 0.06)):"
            + "eof_action=pass[v\(index + 1)]")
}
filters.append("[v\(timed.count)]format=yuv420p[out]")
let script = work.appendingPathComponent("filter.txt")
try! filters.joined(separator: ";\n").write(to: script, atomically: true, encoding: .utf8)

let mp4 = out + ".mp4"
run("ffmpeg", ["-y", "-v", "error"] + inputs + [
    "-/filter_complex", script.path, "-map", "[out]", "-an",
    "-c:v", "libx264", "-preset", "slow", "-crf", "20", "-movflags", "+faststart", mp4,
])

// MARK: GIF

let gif = out + ".gif"
let limit = 5_000_000
for (gifWidth, quality, fps) in [(960, 80, 12), (800, 70, 12), (720, 60, 10)] {
    let frames = work.appendingPathComponent("frames-\(gifWidth)")
    try! FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
    run("ffmpeg", ["-y", "-v", "error", "-i", mp4, "-vf", "fps=\(fps),scale=\(gifWidth):-2:flags=lanczos",
                   frames.appendingPathComponent("%05d.png").path])
    let files = try! FileManager.default.contentsOfDirectory(atPath: frames.path).sorted()
        .map { frames.appendingPathComponent($0).path }
    run("gifski", ["--quiet", "--fps", "\(fps)", "--quality", "\(quality)", "-o", gif] + files)
    let bytes = (try? FileManager.default.attributesOfItem(atPath: gif)[.size] as? Int) ?? 0
    print("\(gif): \(gifWidth) wide, quality \(quality), \(fps) fps, \(bytes / 1000) kB")
    if bytes <= limit { break }
}
let mp4Bytes = (try? FileManager.default.attributesOfItem(atPath: mp4)[.size] as? Int) ?? 0
print("\(mp4): \(mp4Bytes / 1000) kB")
