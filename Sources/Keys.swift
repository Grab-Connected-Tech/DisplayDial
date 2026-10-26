// DisplayDial by Grab Connected Tech, https://www.grabians.com

import SwiftUI
import CoreAudio

// The keyboard's brightness, volume and mute keys, sent to external monitors over DDC. The event tap only
// asks for system-defined events (media keys), never key-downs, so it can't see typing. Any key DisplayDial
// can't act on reliably goes to macOS untouched.
@Observable
final class Keys {
    var enabled = UserDefaults.standard.bool(forKey: "keys.enabled") {
        didSet { UserDefaults.standard.set(enabled, forKey: "keys.enabled"); update() }
    }
    private(set) var trusted = AXIsProcessTrusted()
    var needsAccess: Bool { enabled && !trusted }

    @ObservationIgnored private let displays: Displays
    @ObservationIgnored private var tap: CFMachPort?
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var swallowed: Set<Int> = []
    @ObservationIgnored private var lastPress: [String: Date] = [:]
    @ObservationIgnored private var awaitingRead: [String: [() -> Void]] = [:]

    init(displays: Displays) {
        self.displays = displays
        UserDefaults.standard.register(defaults: ["keys.volume": true, "keys.osd": true])
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.restart()
        }
        update()
    }

    func requestAccess() {
        AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func update() {
        trusted = AXIsProcessTrusted()
        if enabled, trusted, tap == nil { start() }
        if !(enabled && trusted), let tap { CFMachPortInvalidate(tap); self.tap = nil }
        // Nothing announces a grant or revoke in System Settings, so poll while the feature is on.
        if enabled, timer == nil {
            timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                guard let self, AXIsProcessTrusted() != trusted else { return }
                restart()
            }
            timer?.tolerance = 0.3
        } else if !enabled {
            timer?.invalidate(); timer = nil
        }
    }

    private func restart() {
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        update()
    }

    private func start() {
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                eventsOfInterest: CGEventMask(1 << NSEvent.EventType.systemDefined.rawValue),
                                callback: { _, type, event, me in Unmanaged<Keys>.fromOpaque(me!).takeUnretainedValue().handle(type, event) },
                                userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        // Panel-only users never pay for these reads; key users need each monitor's capabilities up front.
        displays.monitors.filter { $0.responded == nil }.forEach { $0.refresh() }
    }

    // Runs on the main thread for every media key press, so it decides quickly and leaves DDC to the monitor's queue.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let pass = Unmanaged.passUnretained(event)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return pass
        }
        // NX_SUBTYPE_AUX_CONTROL_BUTTONS: data1 is key << 16 | state << 8 | repeat.
        guard let ns = NSEvent(cgEvent: event), ns.subtype.rawValue == 8 else { return pass }
        let key = (ns.data1 & 0xFFFF_0000) >> 16, down = (ns.data1 & 0xFF00) >> 8 == 0x0A, isRepeat = ns.data1 & 1 == 1
        if !down { return swallowed.remove(key) != nil ? nil : pass }
        if key == 7, isRepeat { return swallowed.contains(key) ? nil : pass }
        let fine = ns.modifierFlags.isSuperset(of: [.shift, .option])
        let handled = switch key {
        case 2, 3: brightness(up: key == 2, fine: fine) // NX_KEYTYPE_BRIGHTNESS_UP, _DOWN
        case 0, 1, 7: volume(key, fine: fine)            // NX_KEYTYPE_SOUND_UP, _DOWN, NX_KEYTYPE_MUTE
        default: false
        }
        if handled { swallowed.insert(key) } else { swallowed.remove(key) }
        return handled ? nil : pass
    }

    private func controllable(_ m: Monitor) -> Bool {
        m.responded == true && m.ddc.map { !$0.unreliable } == true
    }

    private func display(at point: CGPoint) -> CGDirectDisplayID? {
        var id = CGDirectDisplayID(), count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 1, &id, &count)
        return count == 1 ? id : nil
    }

    private var pointer: CGPoint { CGEvent(source: nil)?.location ?? .zero }

    // Window bounds (not titles) are readable without Screen Recording access.
    private var frontWindowCenter: CGPoint? {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        guard let window = windows.first(where: { $0[kCGWindowOwnerPID as String] as? pid_t == pid && $0[kCGWindowLayer as String] as? Int == 0 }),
              let dictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: dictionary as CFDictionary) else { return nil }
        return CGPoint(x: bounds.midX, y: bounds.midY)
    }

    private func brightness(up: Bool, fine: Bool) -> Bool {
        switch UserDefaults.standard.string(forKey: "keys.brightness") {
        case "all":
            // macOS still gets the key, so the built-in display changes too.
            displays.monitors.filter(controllable).forEach { change($0, .brightness, up: up, fine: fine) }
            return false
        case let mode:
            let point = mode == "window" ? frontWindowCenter ?? pointer : pointer
            guard let id = display(at: point), let m = displays.monitors.first(where: { $0.id == id }), controllable(m) else { return false }
            change(m, .brightness, up: up, fine: fine)
            return true
        }
    }

    private func volume(_ key: Int, fine: Bool) -> Bool {
        guard UserDefaults.standard.bool(forKey: "keys.volume"), let m = speakers, m.supports(.volume) else { return false }
        if key == 7 {
            whenFresh(m, .volume) { [self] in m.toggleMute(); indicate(m, .volume) }
        } else {
            change(m, .volume, up: key == 0, fine: fine)
        }
        return true
    }

    // Monitors that could be the current sound output. macOS names a monitor's audio device after the model, and
    // its UID is the EDID header, whose serial field is often zero, so two identical monitors can look the same.
    var speakerCandidates: [Monitor] {
        let output = audioProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0)) ?? 0
        let transport = audioProperty(output, kAudioDevicePropertyTransportType, UInt32(0))
        guard transport == kAudioDeviceTransportTypeDisplayPort || transport == kAudioDeviceTransportTypeHDMI else { return [] }
        let name = audioProperty(output, kAudioObjectPropertyName, Unmanaged<CFString>?.none)??.takeRetainedValue() as String?
        let usable = displays.monitors.filter(controllable)
        let named = usable.filter { screen($0.id)?.localizedName == name }
        return named.isEmpty && usable.count == 1 ? usable : named
    }

    private var speakers: Monitor? {
        let candidates = speakerCandidates
        guard candidates.count > 1 else { return candidates.first }
        let chosen = UserDefaults.standard.string(forKey: "keys.speakers")
        let underPointer = display(at: pointer)
        return candidates.first { $0.key == chosen } ?? candidates.first { $0.id == underPointer } ?? candidates.first
    }

    private func change(_ m: Monitor, _ code: VCP, up: Bool, fine: Bool) {
        // Most monitors lock brightness in HDR; writing would do nothing, so just say so.
        if code == .brightness, HDR.enabled(m.id) ?? m.hdr { indicate(m, code, locked: true); return }
        whenFresh(m, code) { [self] in
            let value = m.values[code] ?? 0
            // Volume 0 is mute: down stays there, up starts from the level before muting.
            if code == .volume, value == 0, !up { indicate(m, code); return }
            let next = DDC.step(code == .volume && value == 0 ? m.volumeBeforeMute : value,
                                max: m.maxes[code] ?? 100, steps: fine ? 64 : 16, up: up)
            if code == .volume, next == 0 { m.volumeBeforeMute = 0 }
            m.set(code, next)
            indicate(m, code)
        }
    }

    // After 3 s without a key press, read the monitor first, so changes made with its own buttons aren't overwritten.
    // The read runs off the main thread; presses that arrive meanwhile queue behind it.
    private func whenFresh(_ m: Monitor, _ code: VCP, _ action: @escaping () -> Void) {
        let key = "\(m.key).\(code.rawValue)"
        defer { lastPress[key] = .now }
        if awaitingRead[key] != nil { awaitingRead[key]?.append(action); return }
        if m.values[code] != nil, let last = lastPress[key], last.timeIntervalSinceNow > -3 { action(); return }
        guard let ddc = m.ddc else { return }
        awaitingRead[key] = [action]
        Task.detached { [self] in
            let read = ddc.read(code)
            await MainActor.run { [self] in
                if let read { m.values[code] = read.current; m.maxes[code] = read.max }
                let actions = self.awaitingRead.removeValue(forKey: key) ?? []
                if m.values[code] != nil { actions.forEach { $0() } }
            }
        }
    }

    private func indicate(_ m: Monitor, _ code: VCP, locked: Bool = false) {
        guard UserDefaults.standard.bool(forKey: "keys.osd") else { return }
        let fraction = Double(m.values[code] ?? 0) / Double(max(m.maxes[code] ?? 100, 1))
        OSD.show(code == .brightness ? .brightness : fraction == 0 ? .muted : .volume, fraction, locked: locked, on: m.id)
    }
}

