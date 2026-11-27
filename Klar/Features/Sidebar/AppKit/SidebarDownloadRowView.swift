import AppKit
import Combine

final class SidebarDownloadRowView: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("SidebarDownloadRowView")
    static let height: CGFloat = 50

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let subtitleField = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    private var titleTop: NSLayoutConstraint!
    // The subtitle sits under the progress bar while there is one.
    private var subtitleBelowProgress: NSLayoutConstraint!
    private var subtitleBelowTitle: NSLayoutConstraint!

    private var cancellables: Set<AnyCancellable> = []
    private weak var download: DownloadItem?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        configureSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    private func configureSubviews() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown
        addSubview(iconView)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        // A file's extension is at its end
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.font = NSFont.systemFont(ofSize: 13)
        titleField.textColor = .labelColor
        titleField.cell?.usesSingleLineMode = true
        addSubview(titleField)

        subtitleField.translatesAutoresizingMaskIntoConstraints = false
        subtitleField.lineBreakMode = .byTruncatingTail
        subtitleField.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        subtitleField.textColor = .secondaryLabelColor
        subtitleField.cell?.usesSingleLineMode = true
        addSubview(subtitleField)

        progressIndicator.translatesAutoresizingMaskIntoConstraints = false
        progressIndicator.style = .bar
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
        progressIndicator.controlSize = .small
        progressIndicator.isHidden = true
        addSubview(progressIndicator)

        textField = titleField
        imageView = iconView

        titleTop = titleField.topAnchor.constraint(equalTo: topAnchor, constant: 10)
        subtitleBelowProgress = subtitleField.topAnchor.constraint(equalTo: progressIndicator.bottomAnchor, constant: 3)
        subtitleBelowTitle = subtitleField.topAnchor.constraint(equalTo: titleField.bottomAnchor)

        NSLayoutConstraint.activate([
            // A file's icon reads better larger than a favicon: centered
            // where a favicon would be.
            iconView.centerXAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.iconLeading + 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 26),
            iconView.heightAnchor.constraint(equalToConstant: 26),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: SidebarLibraryMetrics.titleLeading),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -SidebarLibraryMetrics.trailing),
            titleTop,

            progressIndicator.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            progressIndicator.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            progressIndicator.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 3),
            progressIndicator.heightAnchor.constraint(equalToConstant: 4),

            subtitleField.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleField.trailingAnchor.constraint(equalTo: titleField.trailingAnchor),
            subtitleBelowTitle
        ])
    }

    /// The lines (16 and 14pt, and the bar between them while there is
    /// one) centered in the row.
    private func setShowsProgress(_ showsProgress: Bool) {
        guard progressIndicator.isHidden == showsProgress else { return }
        progressIndicator.isHidden = !showsProgress
        titleTop.constant = showsProgress ? 5 : 10
        // Deactivate before activating so both are never active at once.
        if showsProgress {
            subtitleBelowTitle.isActive = false
            subtitleBelowProgress.isActive = true
        } else {
            subtitleBelowProgress.isActive = false
            subtitleBelowTitle.isActive = true
        }
    }

    private func setIndeterminate(_ indeterminate: Bool) {
        guard progressIndicator.isIndeterminate != indeterminate else { return }
        progressIndicator.isIndeterminate = indeterminate
        if indeterminate {
            progressIndicator.startAnimation(nil)
        } else {
            progressIndicator.stopAnimation(nil)
        }
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyTints(backgroundStyle == .emphasized) }
    }

    private func applyTints(_ selected: Bool) {
        titleField.textColor = selected ? .white : .labelColor
        subtitleField.textColor = selected ? NSColor.white.withAlphaComponent(0.8) : .secondaryLabelColor
    }

    func configure(with item: DownloadItem) {
        cancellables.removeAll()
        download = item
        iconView.image = item.systemIcon
        titleField.stringValue = item.filename

        item.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self, weak item] _ in
                guard let self = self, let item = item, self.download === item else { return }
                self.refresh(item: item)
            }
            .store(in: &cancellables)
        refresh(item: item)
    }

    private func refresh(item: DownloadItem) {
        switch item.state {
        case .downloading:
            setShowsProgress(true)
            // Without a Content-Length there's no telling how far along it is.
            setIndeterminate(!item.hasKnownSize)
            progressIndicator.doubleValue = item.progress
            subtitleField.stringValue = item.hasKnownSize
                ? "\(item.formattedDownloadedBytes) / \(item.formattedFileSize) — \(item.formattedDownloadSpeed)"
                : "\(item.formattedDownloadedBytes) — \(item.formattedDownloadSpeed)"
        case .paused:
            setShowsProgress(true)
            setIndeterminate(false)
            progressIndicator.doubleValue = item.progress
            subtitleField.stringValue = "Paused"
        case .completed:
            setShowsProgress(false)
            subtitleField.stringValue = item.formattedFileSize
        case .failed:
            setShowsProgress(false)
            subtitleField.stringValue = item.resumeData != nil ? "Interrupted" : "Failed"
        case .cancelled:
            setShowsProgress(false)
            subtitleField.stringValue = "Cancelled"
        }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        cancellables.removeAll()
        download = nil
        setIndeterminate(false)
        setShowsProgress(false)
        backgroundStyle = .normal
    }
}
