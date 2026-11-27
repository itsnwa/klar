import Foundation

extension ExplorePage {
    /// What can be asked about a page.
    nonisolated enum Question: String, CaseIterable, Codable {
        case similarSites = "similar-sites"
        case discussions
        case otherSources = "other-sources"

        /// In ⌘K's list
        var title: String {
            switch self {
            case .similarSites: return "Find Sites Like This"
            case .discussions: return "Find Discussions of This Page"
            case .otherSources: return "Find Other Sources on This"
            }
        }

        var subtitle: String {
            switch self {
            case .similarSites: return "Alternatives, and sites you’d also like"
            case .discussions: return "Hacker News, Reddit, forums and blogs"
            case .otherSources: return "Other publications, the original source, other takes"
            }
        }

        var symbol: String {
            switch self {
            case .similarSites: return "square.grid.2x2"
            case .discussions: return "bubble.left.and.bubble.right"
            case .otherSources: return "newspaper"
            }
        }

        /// Above the heading
        var eyebrow: String {
            switch self {
            case .similarSites: return "Sites like this"
            case .discussions: return "Discussions"
            case .otherSources: return "Other sources"
            }
        }

        /// The page's heading, about the page asked about: its site by name (from the page's head), else
        /// its address's host
        func heading(source: String, title: String, siteName: String?) -> String {
            switch self {
            case .similarSites: return "Sites like \(siteName ?? ExplorePage.displayHost(of: source))"
            case .discussions: return "Discussions of “\(title)”"
            case .otherSources: return "Other sources on “\(title)”"
            }
        }

        /// What the AI is asked to find
        var task: String {
            switch self {
            case .similarSites:
                return "Find 8 websites like this page's site: alternatives to it, and sites someone who uses it would also like. For a blog, newsletter or shop hosted on a platform (Tumblr, Substack, Medium, Shopify…), sites like that blog or shop, not the platform. Not the site itself or pages of it. Link each site's home page."
            case .discussions:
                return "Find where people discuss this page or what it's about: threads on Hacker News, Reddit, Lobsters, forums, and blog posts replying to it. Up to 8, the most substantial first. name: the thread's title and where it is, such as “Show HN: … (Hacker News)”. If there's none about this page itself, find discussions of its subject."
            case .otherSources:
                return "Find up to 8 other sources on what this page is about: articles from other publications, the original source it's based on, and ones with a different view. Not pages from this page's own site."
            }
        }
    }

    nonisolated struct Site: Codable, Equatable {
        var name: String
        var url: String
        var description: String
    }

    /// An answer, or why there's none (`error`, kept only in memory).
    nonisolated struct Answer: Codable, Equatable, Identifiable {
        let id: UUID
        let question: Question
        let source: String
        let sourceTitle: String
        /// The site's own name, from the page's head (`og:site_name`…), when it has one
        var siteName: String?
        let provider: String
        let date: Date
        var sites: [Site]
        var error: String?

        var heading: String {
            question.heading(source: source, title: sourceTitle, siteName: siteName)
        }

        /// Its page's address
        var pageURL: String {
            ExplorePage.url(for: question, source: source, title: sourceTitle, siteName: siteName, id: id)
        }
    }
}
