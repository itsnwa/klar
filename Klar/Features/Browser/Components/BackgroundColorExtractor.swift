import Foundation
import SwiftUI
import WebKit
import AppKit

// MARK: - Background Color Extraction
class BackgroundColorExtractor {
    
    // MARK: - Dynamic Update Script
    static var dynamicUpdateScript: String {
        return """
        (function() {
            // Simple background color detection - no guessing, no confidence scores
            function getBackgroundColor() {
                // Check elements in order of priority
                const elements = [
                    document.body,
                    document.documentElement
                ];
                
                // Also check main content containers that might cover the viewport
                const mainContainers = document.querySelectorAll('main, [role="main"], #root, #app, .app, .page, .container');
                for (const container of mainContainers) {
                    elements.push(container);
                }
                
                for (const el of elements) {
                    if (!el) continue;
                    
                    const style = getComputedStyle(el);
                    const bg = style.backgroundColor;
                    
                    // Skip transparent/none - we want the actual color
                    if (bg && bg !== 'rgba(0, 0, 0, 0)' && bg !== 'transparent' && bg !== 'initial' && bg !== 'inherit') {
                        return bg;
                    }
                }
                
                // Default to white (most common web default)
                return 'rgb(255, 255, 255)';
            }
            
            // Track last sent color to avoid redundant updates
            let lastSentColor = '';
            let transitionTimeout = null;
            
            function sendColorUpdate() {
                const color = getBackgroundColor();
                
                // Only send if color actually changed
                if (color !== lastSentColor) {
                    lastSentColor = color;
                    
                    try {
                        if (window.webkit?.messageHandlers?.backgroundColorUpdate) {
                            window.webkit.messageHandlers.backgroundColorUpdate.postMessage({
                                color: color,
                                timestamp: Date.now()
                            });
                        }
                    } catch (error) {
                        // Silent fallback - no console spam
                        window._klarBackgroundColor = { color: color, timestamp: Date.now() };
                    }
                }
            }
            
            // Smart transition-aware update function
            function scheduleTransitionAwareUpdate() {
                // Clear any existing timeout
                if (transitionTimeout) {
                    clearTimeout(transitionTimeout);
                }
                
                // Check immediately for non-transitioning changes
                const immediateColor = getBackgroundColor();
                
                // Detect transition duration from relevant elements
                const elements = [document.body, document.documentElement];
                let maxTransitionDuration = 0;
                
                for (const el of elements) {
                    if (!el) continue;
                    
                    const style = getComputedStyle(el);
                    const transition = style.transition || style.webkitTransition;
                    
                    if (transition && transition !== 'none' && transition.includes('background')) {
                        // Extract duration from transition (e.g., "background-color 0.3s ease")
                        const durationMatch = transition.match(/([0-9.]+)(s|ms)/);
                        if (durationMatch) {
                            const value = parseFloat(durationMatch[1]);
                            const unit = durationMatch[2];
                            const durationMs = unit === 's' ? value * 1000 : value;
                            maxTransitionDuration = Math.max(maxTransitionDuration, durationMs);
                        }
                    }
                }
                
                if (maxTransitionDuration > 0) {
                    // Wait for the actual transition duration, then check color
                    transitionTimeout = setTimeout(() => {
                        sendColorUpdate();
                        transitionTimeout = null;
                    }, maxTransitionDuration + 50); // Add 50ms buffer for completion
                } else {
                    // No transition detected, update immediately
                    sendColorUpdate();
                }
            }
            
            // Initial detection
            sendColorUpdate();
            
            // Watch for changes - only track essential mutations
            if (document.body) {
                // Debounce observer callbacks to avoid excessive getComputedStyle calls
                let observerRafPending = false;

                const observer = new MutationObserver((mutations) => {
                    let hasRelevantChange = false;

                    for (const mutation of mutations) {
                        // Only care about style/class changes on body, html, or main containers
                        if (mutation.type === 'attributes') {
                            const target = mutation.target;
                            const attr = mutation.attributeName;

                            if ((attr === 'style' || attr === 'class') &&
                                (target === document.body || target === document.documentElement ||
                                 target.matches('main, [role="main"], #root, #app, .app'))) {
                                hasRelevantChange = true;
                                break;
                            }
                        }
                        // Watch for style element changes in head
                        else if (mutation.type === 'childList') {
                            const hasStyleChanges = Array.from(mutation.addedNodes).some(node =>
                                node.tagName === 'STYLE' || node.tagName === 'LINK'
                            ) || Array.from(mutation.removedNodes).some(node =>
                                node.tagName === 'STYLE' || node.tagName === 'LINK'
                            );

                            if (hasStyleChanges) {
                                hasRelevantChange = true;
                                break;
                            }
                        }
                    }

                    if (hasRelevantChange && !observerRafPending) {
                        observerRafPending = true;
                        requestAnimationFrame(() => {
                            observerRafPending = false;
                            scheduleTransitionAwareUpdate();
                        });
                    }
                });

                // Watch body and html for changes
                observer.observe(document.body, {
                    attributes: true,
                    attributeFilter: ['class', 'style'],
                    childList: false,
                    subtree: false
                });

                observer.observe(document.documentElement, {
                    attributes: true,
                    attributeFilter: ['class', 'style'],
                    childList: false,
                    subtree: false
                });

                // Watch head for stylesheet changes (only direct children, not subtree)
                if (document.head) {
                    observer.observe(document.head, {
                        childList: true,
                        subtree: false
                    });
                }

                // Cleanup on page unload
                window.addEventListener('beforeunload', () => {
                    observer.disconnect();
                    if (transitionTimeout) {
                        clearTimeout(transitionTimeout);
                    }
                }, { passive: true });
            }
            
            // Add transition end listeners for immediate detection when transitions complete
            const transitionElements = [document.body, document.documentElement];
            transitionElements.forEach(element => {
                if (element) {
                    element.addEventListener('transitionend', (event) => {
                        // Only care about background-related transitions
                        if (event.propertyName.includes('background') || event.propertyName === 'all') {
                            sendColorUpdate();
                        }
                    }, { passive: true });
                }
            });
            
            // System theme changes
            if (window.matchMedia) {
                const darkModeQuery = window.matchMedia('(prefers-color-scheme: dark)');
                const lightModeQuery = window.matchMedia('(prefers-color-scheme: light)');
                
                darkModeQuery.addEventListener('change', scheduleTransitionAwareUpdate);
                lightModeQuery.addEventListener('change', scheduleTransitionAwareUpdate);
            }
            
            // Handle navigation from cache
            window.addEventListener('pageshow', (event) => {
                // Always check color when page is shown (including from cache)
                setTimeout(sendColorUpdate, 10);
            }, { passive: true });
        })();
        """
    }
    
