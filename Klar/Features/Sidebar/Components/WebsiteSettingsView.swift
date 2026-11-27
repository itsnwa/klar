import SwiftUI
import WebKit
import SecurityInterface

/// The gear at the end of the URL bar: the active page's connection and
/// certificate, its permissions (SitePermissionsManager), zoom and website
/// data.
struct WebsiteSettingsView: View {
    @EnvironmentObject var tabManager: TabManager
    @Environment(SidebarStateManager.self) private var sidebarStateManager
    @State private var showSettingsPopover = false
    /// Whether this view holds the floating sidebar open, so it lets go
    /// exactly once: when the popover closes, or when the view goes away
    /// with it open (⌘W on a space's last tab), where no change comes.
    @State private var isBlockingFloatingSidebar = false

    var body: some View {
        Button(action: {
            showSettingsPopover.toggle()
        }) {
            Image(systemName: "gear")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
        }
        .buttonStyle(.plain)
        .help("Website Settings")
        .popover(isPresented: $showSettingsPopover, arrowEdge: .leading) {
            if let tab = tabManager.activeTab {
                WebsiteSettingsPanel(tab: tab, tabManager: tabManager)
                    .id(tab.id)
            }
        }
        .onChange(of: showSettingsPopover) { _, isOpen in
            blockFloatingSidebar(isOpen)
        }
        .onDisappear {
            blockFloatingSidebar(false)
        }
    }

    private func blockFloatingSidebar(_ blocks: Bool) {
        guard blocks != isBlockingFloatingSidebar else { return }
        isBlockingFloatingSidebar = blocks
        if blocks {
            FloatingSidebarBlocker.shared.beginBlocking(sidebarStateManager)
        } else {
            FloatingSidebarBlocker.shared.endBlocking(sidebarStateManager)
        }
    }
}

// MARK: - Panel

private struct WebsiteSettingsPanel: View {
    @ObservedObject var tab: BrowserTab
    @StateObject private var model: WebsiteSettingsModel
    @ObservedObject private var permissions = SitePermissionsManager.shared
    @Environment(\.dismiss) private var dismiss

    init(tab: BrowserTab, tabManager: TabManager) {
        self.tab = tab
        _model = StateObject(wrappedValue: WebsiteSettingsModel(tab: tab, tabManager: tabManager))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            connectionNote

            if model.hasPermissions, let host = model.host {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Permissions")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)

                    PanelGroup {
                        ForEach(Array(SitePermission.allCases.enumerated()), id: \.element) { index, permission in
                            if index > 0 {
                                Divider().padding(.leading, 36)
                            }
                            permissionRow(permission, host: host)
                        }
                    }
                }
            }

