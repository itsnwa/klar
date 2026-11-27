import AppKit

final class SidebarHistoryRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarHistoryRowView")
    static let height: CGFloat = 44

    private let faviconView = FaviconImageView(frame: .zero)
    private let titleField = NSTextField(labelWithString: "")
    /// The site and the time of the last visit; the day is in the header.
    private let detailField = NSTextField(labelWithString: "")

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
        faviconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        faviconView.contentTintColor = .secondaryLabelColor
        addSubview(faviconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.lineBreakMode = .byTruncatingTail
        titleField.font = NSFont.systemFont(ofSize: 13)
        titleField.textColor = .labelColor
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        detailField.translatesAutoresizingMaskIntoConstraints = false
        detailField.lineBreakMode = .byTruncatingTail
        detailField.font = NSFont.systemFont(ofSize: 11)
        detailField.textColor = .secondaryLabelColor
        detailField.cell?.usesSingleLineMode = true
        addSubview(detailField)

        textField = titleField
        imageView = faviconView

        NSLayoutConstraint.activate([
            faviconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.iconLeading),
            faviconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            faviconView.widthAnchor.constraint(equalToConstant: 16),
            faviconView.heightAnchor.constraint(equalToConstant: 16),

            // The two lines (16 + 14pt) centered in the row
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.titleLeading),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarLibraryMetrics.trailing),
            titleField.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            detailField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            detailField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            detailField.topAnchor.constraint(equalTo: titleField.bottomAnchor)
        ])
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTints(backgroundStyle == .emphasized) }
    }

    private func applyTints(_ selected: Bool) {
        titleField.textColor = selected ? .white : .labelColor
        detailField.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    func configure(with entry: HistoryEntryData) {
        titleField.stringValue = entry.title.isEmpty ? entry.url : entry.title
        let site: String
        if let host = URL(string: entry.url)?.host {
            site = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        } else {
            site = entry.url
        }
        detailField.stringValue = "\(site) · \(entry.visitedAt.formatted(date: .omitted, time: .shortened))"
        loadFavicon(for: entry.url)
    }

    private func loadFavicon(for url: String) {
        faviconURL = url
        faviconTask?.cancel()
        faviconTask = Task { [weak self] in
            let image = await FaviconCacheManager.shared.getFavicon(for: url)
            await MainActor.run { [weak self] in
                // Cancelling doesn't stop the lookup: the row would get the
                // icon of the entry it showed before it was reused.
                guard let self = self, !Task.isCancelled else { return }
                if let image = image {
                    self.faviconView.image = image
                    self.faviconView.contentTintColor = nil
                }
            }
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if let faviconURL { loadFavicon(for: faviconURL) }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        faviconTask?.cancel()
        faviconTask = nil
        faviconURL = nil
        faviconView.image = NSImage(systemSymbolName: "globe", accessibilityDescription: nil)
        faviconView.contentTintColor = .secondaryLabelColor
        backgroundStyle = .normal
    }

    deinit {
        faviconTask?.cancel()
    }
}

/// A day's header in the History list, in the overview's section style.
final class SidebarHistoryDayHeaderView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarHistoryDayHeaderView")
    static let height: CGFloat = 30
    /// From the label's bottom to the row's: the rest of the row is space
    /// above the label, between one day and the next.
    static let bottomInset: CGFloat = 5

    private let titleField = NSTextField(labelWithString: "")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = .secondaryLabelColor
        titleField.lineBreakMode = .byTruncatingTail
        addSubview(titleField)
        textField = titleField
        NSLayoutConstraint.activate([
            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.iconLeading),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarLibraryMetrics.trailing),
            titleField.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Self.bottomInset)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func configure(title: String) {
        titleField.stringValue = title
    }
}
