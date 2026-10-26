import SwiftUI
import ServiceManagement

@main
struct DisplayDialApp: App {
    @State private var displays = Displays()

    var body: some Scene {
        MenuBarExtra("DisplayDial", systemImage: "sun.max.fill") {
            Panel(displays: displays)
        }
        .menuBarExtraStyle(.window)
    }
}

struct Profile: Codable, Identifiable {
    var id = UUID()
    var name: String
    var values: [VCP: Int]
}

private func screen(_ id: CGDirectDisplayID) -> NSScreen? {
    NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == id }
}

@Observable
final class Displays {
    var monitors: [Monitor] = []
    var selectedID: CGDirectDisplayID?
    var selected: Monitor? { monitors.first { $0.id == selectedID } ?? monitors.first }

    // Rebuilt on every panel open and display change, so replugged monitors get fresh IOAVService
    // handles; a Monitor object (and its cached capabilities) survives while its display stays online.
    func rescan() {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16), count: UInt32 = 0
        CGGetOnlineDisplayList(UInt32(ids.count), &ids, &count)
        let external = ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
        let services = DDC.externalDisplays()

        var pairs: [(id: CGDirectDisplayID, service: Int, score: Int)] = []
        for id in external {
            for (i, s) in services.enumerated() {
                let score = DDC.matchScore(s.attributes, vendor: CGDisplayVendorNumber(id), model: CGDisplayModelNumber(id),
                                           serial: CGDisplaySerialNumber(id), name: screen(id)?.localizedName)
                if score > 0 { pairs.append((id, i, score)) }
            }
        }
        var match: [CGDirectDisplayID: Int] = [:]
        for p in pairs.sorted(by: { $0.score > $1.score }) where match[p.id] == nil && !match.values.contains(p.service) {
            match[p.id] = p.service
        }
        // A future registry layout without attributes still works for the common one-monitor case.
        let unmatched = external.filter { match[$0] == nil }, spare = services.indices.filter { !match.values.contains($0) }
        if unmatched.count == 1, spare.count == 1 { match[unmatched[0]] = spare[0] }

        let baseNames = external.map { id in
            screen(id)?.localizedName ?? match[id].flatMap { services[$0].attributes["ProductName"] as? String } ?? "Display"
        }
        monitors = zip(external, baseNames).enumerated().map { i, pair in
            let (id, base) = pair
            let shared = baseNames.filter { $0 == base }.count > 1
            let name = shared ? "\(base) (\(baseNames[...i].filter { $0 == base }.count))" : base
            let m = monitors.first { $0.id == id } ?? Monitor(id: id, legacyProfilesKey: shared ? nil : "profiles.\(base)")
            m.name = name
            m.ddc = match[id].map { services[$0].ddc }
            return m
        }
    }
}

@Observable
final class Monitor: Identifiable {
    let id: CGDirectDisplayID
    var name = ""
    var ddc: DDC?
    // nil while the first read is in flight; false when the monitor never answered over DDC.
    var responded: Bool?
    var values: [VCP: Int] = [:]
    var maxes: [VCP: Int] = [:]
    // nil until the monitor's capabilities string is read; then code -> allowed values.
    var supported: [UInt8: [Int]]?
    // Dell (and most monitors) lock brightness/contrast while macOS drives them in HDR.
    var hdr = false
    var hdrSupported = false
    // Vendor-model-serial stays the same across reconnects and tells identical models apart.
    private let profilesKey: String
    var profiles: [Profile] {
        didSet { UserDefaults.standard.set(try? JSONEncoder().encode(profiles), forKey: profilesKey) }
    }
    private var volumeBeforeMute = 30

    init(id: CGDirectDisplayID, legacyProfilesKey: String?) {
        self.id = id
        profilesKey = "profiles.\(CGDisplayVendorNumber(id))-\(CGDisplayModelNumber(id))-\(CGDisplaySerialNumber(id))"
        let defaults = UserDefaults.standard
        let data = defaults.data(forKey: profilesKey) ?? legacyProfilesKey.flatMap { defaults.data(forKey: $0) }
        profiles = data.flatMap { try? JSONDecoder().decode([Profile].self, from: $0) } ?? []
        if defaults.data(forKey: profilesKey) == nil, let data { defaults.set(data, forKey: profilesKey) }
    }

