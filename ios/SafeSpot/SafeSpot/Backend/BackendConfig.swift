//  BackendConfig.swift
//  Where Lavanya's backend lives. The real host is read from a gitignored
//  `BackendConfig.plist` (key `BaseURL`, e.g. "http://192.168.1.23:8000") so the
//  LAN IP isn't committed; `BackendConfig.example.plist` documents the format.
//  Without the plist it falls back to localhost (simulator / same-machine runs).

import Foundation

enum BackendConfig {
    /// http(s) base, e.g. http://192.168.1.23:8000 — used for POST /plan, /report.
    static let baseURL: URL = {
        if let url = Bundle.main.url(forResource: "BackendConfig", withExtension: "plist"),
           let dict = NSDictionary(contentsOf: url),
           let s = dict["BaseURL"] as? String,
           let u = URL(string: s) {
            return u
        }
        return URL(string: "http://localhost:8000")!
    }()

    /// ws(s) base derived from `baseURL` — used for /ws/plan and /ws/sensors.
    static let wsBaseURL: URL = {
        var c = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        c.scheme = (c.scheme == "https") ? "wss" : "ws"
        return c.url!
    }()
}
