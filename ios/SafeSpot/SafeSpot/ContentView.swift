//  ContentView.swift
//  SafeSpot

import SwiftUI

struct ContentView: View {
    // Photo = photoreal 360 views; Walk = continuous first-person (live-tracked);
    // Overhead = floor-plan dollhouse.
    enum Mode: String, CaseIterable { case photo = "Photo", walk = "Walk", overhead = "Overhead" }
    @State private var mode: Mode = .photo

    var body: some View {
        ZStack(alignment: .top) {
            switch mode {
            case .photo: PanoramaView()
            case .walk: FirstPersonView()
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
