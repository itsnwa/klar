import SwiftUI

/// The overview's Explore list (`SidebarLibraryList.explore`): every page Explore with AI made, here or on
/// another Mac, newest first. Opening one shows its page, the list staying open; the page on screen is marked.
struct ExploreListView: View {
    @EnvironmentObject var tabManager: TabManager
    @ObservedObject private var library = ExploreLibrary.shared

    var body: some View {
        let collection = library.collection
        if collection.isEmpty {
            VStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 20))
                    .foregroundStyle(.tertiary)
                Text("Pages Explore with AI makes are kept here. Ask about a page from ⌘K.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(collection) { answer in
                        ExploreAnswerRow(answer: answer, isShown: isShown(answer)) { inBackground in
                            _ = tabManager.openFromLibrary(url: answer.pageURL, inBackground: inBackground)
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, SidebarLayoutMetrics.contentEdgeInset)
                .padding(.bottom, SidebarLayoutMetrics.contentBottomInsideSeparator)
            }
            // Its top line right under the list's header
            .sidebarScrollEdgeSeparators(topInset: 0)
        }
    }

    private func isShown(_ answer: ExplorePage.Answer) -> Bool {
        tabManager.activeTab?.url.contains(answer.id.uuidString) == true
    }
}

/// A page Explore made: the first sites' icons, its heading, what it is and when.
struct ExploreAnswerLabel: View {
    let answer: ExplorePage.Answer
    var lineLimit = 2

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            ExploreIconStack(sites: answer.sites)
            VStack(alignment: .leading, spacing: 2) {
                Text(answer.heading)
                    .font(.system(size: 12))
                    .lineLimit(lineLimit)
                Text("\(answer.question.eyebrow) · \(answer.date.formatted(.relative(presentation: .named)))")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }
}

/// Up to three sites' icons, overlapping
private struct ExploreIconStack: View {
    let sites: [ExplorePage.Site]

    var body: some View {
        ZStack(alignment: .leading) {
            ForEach(Array(sites.prefix(3).enumerated()), id: \.offset) { index, site in
                FaviconView(url: site.url, size: 12)
                    .frame(width: 16, height: 16)
                    .background(Circle().fill(.background))
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 0.5))
                    .offset(x: CGFloat(index) * 8)
                    .zIndex(Double(3 - index))
            }
        }
        .frame(width: 32, height: 16, alignment: .leading)
        .padding(.top, 1)
    }
}

/// A row of the list, highlighted under the pointer and while its page is on screen
private struct ExploreAnswerRow: View {
    let answer: ExplorePage.Answer
    let isShown: Bool
    let open: (_ inBackground: Bool) -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: { open(false) }) {
            ExploreAnswerLabel(answer: answer)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(isShown ? 0.1 : isHovering ? 0.06 : 0)))
        .onHover { hovering in
            if isHovering != hovering {
                isHovering = hovering
            }
        }
        .contextMenu {
            ExploreAnswerMenu(answer: answer, open: open)
        }
    }
}

/// An Explore page's context menu, in the list and on the overview's card
struct ExploreAnswerMenu: View {
    let answer: ExplorePage.Answer
    let open: (_ inBackground: Bool) -> Void

    var body: some View {
        Button("Open") { open(false) }
        Button("Open in Background") { open(true) }
        Button("Open \(ExplorePage.displayHost(of: answer.source))") {
            BrowserWindowSession.current.tabManager.createNewTab(url: answer.source)
        }
        Divider()
        Button("Delete", role: .destructive) {
            ExploreLibrary.shared.delete(answer.id)
        }
    }
}
