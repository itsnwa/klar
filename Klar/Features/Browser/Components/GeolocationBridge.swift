import Foundation
import WebKit
import CoreLocation

class GeolocationBridge: NSObject, WKScriptMessageHandler {
    // Created on the first geolocation request rather than in init: every tab
    // gets a bridge, but few pages ever ask for location.
    private var locationManager: CLLocationManager?
    // True while the system location prompt is up; see
    // locationManagerDidChangeAuthorization.
    private var isAwaitingSystemAuthorization = false
    private var pendingCallbacks: [String: GeolocationCallback] = [:]
    private var watchCallbacks: [String: GeolocationCallback] = [:]
    
    // Tab ID to associate requests with specific tabs
    var tabId: UUID?

    /// Every tab's bridge, to tell of a page that's gone (`pageDidChange`).
    private static let bridges = NSHashTable<GeolocationBridge>.weakObjects()

    init(tabId: UUID) {
        super.init()
        self.tabId = tabId
        Self.bridges.add(self)
    }

    /// A web view's main frame has a new document, and the requests of the
    /// one before are gone with it. A watch otherwise went on for as long
    /// as the tab lived, the Mac's location in use all the while, and each
    /// new position was handed to whatever page the tab showed by then.
    /// Every bridge is told: a window a page opened shares its opener's.
    static func pageDidChange(in webView: WKWebView) {
        for bridge in bridges.allObjects {
            bridge.forgetRequests(from: webView)
        }
    }

    private func forgetRequests(from webView: WKWebView) {
        guard !pendingCallbacks.isEmpty || !watchCallbacks.isEmpty else { return }
        pendingCallbacks = pendingCallbacks.filter { $0.value.webView !== webView }
        watchCallbacks = watchCallbacks.filter { $0.value.webView !== webView }
        stopUpdatingIfIdle()
    }

    /// Location updates go on only while a page is waiting for one. A
    /// request still to be answered keeps them: stopping would cancel it.
    private func stopUpdatingIfIdle() {
        // A closed tab's requests don't count.
        pendingCallbacks = pendingCallbacks.filter { $0.value.webView != nil }
        watchCallbacks = watchCallbacks.filter { $0.value.webView != nil }
        if pendingCallbacks.isEmpty, watchCallbacks.isEmpty {
            locationManager?.stopUpdatingLocation()
        }
    }
    
    struct GeolocationCallback {
        let requestId: String
        let method: String
        let options: GeolocationOptions?
        let watchId: Int?
        weak var webView: WKWebView?
    }
    
    struct GeolocationOptions: Codable {
        let enableHighAccuracy: Bool?
        let timeout: Double?
        let maximumAge: Double?
    }
    
