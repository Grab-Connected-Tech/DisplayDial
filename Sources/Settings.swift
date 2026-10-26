// DisplayDial by Grab Connected Tech, https://www.grabians.com

import SwiftUI
import ServiceManagement

// An AppKit window rather than a Settings scene: it opens from the panel, the hint and the right-click menu,
// and has to come to the front even though DisplayDial has no Dock icon. Closing it doesn't quit the app.
final class SettingsWindow: NSObject {
    let keys: Keys
    private var window: NSWindow?

    init(keys: Keys) { self.keys = keys }

    @objc func open() { show() }

    func show(highlightKeys: Bool = false) {
        let window = window ?? NSWindow(contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        if self.window == nil {
            window.title = "DisplayDial Settings"
            window.isReleasedWhenClosed = false
            self.window = window
        }
        window.contentViewController = NSHostingController(rootView: SettingsView(keys: keys, highlightKeys: highlightKeys))
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc func about() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
}

private let otherMonitorApps: Set = ["me.guillaumeb.MonitorControl", "pro.betterdisplay.BetterDisplay", "fyi.lunar.Lunar"]
private let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"

struct SettingsView: View {
    let keys: Keys
    let highlightKeys: Bool
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @AppStorage("keys.brightness") private var brightnessTarget = "pointer"
    @AppStorage("keys.volume") private var volumeKeys = true
    @AppStorage("keys.speakers") private var speakers = ""
    @AppStorage("keys.osd") private var indicator = true
    @State private var explaining = false
    @State private var turnedOff = false
    @State private var updateStatus: String?
    private let otherAppRunning = NSWorkspace.shared.runningApplications.contains { otherMonitorApps.contains($0.bundleIdentifier ?? "") }

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, on in
                        do { on ? try SMAppService.mainApp.register() : try SMAppService.mainApp.unregister() }
                        catch { launchAtLogin = SMAppService.mainApp.status == .enabled }
                    }
            }

            Section("Keyboard") {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Control external monitors with keyboard keys", isOn: Binding(get: { keys.enabled }, set: { on in
                        if on, !keys.trusted { explaining = true } else { keys.enabled = on }
                        turnedOff = !on && keys.trusted
                    }))
                    if keys.enabled {
                        if keys.trusted {
                            Label("Ready", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            HStack {
                                Label("Needs Accessibility access", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Spacer()
                                Button("Open System Settings") { NSWorkspace.shared.open(Keys.accessibilitySettings) }
                            }
                        }
                    } else if turnedOff {
                        Text("You can also remove DisplayDial from Privacy & Security › Accessibility in System Settings.")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)
                .padding(highlightKeys ? 6 : 0)
                .background(highlightKeys ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))

                Group {
                    Picker("Brightness keys adjust", selection: $brightnessTarget) {
                        Text("Screen under the pointer").tag("pointer")
                        Text("Screen with the active window").tag("window")
                        Text("All screens").tag("all")
                    }
                    Toggle("Volume keys adjust monitor speakers", isOn: $volumeKeys)
                    let candidates = keys.speakerCandidates
                    if candidates.count > 1 {
                        Picker("Monitor speakers in use", selection: $speakers) {
                            Text("Automatic").tag("")
                            ForEach(candidates) { Text($0.name).tag($0.key) }
                        }
                        .disabled(!volumeKeys)
                    }
                    Toggle("Show on-screen indicator", isOn: $indicator)
                }
                .disabled(!keys.enabled)

                if otherAppRunning {
                    Label("Another monitor app is running and may also respond to these keys.", systemImage: "info.circle")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Section("About") {
                LabeledContent("Version", value: version)
                Link("DisplayDial on GitHub", destination: URL(string: "https://github.com/Grab-Connected-Tech/DisplayDial")!)
                HStack {
                    Button("Check for Updates") { Task { await checkForUpdates() } }
                    if let updateStatus { Text(.init(updateStatus)).foregroundStyle(.secondary) }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize(horizontal: false, vertical: true)
        .sheet(isPresented: $explaining) { explanation }
    }

    private var explanation: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let DisplayDial use your keyboard keys").font(.headline)
            Text("To send your brightness and volume keys to your monitor, DisplayDial needs to catch those keys before macOS does. macOS calls this Accessibility access.")
            Text("DisplayDial only listens for the brightness, volume and mute keys. It can't see anything you type, and it has no network access.")
            HStack {
                Spacer()
                Button("Not now") { explaining = false }
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    explaining = false
                    keys.enabled = true
                    keys.requestAccess()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(20)
        .frame(width: 400)
    }

    // DisplayDial's only network request, made only when this button is clicked.
    private func checkForUpdates() async {
        updateStatus = "Checking…"
        let url = URL(string: "https://api.github.com/repos/Grab-Connected-Tech/DisplayDial/releases/latest")!
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let tag = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["tag_name"] as? String else {
            updateStatus = "Couldn't check for updates"
            return
        }
        let latest = String(tag.trimmingPrefix("v"))
        updateStatus = latest.compare(version, options: .numeric) == .orderedDescending
            ? "Version \(latest) is available · [Download](https://github.com/Grab-Connected-Tech/DisplayDial/releases/latest)"
            : "You're up to date"
    }
}
