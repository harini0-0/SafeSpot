//  WalkLogView.swift
//  LocateTest — camera preview, live sensor readout, start/stop and CSV export.

import RealityKit
import SwiftUI

struct ARPreview: UIViewRepresentable {
    let arView: ARView
    func makeUIView(context: Context) -> ARView { arView }
    func updateUIView(_ uiView: ARView, context: Context) {}
}

struct WalkLogView: View {
    @State private var logger = WalkLogger()

    var body: some View {
        VStack(spacing: 0) {
            ARPreview(arView: logger.ar.arView)
                .frame(maxHeight: 220)
                .overlay(alignment: .topLeading) {
                    Text("AR: \(logger.ar.trackingState)")
                        .font(.caption.monospaced())
                        .padding(6)
                        .background(.black.opacity(0.6))
                        .foregroundStyle(logger.ar.isNormal ? Color.green : Color.orange)
                        .padding(8)
                }

            List {
                Section("Live") {
                    row("Steps", "\(logger.motion.steps)")
                    row("Pedometer distance", meters(logger.motion.pedometerDistance))
                    row("AR path length", meters(logger.summary.arPathLength))
                    row("AR position (x, z)", position)
                    row("AR yaw", degrees(logger.ar.yaw))
                    row("Compass (true)", degrees(logger.motion.trueHeading))
                    row("Compass accuracy", logger.motion.headingAccuracy.map { "±\(Int($0))°" } ?? "–")
                    row("Fused heading", degrees(logger.motion.fusedHeading))
                }

                if !logger.isRecording && !logger.samples.isEmpty {
                    let s = logger.summary
                    Section("Walk result") {
                        row("Duration", String(format: "%.0f s", s.duration))
                        row("Steps", "\(s.steps)")
                        row("AR path length", meters(s.arPathLength))
                        row("AR start → end", meters(s.arStraightLine))
                        row("Step length (AR)", meters(s.stepLengthFromAR))
                        row("Step length (pedometer)", meters(s.stepLengthFromPedometer))
                        row("Compass drift vs AR", signedDegrees(s.compassDrift))
                        row("Fused heading drift vs AR", signedDegrees(s.fusedDrift))
                        row("AR not tracking", String(format: "%.0f%% of walk", s.arLimitedFraction * 100))
                    }
                    if let url = logger.csvURL {
                        Section {
                            ShareLink(item: url) { Label("Export CSV", systemImage: "square.and.arrow.up") }
                        }
                    }
                }

                if !logger.motion.errors.isEmpty {
                    Section("Sensor errors") {
                        ForEach(logger.motion.errors, id: \.self) { Text($0).font(.caption) }
                    }
                }
            }

            Button {
                logger.isRecording ? logger.stopWalk() : logger.startWalk()
            } label: {
                Text(logger.isRecording ? "Stop walk" : "Start walk")
                    .font(.title3.bold())
                    .frame(maxWidth: .infinity)
                    .padding()
            }
            .buttonStyle(.borderedProminent)
            .tint(logger.isRecording ? Color.red : Color.accentColor)
            .padding()
        }
        .onAppear { logger.startARPreview() }
        .onDisappear { if logger.isRecording { logger.stopWalk() }; logger.ar.stop() }
    }

    private var position: String {
        guard let p = logger.ar.position else { return "–" }
        return String(format: "%.2f, %.2f m", p.x, p.z)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).monospacedDigit().foregroundStyle(.secondary)
        }
    }

    private func meters(_ v: Double?) -> String { v.map { String(format: "%.2f m", $0) } ?? "–" }
    private func degrees(_ v: Double?) -> String { v.map { String(format: "%.0f°", $0) } ?? "–" }
    private func signedDegrees(_ v: Double?) -> String { v.map { String(format: "%+.1f°", $0) } ?? "–" }
}

#Preview {
    WalkLogView()
}