    func refresh(after delay: Double = 0) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [self] in
            hdrSupported = HDR.supported(id)
            hdr = HDR.enabled(id) ?? ((screen(id)?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1)
            guard let ddc else { responded = false; return }
            if responded == false { responded = nil }
            let known = supported
            Task.detached {
                let caps = known ?? ddc.capabilities().map(DDC.supportedCodes).flatMap { $0.isEmpty ? nil : $0 }
                var read: [VCP: (current: Int, max: Int)] = [:]
                for code in VCP.allCases where caps?[code.rawValue] != nil || caps == nil {
                    read[code] = ddc.read(code)
                }
                let (values, maxes) = (read.mapValues(\.current), read.mapValues(\.max))
                await MainActor.run {
                    self.supported = caps; self.values = values; self.maxes = maxes
                    self.responded = !values.isEmpty
                }
            }
        }
    }

    func setHDR(_ on: Bool) {
        hdr = on
        Task.detached { [id] in HDR.set(id, on) }
        refresh(after: 3)
    }

    var canRestoreColor: Bool { supported.map { $0[0x08] != nil } ?? true }

    func restoreFactoryColor() {
        ddc?.restoreFactoryColor()
        refresh(after: 1.5)
    }

    func set(_ code: VCP, _ value: Int) {
        values[code] = value
        ddc?.set(code, value)
    }

    func binding(_ code: VCP) -> Binding<Double> {
        Binding(get: { Double(self.values[code] ?? 0) }, set: { self.set(code, Int($0.rounded())) })
    }

    func supports(_ code: VCP) -> Bool { supported.map { $0[code.rawValue] != nil } ?? true }

    func options(_ code: VCP, fallback: [Int]) -> [Int] {
        supported?[code.rawValue].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
    }

    // Changing mode/preset makes the monitor load that preset's own brightness, colour, etc.
    func switchPicture(_ code: VCP, _ value: Int) {
        set(code, value)
        refresh(after: 1)
    }

    // Many monitors (this Dell included) don't implement MCCS mute (0x8D), so mute is volume 0.
    func toggleMute() {
        let v = values[.volume] ?? 0
        if v > 0 { volumeBeforeMute = v; set(.volume, 0) } else { set(.volume, volumeBeforeMute) }
    }

    // Input (high byte is junk on Dell) and volume aren't part of a picture profile.
    var input: Int? { values[.input].map { $0 & 0xFF } }
    private static let profileCodes: [VCP] = [.presetMode, .colorPreset, .redGain, .greenGain, .blueGain, .brightness, .contrast]

    func saveProfile(_ name: String) {
        profiles.append(Profile(name: name, values: values.filter { Self.profileCodes.contains($0.key) }))
    }

    func updateProfile(_ p: Profile) {
        guard let i = profiles.firstIndex(where: { $0.id == p.id }) else { return }
        profiles[i].values = values.filter { Self.profileCodes.contains($0.key) }
    }

    func apply(_ p: Profile) {
        // Writing RGB gains under a fixed preset flips most monitors into their custom/user mode,
        // so gains are only restored when the profile was saved on a user preset (MCCS 0x0B–0x0D).
        let userPreset = p.values[.colorPreset].map { (0x0B...0x0D).contains($0) } ?? true
        for code in Self.profileCodes {
            guard let v = p.values[code], userPreset || ![.redGain, .greenGain, .blueGain].contains(code) else { continue }
            set(code, v)
        }
        refresh(after: 1)
    }

    func isActive(_ p: Profile) -> Bool {
        !p.values.isEmpty && p.values.allSatisfy { values[$0.key] == $0.value }
    }
}

struct Panel: View {
    let displays: Displays
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if displays.monitors.isEmpty {
                Label("No external display connected", systemImage: "display.trianglebadge.exclamationmark")
                    .foregroundStyle(.secondary)
            }
            if displays.monitors.count > 1 {
                Picker("Monitor", selection: Binding(get: { displays.selected?.id ?? 0 }, set: { displays.selectedID = $0 })) {
                    ForEach(displays.monitors) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            if let monitor = displays.selected { MonitorSection(monitor: monitor).id(monitor.id) }
            Divider()
            HStack {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .toggleStyle(.checkbox)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            }
            .font(.callout)
        }
        .padding(16)
        .frame(width: 320)
        .onAppear { displays.rescan(); displays.selected?.refresh() }
        .onChange(of: displays.selected?.id) { displays.selected?.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification)) { _ in
            displays.rescan()
            // A freshly plugged monitor's DDC service can register a moment after the screen appears.
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { displays.rescan(); displays.selected?.refresh() }
        }
    }
}

