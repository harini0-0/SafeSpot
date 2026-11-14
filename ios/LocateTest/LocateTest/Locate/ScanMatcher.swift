//  ScanMatcher.swift
//  `locate` Block 3: match the camera view against the house's scan photos.
//
//  References: 228 views cut from the 19 panoramas by scripts/make_scan_views.py,
//  each tagged with its pano's room id and position from the house data.
//  Matching: Apple Vision image feature prints, nearest distance per room.
//
//  Measured on the Mac (test views rotated 15° and zoomed, own panorama removed —
//  i.e. standing somewhere other than the scan spot):
//    one view, all rooms ............................ 38% right room
//    current room + neighbours, 4 views looking round  83%
//      … with margin ≥ 0.02 ......................... 95%  (show as a hint)
//      … with margin ≥ 0.06 ......................... 100%
//  Negative test (a different apartment's scans, pretending to be in each room):
//    margin ≥ 0.06 alone wrongly "recognised" it 52% of the time; adding
//    best distance ≤ 0.45 brought that to 0/864, while still acting on 29% of
//    windows in this house, all correct. Those are the thresholds below.
//  So the matcher combines the last 4 views taken in different directions, only
//  compares the candidate rooms it's given, and reports how close the best match is.

import CoreVideo
import Foundation
import ImageIO
import Observation
import UIKit
import Vision

struct ScanView: Decodable, Sendable {
    let file: String
    let panoId: String
    let roomId: String
    let x: Double
    let y: Double
}

struct ScanMatch: Equatable {
    let roomId: String
    /// Position of the closest-matching scan spot in that room (model space).
    let scanPoint: Point2D
    /// Average per-view distance gap between the best and second-best room.
    /// nil when only one candidate room was compared.
    let margin: Double?
    /// Average per-view feature-print distance of the winning room (lower = closer).
    let distance: Double
    let views: Int

    static let hintMargin = 0.02, hintDistance = 0.50
    static let actMargin = 0.06, actDistance = 0.45

    /// Worth showing as a suggestion.
    var isHint: Bool { views >= 2 && (margin ?? 0) >= Self.hintMargin && distance <= Self.hintDistance }
    /// Safe to act on (see the measurements above).
    var isConfident: Bool {
        views >= ScanMatcher.windowSize && (margin ?? 0) >= Self.actMargin && distance <= Self.actDistance
    }
    /// The camera doesn't look like anywhere in this house.
    var looksElsewhere: Bool { views >= ScanMatcher.windowSize && distance > Self.hintDistance }
}

@Observable
final class ScanMatcher {
    static let windowSize = 4
    /// Take a new sample when the phone has turned this much, or after `maxInterval`.
    static let minTurn = 30.0
    static let maxInterval = 2.0

    private(set) var isReady = false
    private(set) var referenceCount = 0
    private(set) var loadError: String?
    private(set) var match: ScanMatch?
    /// Called on the main thread after each new match.
    @ObservationIgnored var onMatch: ((ScanMatch) -> Void)?

    @ObservationIgnored private var refs: [(view: ScanView, print: VNFeaturePrintObservation)] = []
    @ObservationIgnored private let queue = DispatchQueue(label: "locate.scanmatcher", qos: .userInitiated)
    @ObservationIgnored private var busy = false
    @ObservationIgnored private var samples: [(yaw: Double, date: Date, perRoom: [String: (Float, ScanView)])] = []

