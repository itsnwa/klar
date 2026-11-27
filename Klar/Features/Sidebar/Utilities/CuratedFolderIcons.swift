import Foundation
import AppKit

/// The SF Symbols and Klar's own icons that folders and spaces can have, in
/// the groups the icomoji picker shows them in.
nonisolated final class CuratedFolderIcons {

    /// A group of the picker's: its title, the symbol of its button in the
    /// picker's bar, and its icons.
    typealias Group = (title: String, symbol: String, names: [String])

    // MARK: - Curated Icons List

    /// Hand-picked SF Symbols for categorizing links. Every symbol a folder
    /// could pick once stays here, or its icon would no longer count as valid.
    static let symbolGroups: [Group] = [
        ("Work & Money", "briefcase.fill", [
            "briefcase.fill", "building.2.fill", "building.columns.fill", "storefront.fill", "dollarsign", "eurosign",
            "sterlingsign", "yensign", "bitcoinsign", "percent", "banknote.fill", "creditcard.fill", "giftcard.fill",
            "wallet.bifold.fill", "bag.fill", "handbag.fill", "cart.fill", "basket.fill", "tag.fill", "chart.bar.fill",
            "chart.pie.fill", "chart.line.uptrend.xyaxis", "gauge.with.needle.fill", "calendar", "clock.fill", "alarm.fill",
            "hourglass", "timer", "checklist", "list.bullet", "document.fill", "doc.text.fill", "paperclip", "link",
            "signature", "tray.fill", "tray.2.fill", "archivebox.fill", "shippingbox.fill", "truck.box.fill", "cube.fill",
            "megaphone.fill", "barcode"
        ]),
        ("Tech", "cpu.fill", [
            "cpu.fill", "memorychip.fill", "terminal.fill", "apple.terminal.fill", "curlybraces",
            "chevron.left.forwardslash.chevron.right", "desktopcomputer", "display", "laptopcomputer", "macbook",
            "macstudio.fill", "macpro.gen3.fill", "ipad", "iphone", "applewatch", "vision.pro.fill", "airpods.pro",
            "headphones", "headset", "keyboard.fill", "computermouse.fill", "printer.fill", "server.rack",
            "externaldrive.fill", "internaldrive.fill", "externaldrive.connected.to.line.below.fill", "icloud.fill",
            "network", "globe", "wifi", "wave.3.up", "cellularbars", "antenna.radiowaves.left.and.right",
            "personalhotspot", "bolt.horizontal.fill", "poweroutlet.type.b.fill", "batteryblock.stack.fill", "airtag.fill",
            "matter.logo", "gearshape.fill", "gearshape.2.fill", "magnifyingglass"
        ]),
        ("Privacy & Security", "lock.fill", [
            "lock.fill", "lock.shield.fill", "key.fill", "key.horizontal.fill", "key.2.on.ring.fill", "shield.fill",
            "shield.lefthalf.filled", "bolt.shield.fill", "touchid", "eye.fill", "eye.slash.fill", "hand.raised.fill"
        ]),
        ("Creative", "paintpalette.fill", [
            "paintpalette.fill", "swatchpalette.fill", "paintbrush.fill", "paintbrush.pointed.fill", "pencil",
            "pencil.and.ruler.fill", "ruler.fill", "compass.drawing", "scissors", "beziercurve", "scribble.variable",
            "lasso", "wand.and.sparkles", "wand.and.rays", "sparkles", "camera.fill", "camera.aperture", "camera.filters",
            "photo.fill", "photo.on.rectangle.angled", "photo.artframe", "text.below.photo.fill", "character",
            "textformat", "rotate.3d.fill", "rectangle.fill.on.rectangle.fill", "circle.hexagonpath.fill", "hammer.fill",
            "wrench.adjustable.fill", "screwdriver.fill", "wrench.and.screwdriver.fill"
        ]),
        ("Media & Games", "play.fill", [
            "play.fill", "pause.fill", "playpause.fill", "shuffle", "play.square.stack.fill", "play.tv.fill", "tv.fill",
            "video.fill", "film.fill", "film.stack.fill", "movieclapper.fill", "popcorn.fill", "theatermasks.fill",
            "ticket.fill", "music.note", "music.note.list", "music.mic", "guitars.fill", "pianokeys.inverse", "waveform",
            "speaker.wave.2.fill", "microphone.fill", "record.circle.fill", "recordingtape", "gamecontroller.fill",
            "formfitting.gamecontroller.fill", "arcade.stick.console.fill", "arcade.stick", "dpad.fill", "arrowkeys.fill",
            "playstation.logo", "xbox.logo", "xmark.triangle.circle.square.fill", "dice.fill", "puzzlepiece.fill",
            "suit.spade.fill"
        ]),
        ("People & Messages", "bubble.left.and.bubble.right.fill", [
            "person.fill", "person.2.fill", "person.3.fill", "person.crop.square.on.square.angled.fill",
            "figure.2.and.child.holdinghands", "brain.head.profile.fill", "hand.raised.palm.facing.fill", "hand.rays.fill",
            "hands.clap.fill", "hand.thumbsup.fill", "message.fill", "bubble.fill", "bubble.left.and.bubble.right.fill",
            "envelope.fill", "envelope.front.fill", "paperplane.fill", "phone.fill", "bell.fill", "at"
        ]),
        ("Learning", "graduationcap.fill", [
            "book.fill", "books.vertical.fill", "text.book.closed.fill", "magazine.fill", "newspaper.fill",
            "bookmark.fill", "graduationcap.fill", "studentdesk", "globe.desk.fill", "lightbulb.fill", "brain.fill",
            "atom", "flask.fill", "testtube.2", "microbe.fill", "function", "sum", "number", "plus.forwardslash.minus",
            "greaterthanorequalto", "infinity"
        ]),
        ("Home & Life", "house.fill", [
            "house.fill", "house.lodge.fill", "sofa.fill", "bed.double.fill", "lamp.table.fill", "lamp.floor.fill",
            "fan.fill", "washer.fill", "stroller.fill", "teddybear.fill", "fork.knife", "cup.and.heat.waves.fill",
            "cup.and.saucer.fill", "mug.fill", "wineglass.fill", "takeoutbag.and.cup.and.straw.fill", "carrot.fill",
            "birthday.cake.fill", "gift.fill", "party.popper.fill", "balloon.2.fill", "tshirt.fill", "jacket.fill",
            "coat.fill", "hat.cap.fill", "shoe.2.fill", "sunglasses.fill", "duffle.bag.fill", "umbrella.fill",
            "stethoscope", "cross.case.fill", "pills.fill", "syringe.fill", "heart.text.square.fill", "lungs.fill",
            "staroflife.fill"
        ]),
        ("Sports", "figure.run", [
            "figure.walk", "figure.run", "figure.hiking", "figure.climbing", "figure.yoga", "figure.mind.and.body",
            "figure.pool.swim", "figure.outdoor.cycle", "figure.roll", "figure.run.treadmill", "figure.skiing.downhill",
            "figure.surfing", "oar.2.crossed", "dumbbell.fill", "sportscourt.fill", "baseball.fill", "basketball.fill",
            "soccerball.inverse", "american.football.fill", "australian.football.fill", "tennis.racket",
            "tennisball.fill", "hockey.puck.fill", "skis.fill", "surfboard.fill", "snowboard.fill", "skateboard.fill",
            "bicycle", "helmet.fill", "trophy.fill", "medal.fill", "crown.fill", "flag.pattern.checkered",
            "flag.2.crossed.fill"
        ]),
        ("Travel", "airplane", [
            "airplane", "airplane.departure", "airplane.arrival", "car.fill", "car.side.fill", "car.rear.fill",
            "bus.fill", "tram.fill", "train.side.front.car", "cablecar.fill", "ferry.fill", "sailboat.fill",
            "motorcycle.fill", "moped.fill", "scooter", "tire", "suspension.shock", "fuelpump.fill", "ev.charger.fill",
            "location.fill", "mappin.and.ellipse", "map.fill", "signpost.right.fill",
            "point.bottomleft.forward.to.arrow.triangle.scurvepath.fill", "globe.europe.africa.fill",
            "globe.americas.fill", "binoculars.fill", "tent.fill", "beach.umbrella.fill", "mountain.2.fill"
        ]),
        ("Nature", "leaf.fill", [
            "sun.max.fill", "sun.horizon.fill", "moon.fill", "moon.stars.fill", "cloud.fill", "cloud.sun.fill",
            "rainbow", "snowflake", "flame.fill", "bolt.fill", "drop.fill", "water.waves", "leaf.fill", "tree.fill",
            "camera.macro", "fossil.shell.fill", "hare.fill", "dog.fill", "cat.fill", "tortoise.fill", "lizard.fill",
            "bird.fill", "fish.fill", "ant.fill", "ladybug.fill", "pawprint.fill"
        ]),
        ("Shapes", "star.fill", [
            "star.fill", "star.circle.fill", "sparkle", "heart.fill", "bolt.heart.fill", "seal.fill",
            "checkmark.seal.fill", "checkmark.circle.fill", "flag.fill", "exclamationmark.triangle.fill",
            "questionmark.circle.fill", "circle.fill", "square.fill", "triangle.fill", "diamond.fill", "hexagon.fill",
            "suit.heart.fill", "suit.club.fill", "suit.diamond.fill", "laurel.leading", "square.and.arrow.down"
        ])
    ]

    /// Brand icons available in Assets.xcassets/brands, from Simple Icons
    /// (`scripts/update_brand_icons.py`, which lists where each comes from
    /// in docs/brand-icons.md)
    static let brandGroups: [Group] = [
        ("Languages", "chevron.left.forwardslash.chevron.right", [
            "brand-swift", "brand-c", "brand-cplusplus", "brand-java", "brand-kotlin", "brand-scala", "brand-groovy",
            "brand-go", "brand-rust", "brand-python", "brand-ruby", "brand-php", "brand-perl", "brand-r",
            "brand-dart", "brand-clojure", "brand-javascript", "brand-typescript", "brand-html5", "brand-css3",
            "brand-less", "brand-bash", "brand-latex", "brand-markdown", "brand-processing"
        ]),
        ("Frameworks", "square.stack.3d.up.fill", [
            "brand-react", "brand-redux", "brand-angularjs", "brand-svelte", "brand-ember",
            "brand-backbonejs", "brand-jquery", "brand-nextjs", "brand-nuxtjs", "brand-gatsby", "brand-hugo",
            "brand-eleventy", "brand-meteor", "brand-nodejs", "brand-express", "brand-django", "brand-flask",
            "brand-rails", "brand-laravel", "brand-symfony", "brand-spring", "brand-dotnet", "brand-flutter",
            "brand-electron", "brand-bootstrap", "brand-d3js", "brand-threejs", "brand-opengl", "brand-handlebars",
            "brand-babel", "brand-grunt", "brand-gulp", "brand-npm", "brand-wordpress", "brand-drupal",
            "brand-webflow", "brand-unity"
        ]),
        ("AI", "sparkles", [
            "brand-anthropic", "brand-deepseek", "brand-mistral", "brand-perplexity", "brand-ollama",
            "brand-openrouter", "brand-mcp", "brand-pytorch", "brand-tensorflow"
        ]),
        ("Tools", "hammer.fill", [
            "brand-git", "brand-github", "brand-gitlab", "brand-docker", "brand-kubernetes", "brand-firebase",
            "brand-vercel", "brand-mysql", "brand-postgresql", "brand-xcode", "brand-vim", "brand-emacs",
            "brand-figma", "brand-sketch", "brand-blender", "brand-maya", "brand-jira", "brand-raycast",
            "brand-arduino", "brand-raspberrypi", "brand-gnu"
        ]),
        ("Companies", "building.2.fill", [
            "brand-apple", "brand-google", "brand-meta", "brand-alibaba", "brand-x", "brand-youtube"
        ])
    ]

    /// Brand icons Klar offered before they came from Simple Icons, which
    /// doesn't carry them (most at their brands' request), or whose license
    /// there rules out commercial use (Sass's and Vue's). A group that picked
    /// one shows its favicons, a space its letter, as with no icon.
    static let retiredBrandIcons: Set<String> = [
        "brand-objc", "brand-csharp", "brand-matlab", "brand-clojurescript", "brand-sass", "brand-vuejs",
        "brand-xamarin", "brand-magento", "brand-openai", "brand-xai", "brand-midjourney", "brand-stabilityai",
        "brand-blackforestlabs", "brand-smithery", "brand-aws", "brand-azure", "brand-vscode",
        "brand-visualstudio", "brand-slack", "brand-salesforce", "brand-windows", "brand-linkedin"
    ]

    /// Brand icons picked under another name: .NET Core's logo is .NET's now
    static let renamedBrandIcons: [String: String] = [
        "brand-dotnetcore": "brand-dotnet"
    ]

    private static let curatedSFSymbols: [String] = symbolGroups.flatMap(\.names)
    private static let brandIcons: [String] = brandGroups.flatMap(\.names)
    /// With the plain folder, which the picker leaves out: on a folder it
    /// means no icon.
    private static let validIcons: Set<String> = Set(curatedSFSymbols + brandIcons + [FolderIcons.defaultIcon])
    private static let brandIconSet: Set<String> = Set(brandIcons)

    // MARK: - Public API

    /// Get all curated icons for folder categorization (SF Symbols + Brand icons)
    static func getAllIcons() -> [String] {
        return [FolderIcons.defaultIcon] + curatedSFSymbols + brandIcons
    }

    /// Check if an icon is a brand icon (from assets)
    static func isBrandIcon(_ icon: String) -> Bool {
        return brandIconSet.contains(icon)
    }

    /// A brand icon Klar no longer has (`retiredBrandIcons`)
    static func isRetiredBrandIcon(_ icon: String) -> Bool {
        return retiredBrandIcons.contains(icon)
    }

    /// Check if a symbol name is valid (exists in our curated list or brand icons)
    static func isValidIcon(_ icon: String) -> Bool {
        return validIcons.contains(icon)
    }

    /// Filter symbols based on search text from our curated list and brand icons
    static func filterIcons(_ searchText: String) -> [String] {
        if searchText.isEmpty {
            return getAllIcons()
        }

        let lowercaseSearch = searchText.lowercased()
        return getAllIcons().filter { icon in
            icon.lowercased().contains(lowercaseSearch)
        }
    }
}
