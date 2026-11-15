//  ContentView.swift
//  SafeSpot

import SwiftUI

struct ContentView: View {
    // Tour = Matterport-style hybrid (stand in sharp panorama, glide through the
    // textured mesh between points); Photo = pano stills; Overhead = dollhouse map.
    enum Mode: String, CaseIterable { case tour = "Tour", photo = "Photo", overhead = "Overhead" }
    @State private var mode: Mode = .tour

    var body: some View {
        ZStack(alignment: .top) {
            switch mode {
            case .tour: HybridTourView()
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