    /// Load the reference views and compute their feature prints in the background.
    func load() {
        guard !isReady, refs.isEmpty else { return }
        queue.async {
            do {
                guard let url = Bundle.main.url(forResource: "scan_views", withExtension: "json")
                    ?? Bundle.main.url(forResource: "scan_views", withExtension: "json", subdirectory: "ScanViews")
                else { throw CocoaError(.fileNoSuchFile) }
                struct Index: Decodable { let views: [ScanView] }
                let index = try JSONDecoder().decode(Index.self, from: Data(contentsOf: url))
                var out: [(ScanView, VNFeaturePrintObservation)] = []
                for v in index.views {
                    let name = (v.file as NSString).deletingPathExtension
                    guard let imgURL = Bundle.main.url(forResource: name, withExtension: "jpg")
                            ?? Bundle.main.url(forResource: name, withExtension: "jpg", subdirectory: "ScanViews"),
                          let src = CGImageSourceCreateWithURL(imgURL as CFURL, nil),
                          let cg = CGImageSourceCreateImageAtIndex(src, 0, nil) else { continue }
                    let req = VNGenerateImageFeaturePrintRequest()
                    try VNImageRequestHandler(cgImage: cg).perform([req])
                    if let fp = req.results?.first { out.append((v, fp)) }
                }
                let loaded = out
                DispatchQueue.main.async {
                    self.refs = loaded.map { (view: $0.0, print: $0.1) }
                    self.referenceCount = loaded.count
                    self.isReady = !loaded.isEmpty
                    if loaded.isEmpty { self.loadError = "No scan views found" }
                }
            } catch {
                let msg = error.localizedDescription
                DispatchQueue.main.async { self.loadError = "Scan views: \(msg)" }
            }
        }
    }

    /// Forget recent samples (e.g. after the user taps a new position).
    func clear() {
        samples.removeAll()
        match = nil
    }

    /// Offer a camera frame. Dropped if a match is already running or the phone
    /// hasn't turned/waited enough since the last sample.
    /// - candidates: room ids to compare (current room + neighbours), or nil for all.
    func consider(_ pixelBuffer: CVPixelBuffer, yaw: Double, candidates: Set<String>?) {
        guard isReady, !busy else { return }
        if let last = samples.last {
            let turned = abs(FloorPlanLocator.wrap180(yaw - last.yaw))
            if turned < Self.minTurn && Date().timeIntervalSince(last.date) < Self.maxInterval { return }
        }
        busy = true
        let refs = self.refs.filter { candidates?.contains($0.view.roomId) ?? true }
        queue.async {
            // Back camera buffers are landscape; .right = phone held upright.
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right)
            let req = VNGenerateImageFeaturePrintRequest()
            var perRoom: [String: (Float, ScanView)] = [:]
            if (try? handler.perform([req])) != nil, let fp = req.results?.first {
                for r in refs {
                    var d: Float = 0
                    guard (try? fp.computeDistance(&d, to: r.print)) != nil else { continue }
                    if d < (perRoom[r.view.roomId]?.0 ?? .infinity) { perRoom[r.view.roomId] = (d, r.view) }
                }
            }
            DispatchQueue.main.async {
                self.busy = false
                guard !perRoom.isEmpty else { return }
                self.samples.append((yaw, Date(), perRoom))
                if self.samples.count > Self.windowSize { self.samples.removeFirst() }
                self.match = self.combine(candidates: candidates)
                if let m = self.match { self.onMatch?(m) }
            }
        }
    }

    /// Sum each room's best distance over the window; lowest total wins.
    private func combine(candidates: Set<String>?) -> ScanMatch? {
        guard !samples.isEmpty else { return nil }
        // Only rooms seen in every sample can be compared fairly.
        var rooms = Set(samples[0].perRoom.keys)
        for s in samples.dropFirst() { rooms.formIntersection(s.perRoom.keys) }
        if let c = candidates { rooms.formIntersection(c) }
        var totals: [(String, Float)] = rooms.map { room in
            (room, samples.reduce(0) { $0 + ($1.perRoom[room]?.0 ?? 0) })
        }
        totals.sort { $0.1 < $1.1 }
        guard let best = totals.first else { return nil }
        // The closest scan spot for the winning room, across the window.
        let closest = samples.compactMap { $0.perRoom[best.0] }.min { $0.0 < $1.0 }!.1
        let n = Float(samples.count)
        let margin = totals.count >= 2 ? Double((totals[1].1 - best.1) / n) : nil
        return ScanMatch(roomId: best.0, scanPoint: Point2D(x: closest.x, y: closest.y),
                         margin: margin, distance: Double(best.1 / n), views: samples.count)
    }
}
