//  BuildingCheck.swift
//  `locate` Block 2: GPS confirms the building.
//
//  GPS can't place you in a room (indoors it's off by 5–65 m on a ~10 m house), so
//  it only answers "is this phone at the house?". The house's coordinates and size
//  come from the data: geocoordinates.{latitude, longitude} and the room outlines.

import CoreLocation
import Foundation
import Observation

enum BuildingVerdict: Equatable {
    case waiting                          // no usable fix yet
    case atHouse(distance: Double)
    case notAtHouse(distance: Double)
    case unsure(distance: Double)         // fix too inaccurate to tell
}

enum BuildingRule {
    /// Extra distance allowed beyond the house's own radius, metres. Covers GPS
    /// error indoors and standing in the yard.
    static let slack = 20.0
    /// Fixes worse than this are ignored entirely, metres.
    static let maxUsableAccuracy = 100.0

    /// - distance: phone fix → house coordinate, metres
    /// - accuracy: the fix's horizontal accuracy (CLLocation.horizontalAccuracy), metres
    /// - houseRadius: half the diagonal of the house footprint, metres
    static func evaluate(distance: Double, accuracy: Double, houseRadius: Double) -> BuildingVerdict {
        guard accuracy >= 0, accuracy <= maxUsableAccuracy else { return .waiting }
        let limit = houseRadius + slack
        // At the house: the fix is inside the zone and precise enough to resolve it.
        if distance <= limit && accuracy <= limit { return .atHouse(distance: distance) }
        // Not at the house: even allowing for the fix's error it can't be inside.
        if distance - accuracy > limit { return .notAtHouse(distance: distance) }
        return .unsure(distance: distance)
    }

    /// Great-circle distance in metres.
    static func haversine(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lon2 - lon1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }

    /// Half the diagonal of the bounding box of all room outlines.
    static func houseRadius(_ graph: HouseGraph) -> Double {
        let pts = graph.rooms.flatMap(\.polygon)
        guard let minX = pts.map(\.x).min(), let maxX = pts.map(\.x).max(),
              let minY = pts.map(\.y).min(), let maxY = pts.map(\.y).max() else { return 0 }
        return hypot(maxX - minX, maxY - minY) / 2
    }
}

@Observable
final class BuildingCheck: NSObject {
    private(set) var verdict: BuildingVerdict = .waiting
    private(set) var accuracy: Double?
    private(set) var permissionDenied = false
    /// Demo override: treat the phone as being at the house (e.g. demoing at the
    /// venue). Always shown on screen when on, so it's never silent.
    var demoOverride = false

    let houseLatitude: Double
    let houseLongitude: Double
    let houseRadius: Double

    @ObservationIgnored private let manager = CLLocationManager()

    init(geo: GeoCoordinate, graph: HouseGraph) {
        houseLatitude = geo.latitude
        houseLongitude = geo.longitude
        houseRadius = BuildingRule.houseRadius(graph)
        super.init()
    }

    /// True when the building is confirmed, or the demo override is on.
    var isAtHouse: Bool {
        if demoOverride { return true }
        if case .atHouse = verdict { return true }
        return false
    }

    func start() {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.requestWhenInUseAuthorization()
        manager.startUpdatingLocation()
    }

    func stop() { manager.stopUpdatingLocation() }

    fileprivate func handle(lat: Double, lon: Double, accuracy acc: Double) {
        accuracy = acc
        let d = BuildingRule.haversine(lat, lon, houseLatitude, houseLongitude)
        verdict = BuildingRule.evaluate(distance: d, accuracy: acc, houseRadius: houseRadius)
    }
}

extension BuildingCheck: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        let lat = l.coordinate.latitude, lon = l.coordinate.longitude, acc = l.horizontalAccuracy
        MainActor.assumeIsolated { self.handle(lat: lat, lon: lon, accuracy: acc) }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            self.permissionDenied = status == .denied || status == .restricted
        }
    }
}
