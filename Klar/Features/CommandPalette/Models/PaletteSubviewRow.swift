import Foundation

struct PaletteSubviewRow: Identifiable, Equatable {
    let id: String
    let title: String
    let subtitle: String?
    let systemIcon: String
    let kind: Kind

    enum Kind: Equatable {
        case commitHere
        case folder(UUID, hasSubfolders: Bool)
        case explore(ExplorePage.Question)
    }
}
