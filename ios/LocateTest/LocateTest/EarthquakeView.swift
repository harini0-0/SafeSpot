//  EarthquakeView.swift
//  LocateTest — test screen for EarthquakeMotionStreamer.
//  The toggle stands in for the app's "Earthquake" hazard button.

import SwiftUI

struct EarthquakeView: View {
    @State private var streamer = EarthquakeMotionStreamer()
    /// Backend host (name or IP). Stored on the phone; never hardcoded.
    @AppStorage("backendHost") private var host = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Backend host, e.g. 192.168.1.20", text: $host)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .disabled(streamer.isActive)
                    if let u = EarthquakeMotionStreamer.sensorsURL(host: host) {
                        Text(u.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Backend")
                } footer: {
                    Text("The laptop running the backend, on the same Wi-Fi as this phone.")
                }

                Section {
                    Toggle("Earthquake mode", isOn: Binding(
                        get: { streamer.isActive },
                        set: { $0 ? streamer.start(host: host) : streamer.stop() }))
                        .tint(.red)
                    if let p = streamer.problem {
                        Text(p).foregroundStyle(.red).font(.callout)
                    }
                    row("Connection", connectionText)
                    row("Sent / dropped", "\(streamer.sentCount) / \(streamer.droppedCount)")
                }

                if let s = streamer.lastSummary {
                    Section("Last message (1 per second)") {
                        row("rms", String(format: "%.3f G", s.rms))
                        row("activity", "\(s.activity) (\(s.activityConfidence))")
                        row("ts", s.ts)
                    }
                }

                Section("How to test") {
                    Text("Shake the phone: rms should jump well above 0.3.\nLay it still on a table: rms near 0.0, activity \"stationary\".\nWalk with it: activity \"walking\".")
                        .font(.callout)
                }
            }
            .navigationTitle("Earthquake sensors")
        }
        .onDisappear { streamer.stop() }
    }

    private var connectionText: String {
        switch streamer.connection {
        case .off: return "off"
        case .connecting: return "connecting…"
        case .connected: return "connected ✓"
        case .waitingToRetry(let why): return "retrying — \(why)"
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary).multilineTextAlignment(.trailing)
        }
    }
}
