import SwiftUI

/// The pages an answer links to, as a row of cards under it: the page's
/// sharing image (or its site's icon on a color of its own), title and site.
/// A card's page is only fetched as the card is about to show (`load`).
struct LinkCardsView: View {
    let links: [MarkdownLink]
    let previews: [URL: LinkPreview]
    /// Leading inset, so the first card lines up with the answer while the
    /// row scrolls out to the panel's edge
    let inset: CGFloat
    let load: (URL) async -> Void
    let open: (URL, _ inBackground: Bool) -> Void

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(spacing: 8) {
                ForEach(links) { link in
                    LinkCard(link: link, preview: previews[link.url], open: open)
                        .task {
                            await load(link.url)
                        }
                }
            }
            .padding(.horizontal, inset)
        }
        .scrollIndicators(.never)
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .padding(.horizontal, -inset)
    }
}

private struct LinkCard: View {
    let link: MarkdownLink
    let preview: LinkPreview?
    let open: (URL, _ inBackground: Bool) -> Void
    @State private var isHovered = false

    static let width: CGFloat = 184
    static let imageHeight: CGFloat = 96
    private static let textHeight: CGFloat = 62
    private static let cornerRadius: CGFloat = 12

    private var host: String {
        let host = link.url.host() ?? link.url.absoluteString
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    private var siteName: String {
        preview?.siteName ?? host
    }

    /// The page's title without its site's name around it ("GitHub - …",
    /// "… | The Verge"), else the answer's text for the link: a site that
    /// gives a fetch without cookies a page of its own (Reddit) has just
    /// its name for a title.
    private var title: String {
        if let title = preview?.title.map(trimmingSiteName), !title.isEmpty, !isJustTheSite(title) {
            return title
        }
        if !link.title.isEmpty {
            return link.title
        }
        let path = link.url.path()
        return path.count > 1 ? host + path : host
    }

    private func trimmingSiteName(from title: String) -> String {
        var title = title
        for name in [siteName, host] {
            for separator in [" - ", " | ", " · ", " – ", " — ", ": "] {
                if title.lowercased().hasPrefix((name + separator).lowercased()) {
                    title = String(title.dropFirst(name.count + separator.count))
                }
                if title.lowercased().hasSuffix((separator + name).lowercased()) {
                    title = String(title.dropLast(name.count + separator.count))
                }
            }
        }
        return title.trimmingCharacters(in: .whitespaces)
    }

    private func isJustTheSite(_ title: String) -> Bool {
        func simplified(_ text: some StringProtocol) -> String {
            text.lowercased().filter { $0.isLetter || $0.isNumber }
        }
        let title = simplified(title)
        return title == simplified(siteName) || title == simplified(host)
            || host.split(separator: ".").contains { simplified($0) == title }
    }

    var body: some View {
        Button {
            open(link.url, NSEvent.modifierFlags.contains(.command))
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                artwork
                    .frame(width: Self.width, height: Self.imageHeight)
                    .clipped()

                VStack(alignment: .leading, spacing: 0) {
                    Text(title)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Spacer(minLength: 4)
                    HStack(spacing: 5) {
                        if let icon = preview?.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .interpolation(.high)
                                .frame(width: 12, height: 12)
                                .clipShape(FaviconStyle.clipShape)
                        }
                        Text(siteName)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .frame(width: Self.width, height: Self.textHeight, alignment: .topLeading)
            }
            .background(Color.primary.opacity(isHovered ? 0.09 : 0.05))
            .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
                    .strokeBorder(Color.primary.opacity(isHovered ? 0.16 : 0.08), lineWidth: 0.5)
            }
            .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(link.url.absoluteString)
        .pointerStyle(.link)
        .onHover { hovering in
            if isHovered != hovering {
                isHovered = hovering
            }
        }
        .animation(.easeOut(duration: 0.15), value: isHovered)
        .contextMenu {
            Button("Open in New Tab") { open(link.url, false) }
            Button("Open in Background") { open(link.url, true) }
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.url.absoluteString, forType: .string)
            }
        }
    }

    @ViewBuilder
    private var artwork: some View {
        if let image = preview?.image {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .transition(.opacity)
        } else {
            // The site's icon on a color of its own, the same every time
            let hue = Self.hue(for: host)
            ZStack {
                LinearGradient(
                    colors: [
                        Color(hue: hue, saturation: 0.55, brightness: 0.85).opacity(0.55),
                        Color(hue: (hue + 0.12).truncatingRemainder(dividingBy: 1), saturation: 0.6, brightness: 0.6).opacity(0.45),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                if let icon = preview?.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                        .clipShape(FaviconStyle.clipShape)
                        .shadow(color: .black.opacity(0.2), radius: 4, y: 1)
                } else {
                    Text(host.prefix(1).uppercased())
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
        }
    }

    /// 0–1, from the host's FNV-1a hash
    private static func hue(for host: String) -> Double {
        var hash: UInt32 = 2166136261
        for byte in host.utf8 {
            hash = (hash ^ UInt32(byte)) &* 16777619
        }
        return Double(hash % 360) / 360
    }
}
