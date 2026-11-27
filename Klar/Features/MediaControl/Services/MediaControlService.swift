import Foundation
import WebKit

// MARK: - Media Control Service

class MediaControlService {
    static let shared = MediaControlService()
    
    private init() {}
    
    // MARK: - JavaScript Generation
    
    /// Generates the comprehensive media control JavaScript for injection
    func generateMediaControlScript() -> String {
        return """
        (function() {
            'use strict';

            // Holds tracked media elements weakly, so tracking never keeps a
            // removed <video> or a finished `new Audio()` alive. Dead refs are
            // swept whenever the list doubles, which keeps add() amortised O(1).
            class WeakList {
                constructor() {
                    this.refs = [];
                    this.members = new WeakSet();
                    this.sweepAt = 64;
                }
                // Returns true the first time a value is added.
                add(value) {
                    if (this.members.has(value)) return false;
                    this.members.add(value);
                    this.refs.push(new WeakRef(value));
                    if (this.refs.length >= this.sweepAt) {
                        this.refs = this.refs.filter(ref => ref.deref() !== undefined);
                        this.sweepAt = Math.max(64, this.refs.length * 2);
                    }
                    return true;
                }
                forEach(callback) {
                    for (const ref of this.refs) {
                        const value = ref.deref();
                        if (value !== undefined) callback(value);
                    }
                }
            }

            // Global media control state. AudioContexts stay strongly held
            // until they close: a context suspended by mute must be
            // resumable. Gain nodes are held weakly, since pages such as games
            // make one per sound, and strongly only while muted
            // (`mutedGainNodes`, with the gain each had): a muted node the
            // page keeps no reference to still carries audio, and must be
            // unmutable. Closed ones are dropped whenever another context is
            // created or mute changes.
            window.__mediaControl = {
                isMuted: false,
                audioContexts: [],
                gainNodes: new WeakList(),
                mutedGainNodes: new Map(),
                mediaElements: new WeakList(),
                originalValues: new WeakMap()
            };

            const mc = window.__mediaControl;

            function pruneClosedContexts() {
                mc.audioContexts = mc.audioContexts.filter(ctx => {
                    try { return ctx.state !== 'closed'; } catch(e) { return false; }
                });
                for (const node of mc.mutedGainNodes.keys()) {
                    let isOpen = false;
                    try { isOpen = node.context.state !== 'closed'; } catch(e) {}
                    if (!isOpen) mc.mutedGainNodes.delete(node);
                }
            }

            function muteGainNode(gainNode) {
                if (mc.mutedGainNodes.has(gainNode)) return;
                try {
                    mc.mutedGainNodes.set(gainNode, gainNode.gain.value);
                    gainNode.gain.value = 0;
                } catch (e) {}
            }

            // Initialize media control system
            function initializeMediaControl() {
                setupAudioContextInterception();
                setupAudioConstructorInterception();
                setupPlaybackTracking();
            }

            // MARK: - Audio Context Interception

            function setupAudioContextInterception() {
                const OriginalAudioContext = window.AudioContext || window.webkitAudioContext;
                if (!OriginalAudioContext) return;

                function TrackedAudioContext(...args) {
                    const context = new OriginalAudioContext(...args);
                    pruneClosedContexts();
                    mc.audioContexts.push(context);

                    // Override createGain
                    const originalCreateGain = context.createGain.bind(context);
                    context.createGain = function() {
                        const gainNode = originalCreateGain();
                        mc.gainNodes.add(gainNode);

                        // Apply current mute state
                        if (mc.isMuted) {
                            muteGainNode(gainNode);
                        }

                        return gainNode;
                    };

                    // Override createMediaElementSource (SoundCloud's main method)
                    const originalCreateMediaElementSource = context.createMediaElementSource.bind(context);
                    context.createMediaElementSource = function(mediaElement) {
                        const source = originalCreateMediaElementSource(mediaElement);
                        // Often a never-inserted element, so this may be the
                        // only place it is seen.
                        trackMediaElement(mediaElement);
                        return source;
                    };

                    return context;
                }

                // Copy static properties
                Object.setPrototypeOf(TrackedAudioContext.prototype, OriginalAudioContext.prototype);
                Object.setPrototypeOf(TrackedAudioContext, OriginalAudioContext);

                // Replace constructors
                if (window.AudioContext) {
                    window.AudioContext = TrackedAudioContext;
                }
                if (window.webkitAudioContext) {
                    window.webkitAudioContext = TrackedAudioContext;
                }
            }

            // MARK: - Audio Constructor Interception

            function setupAudioConstructorInterception() {
                // Override Audio constructor (covers new Audio() calls)
                const OriginalAudio = window.Audio;
                if (OriginalAudio) {
                    window.Audio = function(...args) {
                        const audio = new OriginalAudio(...args);
                        trackMediaElement(audio);
                        return audio;
                    };
                }
                // Note: document.createElement is intentionally NOT overridden.
                // Media in the document is tracked when it plays (see
                // setupPlaybackTracking) without the cost of intercepting all
                // element creation.
            }

            function trackMediaElement(element) {
                // Originals are captured once, the first time an element is seen,
                // so a later sighting can't record our own muted state as the
                // page's.
                if (mc.mediaElements.add(element)) {
                    mc.originalValues.set(element, { muted: element.muted, volume: element.volume });
                }

                // Apply current mute state
                if (mc.isMuted) {
                    element.muted = true;
                }
            }

            // MARK: - Playback Tracking

            function setupPlaybackTracking() {
                // Track document media when it starts playing instead of watching
                // every DOM insertion: no per-mutation work, and it also works in
                // hidden tabs, where the old animation-frame batching never ran
                // (and kept every added node queued). Media that hasn't played
                // is picked up by __muteMedia's document sweep. Capture phase
                // because media events don't bubble.
                document.addEventListener('play', event => {
                    const element = event.target;
                    if (element && (element.tagName === 'AUDIO' || element.tagName === 'VIDEO')) {
                        trackMediaElement(element);
                    }
                }, true);
            }

            // MARK: - Global Mute Control

            window.__muteMedia = function(shouldMute) {
                mc.isMuted = shouldMute;

                // Drop closed contexts before iterating
                pruneClosedContexts();

                // Method 1: Suspend/Resume AudioContexts
                mc.audioContexts.forEach(context => {
                    try {
                        if (shouldMute && context.state === 'running') {
                            context.suspend();
                        } else if (!shouldMute && context.state === 'suspended') {
                            context.resume();
                        }
                    } catch (e) {}
                });

                // Method 2: Control Gain Nodes. Each is given back the gain
                // it had when muted, which the page may have changed since
                // creating it.
                if (shouldMute) {
                    mc.gainNodes.forEach(muteGainNode);
                } else {
                    mc.mutedGainNodes.forEach((gain, gainNode) => {
                        try { gainNode.gain.value = gain; } catch (e) {}
                    });
                    mc.mutedGainNodes.clear();
                }

                // Method 3: Control Media Elements — everything tracked
                // (`new Audio()`, Web Audio sources, media that has played)
                // plus any media currently in the DOM.
                document.querySelectorAll('audio, video').forEach(trackMediaElement);
                mc.mediaElements.forEach(element => {
                    try {
                        if (shouldMute) {
                            element.muted = true;
                            element.volume = 0;
                        } else {
                            const original = mc.originalValues.get(element) || { muted: false, volume: 1 };
                            element.muted = original.muted;
                            element.volume = original.volume;
                        }
                    } catch (e) {}
                });
            };

            // MARK: - Initialization

            initializeMediaControl();

        })();
        """
    }
    