private func audioProperty<T: BitwiseCopyable>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, _ initial: T) -> T? {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    var value = initial, size = UInt32(MemoryLayout<T>.size)
    return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
}

// macOS's own indicator where it behaves, otherwise a look-alike. Chosen once per launch so the look never flips.
enum OSD {
    enum Kind { case brightness, volume, muted }

    // OSD.framework is private, so it's looked up at runtime like the SkyLight HDR calls. macOS 26 moved the
    // indicator to the top right, and OSDManager misbehaves there when other apps call it.
    private typealias ShowFn = @convention(c) (AnyObject, Selector, Int32, UInt32, Int32, UInt32, UInt32, UInt32, Bool) -> Void
    private static let selector = NSSelectorFromString("showImage:onDisplayID:priority:msecUntilFade:filledChiclets:totalChiclets:locked:")
    private static let native: (manager: NSObject, show: ShowFn)? = {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 26,
              dlopen("/System/Library/PrivateFrameworks/OSD.framework/OSD", RTLD_LAZY) != nil,
              let cls = NSClassFromString("OSDManager") as AnyObject?,
              cls.responds(to: NSSelectorFromString("sharedManager")),
              let manager = cls.perform(NSSelectorFromString("sharedManager"))?.takeUnretainedValue() as? NSObject,
              manager.responds(to: selector) else { return nil }
        return (manager, unsafeBitCast(manager.method(for: selector), to: ShowFn.self))
    }()