// MCCS names for VCP 0x60 / 0xDC / 0x14 values; 0x1B (USB-C) is Dell's.
private let inputNames = [0x01: "VGA", 0x03: "DVI", 0x0F: "DP 1", 0x10: "DP 2", 0x11: "HDMI 1", 0x12: "HDMI 2", 0x1B: "USB-C"]
private let modeNames = [0x00: "Standard", 0x01: "Productivity", 0x02: "Mixed", 0x03: "Movie", 0x04: "User",
                         0x05: "Game", 0x06: "Sports", 0x07: "Professional"]
private let presetNames = [0x01: "sRGB", 0x02: "Native", 0x03: "4000K", 0x04: "5000K", 0x05: "6500K", 0x06: "7500K",
                           0x07: "8200K", 0x08: "9300K", 0x09: "10000K", 0x0A: "11500K", 0x0B: "User 1", 0x0C: "User 2", 0x0D: "User 3"]
private func name(_ table: [Int: String], _ v: Int) -> String { table[v] ?? String(format: "0x%02X", v) }

struct MonitorSection: View {
    let monitor: Monitor
    @State private var showColor = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(monitor.name, systemImage: "display")
                .font(.headline)

            if monitor.ddc == nil || monitor.responded == false {
                hdrRow
                Label("No hardware controls on this connection", systemImage: "slash.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .help("This connection doesn't pass DDC/CI, e.g. DisplayLink adapters or the M1 Mac mini's HDMI port. USB-C or DisplayPort usually does.")
            } else if monitor.values.isEmpty {
                ProgressView().controlSize(.small).frame(maxWidth: .infinity)
            } else {
                hdrRow
                Group {
                    SliderRow(icon: "sun.max.fill", help: "Brightness", monitor: monitor, code: .brightness)
                    SliderRow(icon: "circle.lefthalf.filled", help: "Contrast", monitor: monitor, code: .contrast)
                }
                .disabled(monitor.hdr)
                if monitor.supports(.volume) {
                    SliderRow(icon: volumeIcon, help: (monitor.values[.volume] ?? 0) > 0 ? "Mute" : "Unmute",
                              monitor: monitor, code: .volume) { monitor.toggleMute() }
                }

                let inputs = monitor.options(.input, fallback: [0x0F, 0x11, 0x12, 0x1B])
                Titled("Input") {
                    Picker("Input", selection: Binding(get: { monitor.input ?? -1 }, set: { monitor.set(.input, $0) })) {
                        ForEach(inputs, id: \.self) { Text(name(inputNames, $0)).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .help("Switching to another input hides this Mac until you switch back on the monitor")
                }

                let modes = monitor.options(.presetMode, fallback: [])
                let presets = monitor.options(.colorPreset, fallback: [])
                if modes.count > 1 || presets.count > 1 || monitor.canRestoreColor {
                    Titled("Picture") {
                        Group {
                            if modes.count > 1 {
                                Picker("Mode", selection: Binding(get: { monitor.values[.presetMode] ?? -1 },
                                                                  set: { monitor.switchPicture(.presetMode, $0) })) {
                                    ForEach(modes, id: \.self) { Text(name(modeNames, $0)).tag($0) }
                                }
                                .pickerStyle(.segmented)
                                .labelsHidden()
                            }
                            if presets.count > 1 {
                                Picker("Color preset", selection: Binding(get: { monitor.values[.colorPreset] ?? -1 },
                                                                          set: { monitor.switchPicture(.colorPreset, $0) })) {
                                    ForEach(presets, id: \.self) { Text(name(presetNames, $0)).tag($0) }
                                }
                                .font(.callout)
                            }
                        }
                        .disabled(monitor.hdr)
                        if monitor.canRestoreColor { FactoryColorButton(monitor: monitor) }
                    }
                }

                Titled("My profiles") { ProfilesRow(monitor: monitor) }

                DisclosureGroup("Color", isExpanded: $showColor) {
                    VStack(spacing: 8) {
                        SliderRow(icon: "r.circle.fill", help: "Red", monitor: monitor, code: .redGain).tint(.red)
                        SliderRow(icon: "g.circle.fill", help: "Green", monitor: monitor, code: .greenGain).tint(.green)
                        SliderRow(icon: "b.circle.fill", help: "Blue", monitor: monitor, code: .blueGain).tint(.blue)
                    }
                    .padding(.top, 8)
                }
                .font(.callout)
            }
        }
    }

    private var hdrRow: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: "sparkles")
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundStyle(.secondary)
                Text("HDR")
                Spacer()
                Text(monitor.hdr ? "On" : monitor.hdrSupported ? "Off" : "Not supported")
                    .foregroundStyle(.secondary)
                if monitor.hdrSupported {
                    Toggle("HDR", isOn: Binding(get: { monitor.hdr }, set: { monitor.setHDR($0) }))
                        .toggleStyle(.switch)
                        .controlSize(.mini)
                        .labelsHidden()
                }
            }
            .font(.callout)
            if monitor.hdr {
                Text("The monitor locks brightness, contrast and colour presets while HDR is on.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var volumeIcon: String {
        let v = monitor.values[.volume] ?? 0
        return v == 0 ? "speaker.slash.fill" : v < 34 ? "speaker.wave.1.fill" : v < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }
}