    // MARK: - Mute Control
    
    func generateMuteScript(shouldMute: Bool) -> String {
        return """
        // Media Control Mute Operation
        if (typeof window.__muteMedia === 'function') {
            window.__muteMedia(\(shouldMute));
        } else {
            // Fallback mute control
            document.querySelectorAll('audio, video').forEach(element => {
                element.muted = \(shouldMute);
                if (\(shouldMute)) {
                    element.volume = 0;
                } else {
                    element.volume = 1;
                }
            });
        }
        """
    }

    func generatePauseResumeScript(shouldPause: Bool) -> String {
        return """
        (function() {
            document.querySelectorAll('audio, video').forEach(element => {
                try {
                    if (\(shouldPause)) {
                        if (!element.paused) element.pause();
                    } else {
                        if (element.paused && element.readyState > 0) element.play();
                    }
                } catch(e) {}
            });
            // Also handle AudioContexts
            if (window.__mediaControl) {
                window.__mediaControl.audioContexts.forEach(ctx => {
                    try {
                        if (\(shouldPause) && ctx.state === 'running') {
                            ctx.suspend();
                        } else if (!\(shouldPause) && ctx.state === 'suspended') {
                            ctx.resume();
                        }
                    } catch(e) {}
                });
            }
        })();
        """
    }
}