            if model.isWebPage, model.hasWebView {
                PanelGroup {
                    PanelRow(symbol: "plus.magnifyingglass", title: "Zoom") {
                        ControlGroup {
                            Button { model.zoomOut() } label: {
                                Image(systemName: "minus")
                            }
                            .help("Zoom Out")
                            Button { model.resetZoom() } label: {
                                Text(model.zoomText)
                                    .monospacedDigit()
                            }
                            .help("Actual Size")
                            Button { model.zoomIn() } label: {
                                Image(systemName: "plus")
                            }
                            .help("Zoom In")
                        }
                        .controlSize(.small)
                        .fixedSize()
                    }
                    Divider().padding(.leading, 36)
                    PanelRow(symbol: "archivebox", title: "Cookies and website data") {
                        Button("Clear…") {
                            dismiss()
                            model.confirmClearWebsiteData()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 300)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Group {
                if let favicon = tab.favicon {
                    Image(nsImage: favicon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .clipShape(FaviconStyle.clipShape)
                } else {
                    Image(systemName: "globe")
                        .font(.system(size: 18))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(model.host ?? tab.title)
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                connectionLine
            }

            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var connectionLine: some View {
        if let connection = model.connection.presentation {
            if model.canShowCertificate {
                Button {
                    dismiss()
                    model.showCertificate()
                } label: {
                    HStack(spacing: 3) {
                        connectionLabel(connection)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .semibold))
                            .opacity(0.6)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show Certificate")
            } else {
                connectionLabel(connection)
            }
        } else {
            Text(tab.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func connectionLabel(_ connection: WebsiteSettingsModel.Connection.Presentation) -> some View {
        HStack(spacing: 4) {
            Image(systemName: connection.symbol)
                .font(.system(size: 9, weight: .bold))
            Text(connection.title)
                .lineLimit(1)
        }
        .font(.caption)
        .foregroundStyle(connection.color)
    }

    @ViewBuilder
    private var connectionNote: some View {
        switch model.connection {
        case .notSecure:
            PanelNote(color: .orange) {
                Text("Anything you type on this page, like passwords or card numbers, can be read by others on your network.")
            }
        case .mixedContent:
            PanelNote(color: .orange) {
                Text("Some of this page loads without encryption, so others on your network could see or change those parts.")
            }
        case .untrustedCertificate:
            PanelNote(color: .red) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("You chose to visit this site anyway. Klar trusts its certificate until you quit.")
                    Button("Stop Trusting") {
                        model.stopTrusting()
                    }
                    .controlSize(.small)
                }
            }
        case .secure, .localFile, .none:
            EmptyView()
        }
    }

    // MARK: Permissions

    private func permissionRow(_ permission: SitePermission, host: String) -> some View {
        PanelRow(symbol: permission.symbol, title: permission.title) {
            HStack(spacing: 8) {
                if model.isInUse(permission) {
                    HStack(spacing: 4) {
                        Circle().frame(width: 6, height: 6)
                        Text("In use")
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.green)
                }
                Picker(permission.title, selection: Binding(
                    get: { permissions.decision(for: permission, on: host) },
                    set: { model.setDecision($0, for: permission) }
                )) {
                    ForEach(SitePermissionDecision.allCases, id: \.self) { decision in
                        Text(decision.title).tag(decision)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .controlSize(.small)
                .fixedSize()
            }
        }
    }
}

// MARK: - Components

/// A rounded group of rows, as in Settings.
private struct PanelGroup<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            content
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct PanelRow<Accessory: View>: View {
    let symbol: String
    let title: String
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 8)
            accessory
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(minHeight: 32)
    }
}

private struct PanelNote<Content: View>: View {
    let color: Color
    @ViewBuilder var content: Content

    var body: some View {
        content
            .font(.caption)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

// MARK: - Model

/// What the panel shows of the tab's web view, kept up to date while it's
/// open.
@MainActor
private final class WebsiteSettingsModel: ObservableObject {
    enum Connection {
        case secure
        /// HTTPS, with parts of the page loaded over HTTP.
        case mixedContent
        case notSecure
        /// A certificate error the user chose to visit anyway (SSLBypassManager).
        case untrustedCertificate
        case localFile
        /// Klar's own pages, about:blank.
        case none

        struct Presentation {
            let symbol: String
            let title: String
            let color: Color
        }

        var presentation: Presentation? {
            switch self {
            case .secure: return Presentation(symbol: "lock.fill", title: "Secure connection", color: .secondary)
            case .mixedContent: return Presentation(symbol: "lock.trianglebadge.exclamationmark.fill", title: "Not fully secure", color: .orange)
            case .notSecure: return Presentation(symbol: "lock.slash.fill", title: "Not secure", color: .orange)
            case .untrustedCertificate: return Presentation(symbol: "lock.slash.fill", title: "Certificate not trusted", color: .red)
            case .localFile: return Presentation(symbol: "doc.fill", title: "File on this Mac", color: .secondary)
            case .none: return nil
            }
        }
    }

    @Published private(set) var connection: Connection = .none
    @Published private(set) var canShowCertificate = false
    @Published private(set) var isCameraInUse = false
    @Published private(set) var isMicrophoneInUse = false
    @Published private(set) var zoom: CGFloat = 1

    private let tab: BrowserTab
    private let tabManager: TabManager
    private weak var webView: WKWebView?
    private var observations: [NSKeyValueObservation] = []

    init(tab: BrowserTab, tabManager: TabManager) {
        self.tab = tab
        self.tabManager = tabManager
        webView = TabWebViewCoordinator.coordinator(for: tab.id)?.webView
        refresh()

        guard let webView else { return }
        let changed: @Sendable (WKWebView) -> Void = { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        observations = [
            webView.observe(\.url) { view, _ in changed(view) },
            webView.observe(\.serverTrust) { view, _ in changed(view) },
            webView.observe(\.hasOnlySecureContent) { view, _ in changed(view) },
            webView.observe(\.cameraCaptureState) { view, _ in changed(view) },
            webView.observe(\.microphoneCaptureState) { view, _ in changed(view) }
        ]
    }

    private var url: URL? {
        webView?.url ?? URL(string: tab.url)
    }

    var host: String? {
        url?.host?.lowercased()
    }

    var hasWebView: Bool {
        webView != nil
    }

    var isWebPage: Bool {
        url?.scheme == "https" || url?.scheme == "http"
    }

    /// Camera, microphone and location are only for secure pages.
    var hasPermissions: Bool {
        url.map(SitePermissionsManager.canAsk(from:)) ?? false
    }

    var zoomText: String {
        "\(Int((zoom * 100).rounded()))%"
    }

    func isInUse(_ permission: SitePermission) -> Bool {
        switch permission {
        case .camera: return isCameraInUse
        case .microphone: return isMicrophoneInUse
        case .location: return false
        }
    }

    private func refresh() {
        let connection: Connection
        switch url?.scheme {
        case "https":
            if let host, SSLBypassManager.shared.shouldBypassSSL(for: host) {
                connection = .untrustedCertificate
            } else if webView?.hasOnlySecureContent == false {
                connection = .mixedContent
            } else {
                connection = .secure
            }
        case "http": connection = .notSecure
        case "file": connection = .localFile
        default: connection = .none
        }
        setIfChanged(\.connection, connection)
        setIfChanged(\.canShowCertificate, url?.scheme == "https" && webView?.serverTrust != nil)
        setIfChanged(\.isCameraInUse, (webView?.cameraCaptureState ?? .none) != .none)
        setIfChanged(\.isMicrophoneInUse, (webView?.microphoneCaptureState ?? .none) != .none)
        setIfChanged(\.zoom, webView?.pageZoom ?? 1)
    }

    private func setIfChanged<Value: Equatable>(_ keyPath: ReferenceWritableKeyPath<WebsiteSettingsModel, Value>, _ value: Value) {
        if self[keyPath: keyPath] != value {
            self[keyPath: keyPath] = value
        }
    }

    // MARK: Actions

    /// Blocking stops a camera or microphone the page is using.
    func setDecision(_ decision: SitePermissionDecision, for permission: SitePermission) {
        guard let host else { return }
        SitePermissionsManager.shared.setDecision(decision, for: permission, on: host)
        guard decision == .block, let webView else { return }
        switch permission {
        case .camera: webView.setCameraCaptureState(.none, completionHandler: nil)
        case .microphone: webView.setMicrophoneCaptureState(.none, completionHandler: nil)
        case .location: break
        }
    }

    /// The certificate chain the page was loaded with, in a sheet on the
    /// window.
    func showCertificate() {
        guard let webView, let trust = webView.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let window = webView.presentationWindow else { return }
        // Once the popover has closed.
        DispatchQueue.main.async {
            SFCertificatePanel.shared().beginSheet(
                for: window,
                modalDelegate: nil,
                didEnd: nil,
                contextInfo: nil,
                certificates: certificates,
                showGroup: true
            )
        }
    }

    func stopTrusting() {
        guard let host else { return }
        SSLBypassManager.shared.removeBypass(for: host)
        refresh()
        webView?.reload()
    }

    // The tab's zoom commands; the coordinator applies them on the next turn
    // of the main queue.
    func zoomIn() {
        tabManager.zoomIn()
        refreshSoon()
    }

    func zoomOut() {
        tabManager.zoomOut()
        refreshSoon()
    }

    func resetZoom() {
        tabManager.resetZoom()
        refreshSoon()
    }

    private func refreshSoon() {
        DispatchQueue.main.async { [weak self] in
            self?.refresh()
        }
    }

    /// Asks, then removes the site's cookies, storage and caches from the
    /// tab's data store (its space's profile) and reloads the page. The
    /// popover, and this model, are gone by the time it's answered.
    func confirmClearWebsiteData() {
        guard let webView, let host else { return }
        let tabID = tab.id
        let alert = NSAlert()
        alert.messageText = "Clear cookies and website data for “\(host)”?"
        alert.informativeText = "You’ll be signed out of the site, and anything it stored on this Mac is removed."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")

        let answer: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .alertFirstButtonReturn else { return }
            Self.clearWebsiteData(of: host, in: webView, tabID: tabID)
        }
        DispatchQueue.main.async {
            if let window = webView.presentationWindow {
                alert.beginSheetModal(for: window, completionHandler: answer)
            } else {
                answer(alert.runModal())
            }
        }
    }

    /// The toast shows in the window of `tabID`
    private static func clearWebsiteData(of host: String, in webView: WKWebView, tabID: UUID) {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        Task { @MainActor in
            // Records are named by the site's registrable domain
            // ("bbc.co.uk" for www.bbc.co.uk).
            let records = await store.dataRecords(ofTypes: types).filter {
                host == $0.displayName || host.hasSuffix("." + $0.displayName)
            }
            await store.removeData(ofTypes: types, for: records)
            logInfo(.webView, "Cleared \(records.count) website data records for \(host)")
            webView.reload()
            NotificationCenter.default.post(
                name: NSNotification.Name("ShowToast"),
                object: nil,
                userInfo: [
                    "message": "Cleared website data for \(host)",
                    "type": "success",
                    "icon": "archivebox",
                    "tabId": tabID.uuidString
                ]
            )
        }
    }
}