private struct Titled<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) { self.title = title; self.content = content() }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

struct ProfilesRow: View {
    let monitor: Monitor
    @State private var naming = false
    @State private var newName = ""
    @FocusState private var focused: Bool

    var body: some View {
        if naming {
            HStack(spacing: 6) {
                TextField("Profile name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit(save)
                    .onExitCommand { naming = false }
                Button("Save", action: save)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.small)
            .onAppear { focused = true }
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(monitor.profiles) { p in
                        Button(p.name) { monitor.apply(p) }
                            .buttonStyle(.bordered)
                            .tint(monitor.isActive(p) ? .accentColor : nil)
                            .help("Apply · right-click to update or delete")
                            .contextMenu {
                                Button("Update to Current Settings") { monitor.updateProfile(p) }
                                Button("Delete", role: .destructive) { monitor.profiles.removeAll { $0.id == p.id } }
                            }
                    }
                    Button {
                        newName = ""
                        naming = true
                    } label: {
                        if monitor.profiles.isEmpty { Label("Save current settings", systemImage: "plus") }
                        else { Image(systemName: "plus").accessibilityLabel("New profile") }
                    }
                    .buttonStyle(.bordered)
                    .help("Save the current picture settings as a profile")
                }
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
        }
    }

    private func save() {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        monitor.saveProfile(trimmed)
        naming = false
    }
}

// Two-step instead of an alert: alerts make the menu bar panel lose focus and close.
struct FactoryColorButton: View {
    let monitor: Monitor
    @State private var armed = false

    var body: some View {
        Button {
            if armed { monitor.restoreFactoryColor(); armed = false } else { armed = true }
        } label: {
            Label(armed ? "Click again to reset colours" : "Restore factory colours", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(armed ? .red : .secondary)
        .font(.callout)
        .help("Resets the colour preset and red, green and blue to the monitor's factory defaults. Save a profile first to keep your current colours.")
        .task(id: armed) {
            guard armed else { return }
            try? await Task.sleep(for: .seconds(4))
            armed = false
        }
    }
}

struct SliderRow: View {
    let icon: String
    let help: String
    let monitor: Monitor
    let code: VCP
    var tap: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 10) {
            Button { tap?() } label: {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .contentTransition(.symbolEffect(.replace))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .disabled(tap == nil)
            .help(help)
            .accessibilityLabel(help)

            Slider(value: monitor.binding(code), in: 0...Double(max(monitor.maxes[code] ?? 100, 1)))
                .accessibilityLabel(help)

            Text("\(monitor.values[code] ?? 0)")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 30, alignment: .trailing)
        }
    }
}

// HDR on/off has no public API; these SkyLight calls are what macOS's own Displays settings use.
// Looked up at runtime so a future macOS that drops them just hides the toggle.
enum HDR {
    private static let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func fn<T>(_ name: String, as: T.Type) -> T? { dlsym(sky, name).map { unsafeBitCast($0, to: T.self) } }
    private static let supportsFn = fn("SLSDisplaySupportsHDRMode", as: (@convention(c) (CGDirectDisplayID) -> Bool).self)
    private static let enabledFn = fn("SLSDisplayIsHDRModeEnabled", as: (@convention(c) (CGDirectDisplayID) -> Bool).self)
    private static let setFn = fn("SLSDisplaySetHDRModeEnabled", as: (@convention(c) (CGDirectDisplayID, Bool, Int32, Int32) -> Int32).self)

    static func supported(_ id: CGDirectDisplayID) -> Bool { setFn != nil && supportsFn?(id) == true }
    static func enabled(_ id: CGDirectDisplayID) -> Bool? { enabledFn?(id) }
    static func set(_ id: CGDirectDisplayID, _ on: Bool) { _ = setFn?(id, on, 0, 0) }
}
