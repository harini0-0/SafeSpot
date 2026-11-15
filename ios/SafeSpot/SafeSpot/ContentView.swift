//  ContentView.swift
//  SafeSpot

import SwiftUI

struct ContentView: View {
    // Walk = photoreal continuous walkthrough (textured MatterPak mesh), live-tracked;
    // Photo = 360 photo stills at scan points; Overhead = floor-plan dollhouse.
    enum Mode: String, CaseIterable { case walk = "Walk", photo = "Photo", overhead = "Overhead" }
    @State private var mode: Mode = .walk

    var body: some View {
        ZStack(alignment: .top) {
            switch mode {
            case .walk: FirstPersonView()
            case .photo: PanoramaView()
            case .overhead: HouseView()
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 60)
        }
    }
}

#Preview {
    ContentView()
}