    // MARK: - Color Utilities
    
    /// Parse RGB/RGBA color string to SwiftUI Color
    static func parseColor(_ colorString: String) -> Color {
        let trimmed = colorString.trimmingCharacters(in: .whitespacesAndNewlines)
        
        // Handle rgb(r, g, b) format
        if trimmed.hasPrefix("rgb(") {
            let rgbPart = String(trimmed.dropFirst(4).dropLast(1)) // Remove "rgb(" and ")"
            let components = rgbPart.split(separator: ",").map { 
                Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 
            }
            
            if components.count >= 3 {
                return Color(.sRGB, 
                           red: components[0] / 255.0,
                           green: components[1] / 255.0, 
                           blue: components[2] / 255.0,
                           opacity: 1.0)
            }
        }
        
        // Handle rgba(r, g, b, a) format
        if trimmed.hasPrefix("rgba(") {
            let rgbaPart = String(trimmed.dropFirst(5).dropLast(1)) // Remove "rgba(" and ")"
            let components = rgbaPart.split(separator: ",").map { 
                Double($0.trimmingCharacters(in: .whitespaces)) ?? 0 
            }
            
            if components.count >= 4 {
                return Color(.sRGB,
                           red: components[0] / 255.0,
                           green: components[1] / 255.0,
                           blue: components[2] / 255.0,
                           opacity: components[3])
            }
        }
        
        // Handle hex colors
        if trimmed.hasPrefix("#") {
            return hexToColor(trimmed)
        }
        
        // Fallback to black
        return Color.black
    }
    
    /// Convert Color to hex string
    static func colorToHex(_ color: Color) -> String {
        let nsColor = NSColor(color)
        guard let rgbColor = nsColor.usingColorSpace(.sRGB) else {
            return "#000000"
        }
        
        let red = Int(rgbColor.redComponent * 255)
        let green = Int(rgbColor.greenComponent * 255)
        let blue = Int(rgbColor.blueComponent * 255)
        
        return String(format: "#%02X%02X%02X", red, green, blue)
    }
    
    static func hexToColor(_ hex: String) -> Color {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (1, 1, 1, 0)
        }
        
        return Color(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}

extension WKWebView {
    /// What the web view shows where the page hasn't drawn yet. As it widens
    /// (the sidebar closing, the window growing), the page lays out for the
    /// new width a frame or two later, and until then WebKit fills the strip
    /// past its right edge with the system's control background: a dark band
    /// in dark mode. In the page's own color the edge holds. Private
    /// (`_setBackgroundColor:`): `underPageBackgroundColor`
    /// doesn't reach that strip, and `drawsBackground` off would also show
    /// through pages that have no background of their own, where this leaves
    /// them white.
    func setUndrawnAreaColor(_ color: Color) {
        let selector = NSSelectorFromString("_setBackgroundColor:")
        guard responds(to: selector) else { return }
        perform(selector, with: NSColor(color))
    }
}
