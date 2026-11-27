import Foundation
import WebKit

// MARK: - Media Control Manager

class MediaControlManager: ObservableObject {
    static let shared = MediaControlManager()
    
    @Published private(set) var tabMediaStates: [UUID: TabMediaState] = [:]
    
    private let service = MediaControlService.shared
    
    private init() {}
    
    // MARK: - Public Interface
    
    func getTabMediaState(for tabId: UUID) -> TabMediaState {
        if let existing = tabMediaStates[tabId] {
            return existing
        }
        
        let newState = TabMediaState()
        tabMediaStates[tabId] = newState
        return newState
    }
    
    func updatePlaybackState(for tabId: UUID, isPlaying: Bool) {
        let state = getTabMediaState(for: tabId)
        let wasPlaying = state.isPlayingMedia
        state.updatePlaybackState(isPlaying)
        // Notify observers when playing state changes so views like NowPlayingWidget update
        if wasPlaying != isPlaying {
            objectWillChange.send()
        }
    }
    
    func togglePause(for tabId: UUID) {
        let state = getTabMediaState(for: tabId)
        let shouldPause = !state.isMediaPaused

        // Use JavaScript pause/play so website controls still work
        if let coordinator = TabWebViewCoordinator.coordinator(for: tabId) {
            let script = service.generatePauseResumeScript(shouldPause: shouldPause)
            coordinator.webView.evaluateJavaScript(script) { [isPrivate = coordinator.tab.isPrivate] _, error in
                if let error = error {
                    logError(.media, "Failed to execute pause/resume script: \(error)", isPrivate: isPrivate)
                }
            }
        }

        state.isMediaPaused = shouldPause
        objectWillChange.send()
    }

    /// Pauses what plays in the tab, and brings a video out of Picture in
    /// Picture back into the page: a pinned site closed with ⌘W stays
    /// loaded, but stops. Not `isMediaPaused`, which keeps a tab paused from
    /// the Now Playing widget in it: the page reports it stopped, and the
    /// widget lets it go.
    func pauseMedia(for tabId: UUID) {
        guard let coordinator = TabWebViewCoordinator.coordinator(for: tabId) else { return }
        let script = service.generatePauseResumeScript(shouldPause: true) + """

        (function(){
            document.querySelectorAll('video').forEach(function(v){
                try {
                    if(v.webkitPresentationMode==='picture-in-picture')v.webkitSetPresentationMode('inline');
                } catch(e) {}
            });
            if(document.pictureInPictureElement&&document.exitPictureInPicture){
                document.exitPictureInPicture().catch(function(){});
            }
        })();
        """
        coordinator.webView.evaluateJavaScript(script) { [isPrivate = coordinator.tab.isPrivate] _, error in
            if let error = error {
                logError(.media, "Failed to pause media: \(error)", isPrivate: isPrivate)
            }
        }
    }

    func toggleMute(for tabId: UUID) {
        let state = getTabMediaState(for: tabId)
        let newMuteState = !state.isMediaMuted
        state.updateMuteState(newMuteState)
        objectWillChange.send()
        
        // The tab's coordinator runs the mute script and updates its BrowserTab
        NotificationCenter.default.post(
            name: NSNotification.Name("MediaControlMuteTab"),
            object: nil,
            userInfo: [
                "tabId": tabId.uuidString,
                "shouldMute": newMuteState
            ]
        )
        
        logDebug(.media, "Tab \(tabId): mute toggled to \(newMuteState)")
    }
    
    /// Pops the tab's largest playing video out to Picture in Picture.
    /// `evaluateJavaScript` runs as a user gesture, which WebKit requires
    /// for it.
    func enterPictureInPicture(for tabId: UUID) {
        guard let coordinator = TabWebViewCoordinator.coordinator(for: tabId) else { return }
        let script = """
        (function(){
            var v=null,maxA=0;
            document.querySelectorAll('video').forEach(function(el){
                if(el.readyState<2||!el.videoWidth)return;
                var b=el.getBoundingClientRect(),a=b.width*b.height;
                if(a>maxA){maxA=a;v=el;}
            });
            if(!v)return;
            v.disablePictureInPicture=false;
            if(v.webkitSupportsPresentationMode&&v.webkitSupportsPresentationMode('picture-in-picture')){
                v.webkitSetPresentationMode('picture-in-picture');
            }else if(v.requestPictureInPicture){
                v.requestPictureInPicture().catch(function(){});
            }
        })();
        """
        coordinator.webView.evaluateJavaScript(script) { [isPrivate = coordinator.tab.isPrivate] _, error in
            if let error = error {
                logError(.media, "Failed to enter Picture in Picture: \(error)", isPrivate: isPrivate)
            }
        }
    }

    func cleanupTab(_ tabId: UUID) {
        tabMediaStates.removeValue(forKey: tabId)
    }

    /// The tab has loaded another page: what was paused from the Now
    /// Playing widget went with the last one. The tab otherwise kept its
    /// row there, with a play button for nothing.
    func pageDidChange(for tabId: UUID) {
        guard let state = tabMediaStates[tabId], state.isMediaPaused else { return }
        state.isMediaPaused = false
        objectWillChange.send()
    }
    
    // MARK: - WebView Integration
    
    func executeMuteScript(in webView: WKWebView, shouldMute: Bool) {
        let script = service.generateMuteScript(shouldMute: shouldMute)
        webView.evaluateJavaScript(script) { [isPrivate = webView.isPrivateBrowsing] _, error in
            if let error = error {
                logError(.media, "Failed to execute mute script: \(error)", isPrivate: isPrivate)
            }
        }
    }
}

// MARK: - Extensions

extension MediaControlManager {
    /// Check if any tab has active media (playing, paused, or muted)
    var hasActiveMedia: Bool {
        return tabMediaStates.values.contains { $0.hasActiveMedia }
    }
}
