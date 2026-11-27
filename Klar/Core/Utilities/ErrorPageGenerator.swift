import Foundation

struct ErrorPageGenerator {
    
    enum ErrorType {
        case connectionRefused
        case connectionTimeout
        case hostNotFound
        case noInternet
        case sslError
        case fileNotFound
        /// The page's web process ended again soon after a reload.
        case pageCrashed(hasFeatureFlags: Bool)
        case generic(String)
        
        var title: String {
            switch self {
            case .connectionRefused:
                return "Unable to Connect"
            case .connectionTimeout:
                return "Connection Timeout"
            case .hostNotFound:
                return "Server Not Found"
            case .noInternet:
                return "No Internet Connection"
            case .sslError:
                return "Secure Connection Failed"
            case .fileNotFound:
                return "File Not Found"
            case .pageCrashed:
                return "This Page Keeps Crashing"
            case .generic:
                return "Page Load Failed"
            }
        }
        
        var message: String {
            switch self {
            case .connectionRefused:
                return "The server refused the connection. This might be because the service isn't running or the port is blocked."
            case .connectionTimeout:
                return "The server took too long to respond. Please check your connection and try again."
            case .hostNotFound:
                return "The server could not be found. Please check the URL and try again."
            case .noInternet:
                return "Please check your internet connection and try again."
            case .sslError:
                return "There was a problem establishing a secure connection to the server."
            case .fileNotFound:
                return "The requested file could not be found on this system."
            case .pageCrashed:
                return "WebKit stopped this page more than once while showing it, so Klar didn't load it again."
            case .generic(let description):
                return description
            }
        }
        
        var suggestions: [String] {
            switch self {
            case .connectionRefused:
                return [
                    "Check if the service is running on the expected port",
                    "Verify the URL is correct",
                    "Try again later"
                ]
            case .connectionTimeout:
                return [
                    "Check your internet connection",
                    "Try reloading the page",
                    "Contact the website administrator if the problem persists"
                ]
            case .hostNotFound:
                return [
                    "Check the spelling of the URL",
                    "Try using a different DNS server",
                    "Check if the website is temporarily down"
                ]
            case .noInternet:
                return [
                    "Check your Wi-Fi or ethernet connection",
                    "Try visiting other websites to test connectivity",
                    "Contact your internet service provider if needed"
                ]
            case .sslError:
                return [
                    "The site's certificate may be invalid, expired, or self-signed",
                    "Check that the URL uses the correct protocol (https/http)",
                    "If this is a local device (like a router), you may proceed anyway"
                ]
            case .fileNotFound:
                return [
                    "Check the file path is correct",
                    "Verify the file exists at the specified location",
                    "Check file permissions"
                ]
            case .pageCrashed(let hasFeatureFlags):
                return (hasFeatureFlags ? ["Turn off the WebKit features you turned on in Settings › Feature Flags"] : []) + [
                    "Try reloading the page",
                    "Try again later"
                ]
            case .generic:
                return [
                    "Try reloading the page",
                    "Check your internet connection",
                    "Try again later"
                ]
            }
        }
    }
    
