import AppKit
import Combine

final class SidebarReadingListRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarReadingListRowView")

    /// Two lines (title, site), or three with Safari's preview text: 16, 14
    /// and 14pt, with the rest above and below.
    static func height(for item: ReadingListItem) -> CGFloat {
        hasPreview(item) ? 60 : 44
    }

    private static func hasPreview(_ item: ReadingListItem) -> Bool {
        item.previewText?.contains { !$0.isWhitespace } ?? false
    }

    private let faviconView = FaviconImageView(frame: .zero)
    private let unreadDot = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let previewField = NSTextField(labelWithString: "")
    private let domainField = NSTextField(labelWithString: "")

    private var titleTop: NSLayoutConstraint!
    // The domain sits under the preview line, or under the title when Safari
    // has no preview text for the page.
    private var domainBelowPreview: NSLayoutConstraint!
    private var domainBelowTitle: NSLayoutConstraint!

    private var faviconTask: Task<Void, Never>?
    private var faviconURL: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureSubviews() {
        faviconView.translatesAutoresizingMaskIntoConstraints = false
        faviconView.imageScaling = .scaleProportionallyUpOrDown
        faviconView.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        faviconView.contentTintColor = .secondaryLabelColor
        addSubview(faviconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .regular)
        titleField.textColor = .labelColor
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        // Trailing, so titles line up whether they're read or not.
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.wantsLayer = true
        unreadDot.layer?.cornerRadius = 3.5
        unreadDot.isHidden = true
        addSubview(unreadDot)

        previewField.translatesAutoresizingMaskIntoConstraints = false
        previewField.lineBreakMode = .byTruncatingTail
        previewField.font = NSFont.systemFont(ofSize: 11)
        previewField.textColor = .secondaryLabelColor
        previewField.cell?.usesSingleLineMode = true
        previewField.isHidden = true
        addSubview(previewField)

        domainField.translatesAutoresizingMaskIntoConstraints = false
        domainField.lineBreakMode = .byTruncatingTail
        domainField.font = NSFont.systemFont(ofSize: 11)
        domainField.textColor = .secondaryLabelColor
        domainField.cell?.usesSingleLineMode = true
        addSubview(domainField)

        textField = titleField
        imageView = faviconView

        titleTop = titleField.topAnchor.constraint(equalTo: topAnchor, constant: 7)
        domainBelowPreview = domainField.topAnchor.constraint(equalTo: previewField.bottomAnchor)
        domainBelowTitle = domainField.topAnchor.constraint(equalTo: titleField.bottomAnchor)

        NSLayoutConstraint.activate([
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.iconLeading),
            faviconView.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.titleLeading),
            titleField.trailingAnchor.constraint(equalTo: unreadDot.leadingAnchor, constant: -6),
            titleTop,

            unreadDot.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarLibraryMetrics.trailing),
            unreadDot.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 7),
            unreadDot.heightAnchor.constraint(equalToConstant: 7),

            previewField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            previewField.trailingAnchor.constraint(equalTo: unreadDot.trailingAnchor),
            previewField.topAnchor.constraint(equalTo: titleField.bottomAnchor),

            domainField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            domainField.trailingAnchor.constraint(equalTo: unreadDot.trailingAnchor),
            domainBelowTitle
        ])
        applyTints(false)
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTints(backgroundStyle == .emphasized) }
    }

    private func applyTints(_ selected: Bool) {
        titleField.textColor = selected ? .white : .labelColor
        previewField.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        domainField.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
        let dotColor: NSColor = selected ? .white : .controlAccentColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            self.unreadDot.layer?.backgroundColor = dotColor.cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyTints(backgroundStyle == .emphasized)
        if let faviconURL { loadFavicon(for: faviconURL) }
    }

    func configure(with item: ReadingListItem) {
        titleField.stringValue = item.title.isEmpty ? item.url : item.title
        titleField.font = NSFont.systemFont(ofSize: 13, weight: item.isUnread ? .medium : .regular)
        unreadDot.isHidden = !item.isUnread
        setAccessibilityLabel(item.isUnread ? "Unread, \(titleField.stringValue)" : nil)

        // Safari's preview text can span several paragraphs; show its start on one line.
        let hasPreview = Self.hasPreview(item)
        previewField.stringValue = hasPreview
            ? item.previewText?.split(whereSeparator: \.isWhitespace).joined(separator: " ") ?? ""
            : ""
        previewField.isHidden = !hasPreview
        // The lines centered in `height(for:)`. Deactivate before activating
        // so both are never active at once.
        titleTop.constant = hasPreview ? 8 : 7
        if hasPreview {
            domainBelowTitle.isActive = false
            domainBelowPreview.isActive = true
        } else {
            domainBelowPreview.isActive = false
            domainBelowTitle.isActive = true
        }

        if let host = URL(string: item.url)?.host {
            domainField.stringValue = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            domainField.stringValue = ""
        }

        loadFavicon(for: item.url)
    }

    private func loadFavicon(for url: String) {
        faviconURL = url
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            let image = await FaviconCacheManager.shared.getFavicon(for: url)
            await MainActor.run { [weak self] in
                // Cancelling doesn't stop the lookup: the row would get the
                // icon of the item it showed before it was reused.
                guard let self = self, !Task.isCancelled else { return }
                if let image = image {
                    self.faviconView.image = image
                    self.faviconView.contentTintColor = nil
                }
            }
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconTask?.cancel()
        faviconTask = nil
        faviconURL = nil
        faviconView.image = NSImage(systemSymbolName: "doc.richtext", accessibilityDescription: nil)
        faviconView.contentTintColor = .secondaryLabelColor
        unreadDot.isHidden = true
        backgroundStyle = .normal
    }

    deinit {
        faviconTask?.cancel()
    }
}
