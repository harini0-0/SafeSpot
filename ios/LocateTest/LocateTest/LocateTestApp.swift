//  LocateTestApp.swift
//  LocateTest — standalone test app for the `locate` module.
//  Kept separate from ios/SafeSpot so locate work isn't blocked on the main app.
//  Everything in Locate/ is written to move into SafeSpot unchanged.

import SwiftUI

@main
struct LocateTestApp: App {
    var body: some Scene {
        WindowGroup {
            TabView {
                FloorPlanView()
                    .tabItem { Label("Floor plan", systemImage: "map") }
                WalkLogView()
                    .tabItem { Label("Walk log", systemImage: "figure.walk") }
                EarthquakeView()
                    .tabItem { Label("Earthquake", systemImage: "waveform.path.ecg") }
            }
        }
    }
}