    static func generateErrorPage(for url: String, errorType: ErrorType) -> String {
        return """
        <!DOCTYPE html>
        <html lang="en">
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <title>\(errorType.title)</title>
            <style>
                * {
                    margin: 0;
                    padding: 0;
                    box-sizing: border-box;
                }
                
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', system-ui, sans-serif;
                    background: #fff;
                    color: #1d1d1f;
                    min-height: 100vh;
                    display: flex;
                    align-items: center;
                    justify-content: center;
                    padding: 24px;
                }
                
                @media (prefers-color-scheme: dark) {
                    body {
                        background: #000;
                        color: #f2f2f7;
                    }
                }
                
                .error-container {
                    max-width: 600px;
                }
                
                .error-title {
                    font-size: 24px;
                    font-weight: 600;
                    margin-bottom: 12px;
                    color: #1d1d1f;
                }
                
                @media (prefers-color-scheme: dark) {
                    .error-title {
                        color: #f2f2f7;
                    }
                }
                
                .error-url {
                    font-family: 'SF Mono', Monaco, 'Cascadia Code', monospace;
                    font-size: 13px;
                    color: #8e8e93;
                    background: #f2f2f2;
                    padding: 16px 24px;
                    border-radius: 8px;
                    margin-bottom: 32px;
                    word-break: break-all;
                }
                
                @media (prefers-color-scheme: dark) {
                    .error-url {
                        color: #8e8e93;
                        background: #1c1c1c;
                    }
                }
                
                .error-message {
                    font-size: 16px;
                    line-height: 1.5;
                    color: #6e6e73;
                    margin-bottom: 32px;
                }
                
                @media (prefers-color-scheme: dark) {
                    .error-message {
                        color: #8e8e93;
                    }
                }
                
                .suggestions {
                    text-align: left;
                    margin-bottom: 32px;
                }
                
                .suggestions h3 {
                    font-size: 16px;
                    font-weight: 600;
                    margin-bottom: 16px;
                    color: #1d1d1f;
                }
                
                @media (prefers-color-scheme: dark) {
                    .suggestions h3 {
                        color: #f2f2f7;
                    }
                }
                
                .suggestions ul {
                    list-style: none;
                    padding: 0;
                }
                
                .suggestions li {
                    padding: 4px 0;
                    font-size: 13px;
                    color: #6e6e73;
                    position: relative;
                    padding-left: 12px;
                }
                
                @media (prefers-color-scheme: dark) {
                    .suggestions li {
                        color: #8e8e93;
                    }
                }
                
                .suggestions li:before {
                    content: "•";
                    color: currentColor;
                    font-weight: bold;
                    position: absolute;
                    left: 0;
                }
                
                .actions {
                    display: flex;
                    gap: 12px;
                    justify-content: space-between;
                    flex-wrap: wrap;
                }
                
                .btn {
                    padding: 8px 12px;
                    border-radius: 12px;
                    font-size: 13px;
                    font-weight: 600;
                    text-decoration: none;
                    border: none;
                    cursor: pointer;
                    transition: all 0.2s ease;
                    display: inline-block;
                }
                
                .btn-primary {
                    background: #007aff;
                    color: white;
                }
                
                .btn-primary:hover {
                    background: #0056b3;
                }
                
                .btn-secondary {
                    background: #f2f2f7;
                    color: #1d1d1f;
                    border: 1px solid #d1d1d6;
                }
                
                @media (prefers-color-scheme: dark) {
                    .btn-secondary {
                        background: #3a3a3c;
                        color: #f2f2f7;
                        border-color: #48484a;
                    }
                }
                
                .btn-secondary:hover {
                    background: #e5e5ea;
                }

                @media (prefers-color-scheme: dark) {
                    .btn-secondary:hover {
                        background: #48484a;
                    }
                }

                .warning-box {
                    background: rgba(255, 149, 0, 0.1);
                    border: 1px solid rgba(255, 149, 0, 0.3);
                    border-radius: 8px;
                    padding: 12px 16px;
                    margin-bottom: 24px;
                    font-size: 13px;
                    color: #86610a;
                }

                @media (prefers-color-scheme: dark) {
                    .warning-box {
                        background: rgba(255, 149, 0, 0.15);
                        border-color: rgba(255, 149, 0, 0.4);
                        color: #ffb340;
                    }
                }

                .btn-warning {
                    background: transparent;
                    color: #86610a;
                    border: 1px solid rgba(255, 149, 0, 0.5);
                }

                @media (prefers-color-scheme: dark) {
                    .btn-warning {
                        color: #ffb340;
                        border-color: rgba(255, 149, 0, 0.5);
                    }
                }

                .btn-warning:hover {
                    background: rgba(255, 149, 0, 0.15);
                }
            </style>
        </head>
        <body>
            <div class="error-container">
                <h1 class="error-title">\(errorType.title)</h1>
                <p class="error-message">\(escapeHTML(errorType.message))</p>
                <div class="error-url">\(escapeHTML(url))</div>

                <div class="suggestions">
                    <h3>Try these solutions</h3>
                    <ul>
                        \(errorType.suggestions.map { "<li>\($0)</li>" }.joined(separator: "\n                        "))
                    </ul>
                </div>

                \(generateSSLBypassSection(for: url, errorType: errorType))

                <div class="actions">
                  <button class="btn btn-secondary" onclick="history.back()">Go Back</button>
                  <button class="btn btn-primary" onclick="reloadPage()">Reload</button>
                </div>
            </div>
            <script>
                // The address as data, here only: in a button's onclick it
                // was decoded as HTML before it ran, so an address could end
                // the string it was in and run as script.
                const failedURL = \(javaScriptLiteral(url));
                function reloadPage() {
                    window.location.href = failedURL;
                }
                function proceedAnyway() {
                    if (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.sslBypass) {
                        window.webkit.messageHandlers.sslBypass.postMessage(failedURL);
                    }
                }
            </script>
        </body>
        </html>
        """
    }

    private static func generateSSLBypassSection(for url: String, errorType: ErrorType) -> String {
        guard case .sslError = errorType else { return "" }

        return """
                <div class="warning-box">
                    <strong>Proceed with caution:</strong> Bypassing this warning may expose your data to security risks. Only proceed if you trust this site or know why the certificate is invalid (e.g., local network devices with self-signed certificates).
                </div>
                <div class="actions" style="margin-bottom: 24px;">
                    <button class="btn btn-warning" onclick="proceedAnyway()">Proceed Anyway (Unsafe)</button>
                </div>
        """
    }
    
    static func determineErrorType(from error: Error, url: String) -> ErrorType {
        let nsError = error as NSError
        
        // Handle file URLs
        if url.hasPrefix("file://") {
            return .fileNotFound
        }
        
        // Handle URLError cases
        if nsError.domain == NSURLErrorDomain {
            switch nsError.code {
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return .connectionRefused
            case NSURLErrorTimedOut:
                return .connectionTimeout
            case NSURLErrorCannotFindHost, NSURLErrorDNSLookupFailed:
                return .hostNotFound
            case NSURLErrorNotConnectedToInternet:
                return .noInternet
            case NSURLErrorSecureConnectionFailed, NSURLErrorServerCertificateUntrusted:
                return .sslError
            default:
                return .generic(error.localizedDescription)
            }
        }
        
        return .generic(error.localizedDescription)
    }
    
    /// A string as text in the page: an address's `&param=` otherwise showed
    /// as `¶m=`, and one with a tag in it became part of the page.
    private static func escapeHTML(_ string: String) -> String {
        return string
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }

    /// A string as a JavaScript literal, quotes included, that can't end the
    /// script element it's written in.
    private static func javaScriptLiteral(_ string: String) -> String {
        guard let data = try? JSONEncoder().encode(string),
              let literal = String(data: data, encoding: .utf8) else { return "\"\"" }
        return literal.replacingOccurrences(of: "<", with: "\\u003C")
    }
} 
