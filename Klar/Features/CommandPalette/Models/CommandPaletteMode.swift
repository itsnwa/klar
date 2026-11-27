import Foundation

enum CommandPaletteMode: Equatable {
    case normal
    case tabActions
    case subview(PaletteSubview)

    var isNormal: Bool {
        if case .normal = self { return true }
        return false
    }
}

struct PaletteSubview: Equatable {
    let id: PaletteSubviewID
    var frames: [PaletteSubviewFrame]

    var current: PaletteSubviewFrame { frames.last! }

    init(id: PaletteSubviewID, rootFrame: PaletteSubviewFrame) {
        self.id = id
        self.frames = [rootFrame]
    }
}

enum PaletteSubviewID: Equatable {
    case folderPicker(intent: FolderPickerIntent)
    /// Explore with AI's questions (ExplorePage)
    case explore
}

struct PaletteSubviewFrame: Equatable, Identifiable {
    let id: UUID
    let title: String
    let context: PaletteSubviewContext
}

enum PaletteSubviewContext: Equatable {
    case folder(parentID: UUID?)
    case explore
}

enum FolderPickerIntent: Equatable {
    case save
    case move
}