    private static var panels: [CGDirectDisplayID: NSPanel] = [:]
    private static var fades: [CGDirectDisplayID: DispatchWorkItem] = [:]

    static func show(_ kind: Kind, _ fraction: Double, locked: Bool, on id: CGDirectDisplayID) {
        if let native {
            // OSDGraphicBacklight = 1, Speaker = 3, SpeakerMuted = 4; 0x1F4 is the default priority.
            let image: Int32 = kind == .brightness ? 1 : kind == .volume ? 3 : 4
            native.show(native.manager, selector, image, id, 0x1F4, 1500, UInt32((fraction * 64).rounded()), 64, locked)
            return
        }
        guard let screen = screen(id) else { return }
        let panel = panels[id] ?? {
            let panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.level = .statusBar
            panel.ignoresMouseEvents = true
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let blur = NSVisualEffectView()
            blur.material = .hudWindow
            blur.state = .active
            blur.wantsLayer = true
            blur.layer?.cornerRadius = 18
            blur.layer?.masksToBounds = true
            panel.contentView = blur
            panels[id] = panel
            return panel
        }()
        let host = NSHostingView(rootView: Indicator(kind: kind, fraction: fraction, locked: locked))
        let size = host.fittingSize, frame = screen.visibleFrame
        host.frame.size = size
        panel.contentView?.subviews = [host]
        panel.setFrame(NSRect(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        fades[id]?.cancel()
        let fade = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup { $0.duration = 0.3; panel.animator().alphaValue = 0 }
        }
        fades[id] = fade
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: fade)
    }
}

private struct Indicator: View {
    let kind: OSD.Kind
    let fraction: Double
    let locked: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Image(systemName: kind == .brightness ? "sun.max.fill" : kind == .muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 15))
                    .frame(width: 22)
                HStack(spacing: 2) {
                    ForEach(0..<16, id: \.self) { i in
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.primary.opacity(i < Int((fraction * 16).rounded()) ? 0.9 : 0.15))
                            .frame(width: 8, height: 6)
                    }
                }
                if locked { Image(systemName: "lock.fill").font(.system(size: 11)) }
            }
            if locked {
                Text("Brightness is locked while HDR is on").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(locked ? "Brightness is locked while HDR is on" : "\(kind == .brightness ? "Brightness" : "Volume") \(Int(fraction * 100))%")
    }
}
