//  ContentView.swift
//  SafeSpot

import SwiftUI

struct ContentView: View {
    // "Walk" (grey free-roam) is kept in the codebase but out of the UI for now —
    // Photo mode is the real walkthrough. Overhead is the floor-plan dollhouse.
    enum Mode: String, CaseIterable { case photo = "Photo", overhead = "Overhead" }
    @State private var mode: Mode = .photo

    var body: some View {
        ZStack(alignment: .top) {
            switch mode {
            case .photo: PanoramaView()
            case .overhead: HouseView()
            }

            Picker("Mode", selection: $mode) {
                ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 220)
            .padding(6)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 60)
        }
    }
}

#Preview {
    ContentView()
}