    struct GeolocationMessage: Codable {
        let requestId: String
        let method: String
        let options: GeolocationOptions?
        let watchId: Int?
    }
    

    
    private func ensureLocationManager() -> CLLocationManager {
        if let locationManager = locationManager {
            return locationManager
        }
        let manager = CLLocationManager()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        locationManager = manager
        return manager
    }
    
    
    // Debug description of a system location authorization status. Takes the
    // status from the caller's manager — creating a CLLocationManager just to
    // read it is not free.
    private static func describe(_ status: CLAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return "Not Determined (0) - System will show prompt"
        case .restricted: return "Restricted (1) - Location disabled by parental controls"
        case .denied: return "Denied (2) - User denied or Location Services disabled"
        case .authorizedAlways: return "Authorized Always (3) - Full access"
        case .authorizedWhenInUse: return "Authorized When In Use (4) - App access granted"
        @unknown default: return "Unknown (\(status.rawValue))"
        }
    }
    
    // MARK: - WKScriptMessageHandler
    
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        
        guard let webView = message.webView else {
            logError(.location, "No webView in message")
            return
        }
        
        guard let messageDict = message.body as? [String: Any] else {
            logError(.location, "Message body is not a dictionary: \(type(of: message.body))", isPrivate: webView.isPrivateBrowsing)
            return
        }
        
        guard let data = try? JSONSerialization.data(withJSONObject: messageDict) else {
            logError(.location, "Failed to serialize message to JSON", isPrivate: webView.isPrivateBrowsing)
            return
        }
        
        guard let geolocationMessage = try? JSONDecoder().decode(GeolocationMessage.self, from: data) else {
            logError(.location, "Failed to decode geolocation message from JSON", isPrivate: webView.isPrivateBrowsing)
            logError(.location, "Raw message data: \(messageDict)", isPrivate: webView.isPrivateBrowsing)
            return
        }
        
        switch geolocationMessage.method {
        case "getCurrentPosition":
            handleGetCurrentPosition(message: geolocationMessage, webView: webView)
        case "watchPosition":
            handleWatchPosition(message: geolocationMessage, webView: webView)
        case "clearWatch":
            handleClearWatch(id: geolocationMessage.requestId)
        default:
            logWarning(.location, "Unknown geolocation method: \(geolocationMessage.method)")
        }
    }
    
    private func handleGetCurrentPosition(message: GeolocationMessage, webView: WKWebView) {
        
        let callback = GeolocationCallback(
            requestId: message.requestId,
            method: message.method,
            options: message.options,
            watchId: message.watchId,
            webView: webView
        )
        
        pendingCallbacks[message.requestId] = callback
        requestLocationPermissionAndGet(for: message.requestId)
    }
    
    private func handleWatchPosition(message: GeolocationMessage, webView: WKWebView) {
        let callback = GeolocationCallback(
            requestId: message.requestId,
            method: message.method,
            options: message.options,
            watchId: message.watchId,
            webView: webView
        )
        
        watchCallbacks[message.requestId] = callback
        
        requestLocationPermissionAndWatch(for: message.requestId)
    }
    
    private func handleClearWatch(id: String) {
        watchCallbacks.removeValue(forKey: id)
        stopUpdatingIfIdle()
    }
    
    private func requestLocationPermissionAndGet(for id: String) {
        guard let callback = pendingCallbacks[id],
              let webView = callback.webView else {
            logError(.location, "Missing callback or webView for id: \(id)")
            return
        }
        
        guard let host = webView.url?.host else {
            logError(.location, "No current URL available for permission check", isPrivate: webView.isPrivateBrowsing)
            sendError(for: id, code: 2, message: "No URL available", to: webView)
            return
        }
        
        // First check system-level location permission
        let locationManager = ensureLocationManager()
        let systemStatus = locationManager.authorizationStatus
        
        // Log system status before starting
        logDebug(.location, "System location status: \(Self.describe(systemStatus))")
        
        // If system permission is denied or restricted, we can't proceed
        switch systemStatus {
        case .denied, .restricted:
            logWarning(.location, "System location permission denied/restricted")
            // Provide helpful error message with instructions
            let message = systemStatus == .denied ? 
                "Location access denied. Please enable Location Services for Klar in System Settings → Privacy & Security → Location Services." :
                "Location access restricted by system settings."
            sendError(for: id, code: 1, message: message, to: webView)
            return
        case .notDetermined:
            logDebug(.location, "System location permission not determined, requesting...")
            isAwaitingSystemAuthorization = true
            locationManager.requestWhenInUseAuthorization()
            return
        case .authorizedAlways, .authorizedWhenInUse:
            // System permission is granted, now check per-domain permission
            break
        @unknown default:
            logError(.location, "Unknown system authorization status: \(systemStatus.rawValue)", isPrivate: webView.isPrivateBrowsing)
            sendError(for: id, code: 2, message: "Unknown authorization status", to: webView)
            return
        }
        
        // Then the site's answer (SitePermissionsManager); always called on
        // the main thread.
        SitePermissionsManager.shared.requestAccess(to: [.location], on: host, from: webView) { [weak self] allowed in
            guard let self = self else { return }
            if allowed {
                logDebug(.location, "✅ \(host) may use location, requesting it from CLLocationManager")
                self.locationManager?.requestLocation()
            } else {
                logWarning(.location, "❌ \(host) may not use location")
                self.sendError(for: id, code: 1, message: "Location permission denied", to: webView)
            }
        }
    }
    
    private func requestLocationPermissionAndWatch(for id: String) {
        guard let callback = watchCallbacks[id],
              let webView = callback.webView else {
            logError(.location, "Missing callback or webView for watch id: \(id)")
            return
        }
        
        guard let host = webView.url?.host else {
            logError(.location, "No current URL available for watch permission check", isPrivate: webView.isPrivateBrowsing)
            sendError(for: id, code: 2, message: "No URL available", to: webView, isWatch: true)
            return
        }
        
        // First check system-level location permission
        let locationManager = ensureLocationManager()
        let systemStatus = locationManager.authorizationStatus
        
        switch systemStatus {
        case .denied, .restricted:
            let message = systemStatus == .denied ? 
                "Location access denied. Please enable Location Services for Klar in System Settings." :
                "Location access restricted by system settings."
            sendError(for: id, code: 1, message: message, to: webView, isWatch: true)
            return
        case .notDetermined:
            isAwaitingSystemAuthorization = true
            locationManager.requestWhenInUseAuthorization()
            return
        case .authorizedAlways, .authorizedWhenInUse:
            break
        @unknown default:
            sendError(for: id, code: 2, message: "Unknown authorization status", to: webView, isWatch: true)
            return
        }
        
        // Then the site's answer, as for getCurrentPosition
        SitePermissionsManager.shared.requestAccess(to: [.location], on: host, from: webView) { [weak self] allowed in
            guard let self = self else { return }
            if allowed {
                logDebug(.location, "✅ \(host) may use location, starting location updates")
                self.locationManager?.startUpdatingLocation()
            } else {
                logWarning(.location, "❌ \(host) may not use location")
                self.sendError(for: id, code: 1, message: "Location permission denied", to: webView, isWatch: true)
            }
        }
    }
    
    private func sendLocation(_ location: CLLocation, for id: String, to webView: WKWebView, isWatch: Bool = false) {
        let position = [
            "coords": [
                "latitude": location.coordinate.latitude,
                "longitude": location.coordinate.longitude,
                "accuracy": location.horizontalAccuracy,
                "altitude": location.altitude,
                "altitudeAccuracy": location.verticalAccuracy,
                "heading": location.course >= 0 ? location.course as Any : NSNull(),
                "speed": location.speed >= 0 ? location.speed as Any : NSNull()
            ],
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000
        ] as [String: Any]
        
        var response: [String: Any] = [
            "type": "geolocation",
            "success": true,
            "requestId": id,
            "position": position
        ]
        
        if isWatch {
            if let callback = watchCallbacks[id] {
                if let watchId = callback.watchId {
                    response["watchId"] = watchId
                }
            }
        } else {
            pendingCallbacks.removeValue(forKey: id)
        }
        
        sendMessage(to: webView, data: response)
    }
    
    private func sendError(for id: String, code: Int, message: String, to webView: WKWebView, isWatch: Bool = false) {
        let error = [
            "code": code,
            "message": message
        ] as [String: Any]
        
        var response: [String: Any] = [
            "type": "geolocation", 
            "success": false,
            "requestId": id,
            "error": error
        ]
        
        if isWatch {
            if let callback = watchCallbacks[id] {
                if let watchId = callback.watchId {
                    response["watchId"] = watchId
                }
            }
        } else {
            pendingCallbacks.removeValue(forKey: id)
        }
        
        sendMessage(to: webView, data: response)
    }
    
    private func sendMessage(to webView: WKWebView, data: [String: Any]) {
        
        do {
            let jsonData = try JSONSerialization.data(withJSONObject: data)
            let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
            let script = "window.dispatchEvent(new MessageEvent('message', { data: \(jsonString) }));"
            
            
            DispatchQueue.main.async {
                webView.evaluateJavaScript(script) { result, error in
                    if let error = error {
                        logError(.location, "Error sending message to WebView: \(error)", isPrivate: webView.isPrivateBrowsing)
                    }
                }
            }
        } catch {
            logError(.location, "Error serializing response: \(error)", isPrivate: webView.isPrivateBrowsing)
        }
    }
    
    isolated deinit {
        // Stop location services
        locationManager?.stopUpdatingLocation()
        locationManager?.delegate = nil
        locationManager = nil
        
        // Clear callbacks
        pendingCallbacks.removeAll()
        watchCallbacks.removeAll()
    }
}

