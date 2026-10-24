//
// MockLocationStateManaging.swift
// bitchatTests
//
// This is free and unencumbered software released into the public domain.
// For more information, see <https://unlicense.org>
//

import CoreLocation
@testable import bitchat

/// CoreLocation stand-in for `LocationStateManager`. It counts every request,
/// so a test can pin exactly which location work a path asks for: a
/// permission prompt, one fix, or continuous updates.
final class MockLocationStateManaging: LocationStateManaging {
    weak var delegate: CLLocationManagerDelegate?
    var desiredAccuracy: CLLocationAccuracy = 0
    var distanceFilter: CLLocationDistance = 0
    var authorizationStatus: CLAuthorizationStatus
    private(set) var requestAuthorizationCallCount = 0
    private(set) var requestLocationCallCount = 0
    private(set) var startUpdatingLocationCallCount = 0
    private(set) var stopUpdatingLocationCallCount = 0
    /// A one-shot fix is on its way: `requestLocation` asked for one and no
    /// `stopUpdatingLocation` has cancelled it since, as CoreLocation's
    /// does. The mock never delivers one.
    private(set) var isFixPending = false

    init(authorizationStatus: CLAuthorizationStatus = .denied) {
        self.authorizationStatus = authorizationStatus
    }

    func requestWhenInUseAuthorization() {
        requestAuthorizationCallCount += 1
    }

    func requestLocation() {
        requestLocationCallCount += 1
        isFixPending = true
    }

    func startUpdatingLocation() {
        startUpdatingLocationCallCount += 1
    }

    func stopUpdatingLocation() {
        stopUpdatingLocationCallCount += 1
        isFixPending = false
    }
}

/// Reverse-geocoder stand-in: answers with the queued responses in order
/// (no placemarks once they run out), synchronously, recording each request.
final class MockLocationStateGeocoder: LocationStateGeocoding {
    private struct Response {
        let placemarks: [CLPlacemark]?
        let error: Error?
    }

    private(set) var cancelCallCount = 0
    private(set) var reverseRequests: [CLLocation] = []
    private var responses: [Response] = []

    func enqueue(placemarks: [CLPlacemark]?, error: Error? = nil) {
        responses.append(Response(placemarks: placemarks, error: error))
    }

    func cancelGeocode() {
        cancelCallCount += 1
    }

    func reverseGeocodeLocation(
        _ location: CLLocation,
        completionHandler: @escaping ([CLPlacemark]?, Error?) -> Void
    ) {
        reverseRequests.append(location)
        let response = responses.isEmpty ? Response(placemarks: nil, error: nil) : responses.removeFirst()
        completionHandler(response.placemarks, response.error)
    }
}