// MARK: - CLLocationManagerDelegate

extension GeolocationBridge: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        
        // Only act on the answer to our own system prompt. The delegate is
        // also called right after the manager is created — now always with a
        // request already pending — and acting on that call would fetch the
        // location before the per-site prompt.
        guard isAwaitingSystemAuthorization, status != .notDetermined else {
            return
        }
        isAwaitingSystemAuthorization = false
        logDebug(.location, "System location permission answered: \(Self.describe(status))")
        
        // Resume the waiting requests through the normal flow, so the per-site
        // prompt still applies and a denial reports the usual errors.
        for id in Array(pendingCallbacks.keys) {
            requestLocationPermissionAndGet(for: id)
        }
        for id in Array(watchCallbacks.keys) {
            requestLocationPermissionAndWatch(for: id)
        }
    }
    
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let location = locations.last else { return }
        
        logDebug(.location, "Location updated: \(location.coordinate.latitude), \(location.coordinate.longitude)")
        
        // Send to pending getCurrentPosition requests
        for (id, callback) in pendingCallbacks {
            if let webView = callback.webView {
                sendLocation(location, for: id, to: webView)
            }
        }
        
        // Send to active watch requests
        for (id, callback) in watchCallbacks {
            if let webView = callback.webView {
                sendLocation(location, for: id, to: webView, isWatch: true)
            }
        }

        // The last watch may have been its closed tab's.
        stopUpdatingIfIdle()
    }
    
    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        logError(.location, "Location error: \(error.localizedDescription)")
        
        let errorCode: Int
        let errorMessage: String
        
        if let clError = error as? CLError {
            switch clError.code {
            case .denied:
                errorCode = 1
                errorMessage = "Location permission denied"
            case .locationUnknown:
                errorCode = 2
                errorMessage = "Location unavailable"
            case .network:
                errorCode = 2
                errorMessage = "Network error"
            default:
                errorCode = 2
                errorMessage = clError.localizedDescription
            }
        } else {
            errorCode = 2
            errorMessage = error.localizedDescription
        }
        
        // Send errors to pending requests
        for (id, callback) in pendingCallbacks {
            if let webView = callback.webView {
                sendError(for: id, code: errorCode, message: errorMessage, to: webView)
            }
        }
        
        // Send errors to watch requests
        for (id, callback) in watchCallbacks {
            if let webView = callback.webView {
                sendError(for: id, code: errorCode, message: errorMessage, to: webView, isWatch: true)
            }
        }
    }
} 
