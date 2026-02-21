import SwiftUI

// MARK: - Shared Icon Catalog

struct ProjectIcons {
    struct IconEntry {
        let name: String
        let keywords: [String]
    }

    static let defaultIcon = "folder.fill"

    static let all: [IconEntry] = [
        // General / Files
        IconEntry(name: "folder.fill", keywords: ["folder", "directory", "files", "default"]),
        IconEntry(name: "doc.fill", keywords: ["document", "file"]),
        IconEntry(name: "doc.text.fill", keywords: ["document", "text", "notes"]),
        IconEntry(name: "tray.fill", keywords: ["inbox", "tray", "mail"]),
        IconEntry(name: "archivebox.fill", keywords: ["archive", "storage", "box"]),
        IconEntry(name: "paperclip", keywords: ["attachment", "clip"]),
        IconEntry(name: "link", keywords: ["link", "url", "chain"]),
        IconEntry(name: "square.and.arrow.up", keywords: ["upload", "share", "export"]),
        IconEntry(name: "square.and.arrow.down", keywords: ["download", "import"]),
        IconEntry(name: "externaldrive.fill", keywords: ["drive", "storage", "disk"]),

        // Development / Code
        IconEntry(name: "chevron.left.forwardslash.chevron.right", keywords: ["code", "development", "programming", "dev"]),
        IconEntry(name: "terminal.fill", keywords: ["terminal", "shell", "command", "cli"]),
        IconEntry(name: "hammer.fill", keywords: ["build", "tool", "construct"]),
        IconEntry(name: "wrench.and.screwdriver.fill", keywords: ["tools", "settings", "config", "fix"]),
        IconEntry(name: "gearshape.fill", keywords: ["settings", "gear", "config", "system"]),
        IconEntry(name: "gearshape.2.fill", keywords: ["settings", "gears", "config", "system"]),
        IconEntry(name: "server.rack", keywords: ["server", "backend", "infrastructure", "hosting"]),
        IconEntry(name: "cpu.fill", keywords: ["processor", "cpu", "hardware", "chip"]),
        IconEntry(name: "memorychip.fill", keywords: ["memory", "ram", "chip", "hardware"]),
        IconEntry(name: "ladybug.fill", keywords: ["bug", "debug", "testing"]),
        IconEntry(name: "ant.fill", keywords: ["bug", "debug", "testing", "ant"]),
        IconEntry(name: "curlybraces", keywords: ["code", "json", "braces", "programming"]),

        // Buildings / Office
        IconEntry(name: "building.fill", keywords: ["building", "office", "company"]),
        IconEntry(name: "building.2.fill", keywords: ["buildings", "campus", "enterprise"]),
        IconEntry(name: "building.columns.fill", keywords: ["bank", "government", "institution", "legal"]),
        IconEntry(name: "house.fill", keywords: ["home", "house", "personal"]),
        IconEntry(name: "storefront.fill", keywords: ["store", "shop", "retail", "ecommerce"]),
        IconEntry(name: "shippingbox.fill", keywords: ["shipping", "package", "delivery", "box"]),
        IconEntry(name: "briefcase.fill", keywords: ["work", "business", "briefcase", "professional"]),

        // People
        IconEntry(name: "person.fill", keywords: ["person", "user", "profile", "individual"]),
        IconEntry(name: "person.2.fill", keywords: ["people", "team", "group", "users"]),
        IconEntry(name: "person.3.fill", keywords: ["people", "team", "group", "community"]),
        IconEntry(name: "person.crop.circle.fill", keywords: ["avatar", "profile", "user"]),
        IconEntry(name: "figure.stand", keywords: ["person", "figure", "body"]),

        // Business / Finance
        IconEntry(name: "cart.fill", keywords: ["cart", "shopping", "ecommerce", "store"]),
        IconEntry(name: "creditcard.fill", keywords: ["payment", "credit", "card", "billing"]),
        IconEntry(name: "banknote.fill", keywords: ["money", "cash", "finance", "payment"]),
        IconEntry(name: "chart.bar.fill", keywords: ["chart", "analytics", "data", "bar", "graph"]),
        IconEntry(name: "chart.line.uptrend.xyaxis", keywords: ["chart", "growth", "trending", "analytics"]),
        IconEntry(name: "chart.pie.fill", keywords: ["chart", "pie", "analytics", "data"]),
        IconEntry(name: "dollarsign.circle.fill", keywords: ["money", "dollar", "finance", "currency"]),
        IconEntry(name: "percent", keywords: ["percent", "discount", "rate"]),

        // Communication
        IconEntry(name: "envelope.fill", keywords: ["email", "mail", "message"]),
        IconEntry(name: "phone.fill", keywords: ["phone", "call", "contact"]),
        IconEntry(name: "bubble.left.fill", keywords: ["chat", "message", "comment", "speech"]),
        IconEntry(name: "megaphone.fill", keywords: ["marketing", "announce", "broadcast", "promotion"]),
        IconEntry(name: "antenna.radiowaves.left.and.right", keywords: ["broadcast", "radio", "signal", "wireless"]),
        IconEntry(name: "bell.fill", keywords: ["notification", "alert", "bell", "reminder"]),

        // Media / Creative
        IconEntry(name: "camera.fill", keywords: ["camera", "photo", "photography"]),
        IconEntry(name: "photo.fill", keywords: ["photo", "image", "picture", "gallery"]),
        IconEntry(name: "film.fill", keywords: ["film", "movie", "video", "cinema"]),
        IconEntry(name: "video.fill", keywords: ["video", "recording", "stream"]),
        IconEntry(name: "music.note", keywords: ["music", "audio", "sound"]),
        IconEntry(name: "music.note.list", keywords: ["music", "playlist", "audio"]),
        IconEntry(name: "paintbrush.fill", keywords: ["design", "paint", "art", "creative"]),
        IconEntry(name: "paintpalette.fill", keywords: ["design", "color", "art", "palette"]),
        IconEntry(name: "pencil", keywords: ["edit", "write", "pencil", "draw"]),
        IconEntry(name: "scissors", keywords: ["cut", "edit", "scissors"]),
        IconEntry(name: "wand.and.stars", keywords: ["magic", "ai", "generate", "transform"]),
        IconEntry(name: "sparkles", keywords: ["ai", "magic", "new", "sparkle", "generate"]),

        // Technology / Devices
        IconEntry(name: "desktopcomputer", keywords: ["desktop", "computer", "mac", "pc"]),
        IconEntry(name: "laptopcomputer", keywords: ["laptop", "notebook", "computer"]),
        IconEntry(name: "iphone", keywords: ["phone", "mobile", "ios", "app"]),
        IconEntry(name: "ipad", keywords: ["tablet", "ipad", "mobile"]),
        IconEntry(name: "applewatch", keywords: ["watch", "wearable"]),
        IconEntry(name: "headphones", keywords: ["headphones", "audio", "music", "podcast"]),
        IconEntry(name: "gamecontroller.fill", keywords: ["game", "gaming", "controller", "play"]),
        IconEntry(name: "printer.fill", keywords: ["printer", "print", "output"]),

        // Cloud / Network
        IconEntry(name: "cloud.fill", keywords: ["cloud", "hosting", "saas"]),
        IconEntry(name: "cloud.bolt.fill", keywords: ["cloud", "serverless", "function"]),
        IconEntry(name: "globe", keywords: ["web", "website", "world", "internet", "global"]),
        IconEntry(name: "globe.americas.fill", keywords: ["world", "global", "americas", "international"]),
        IconEntry(name: "wifi", keywords: ["wifi", "wireless", "network", "internet"]),
        IconEntry(name: "network", keywords: ["network", "connections", "api", "mesh"]),

        // Science / Education
        IconEntry(name: "book.fill", keywords: ["book", "documentation", "docs", "reading", "library"]),
        IconEntry(name: "book.closed.fill", keywords: ["book", "manual", "guide", "reference"]),
        IconEntry(name: "graduationcap.fill", keywords: ["education", "school", "learning", "course"]),
        IconEntry(name: "lightbulb.fill", keywords: ["idea", "innovation", "insight", "lightbulb"]),
        IconEntry(name: "atom", keywords: ["science", "atom", "physics", "research"]),
        IconEntry(name: "flask.fill", keywords: ["science", "experiment", "lab", "chemistry"]),
        IconEntry(name: "testtube.2", keywords: ["test", "lab", "experiment", "science"]),
        IconEntry(name: "function", keywords: ["math", "function", "formula", "calculate"]),

        // Nature / Wellness
        IconEntry(name: "leaf.fill", keywords: ["nature", "eco", "green", "organic", "leaf"]),
        IconEntry(name: "tree.fill", keywords: ["tree", "nature", "environment", "forest"]),
        IconEntry(name: "sun.max.fill", keywords: ["sun", "bright", "day", "energy"]),
        IconEntry(name: "moon.fill", keywords: ["moon", "night", "dark", "sleep"]),
        IconEntry(name: "drop.fill", keywords: ["water", "drop", "liquid", "hydro"]),
        IconEntry(name: "flame.fill", keywords: ["fire", "hot", "trending", "flame"]),
        IconEntry(name: "wind", keywords: ["wind", "air", "weather"]),
        IconEntry(name: "snowflake", keywords: ["snow", "cold", "winter", "frozen"]),

        // Health
        IconEntry(name: "cross.case.fill", keywords: ["health", "medical", "first aid", "emergency"]),
        IconEntry(name: "heart.fill", keywords: ["heart", "health", "love", "favorite"]),
        IconEntry(name: "staroflife.fill", keywords: ["medical", "emergency", "health", "ems"]),
        IconEntry(name: "pills.fill", keywords: ["medicine", "pharmacy", "health", "pills"]),

        // Security / Legal
        IconEntry(name: "shield.fill", keywords: ["security", "shield", "protection", "safe"]),
        IconEntry(name: "shield.checkered", keywords: ["security", "verified", "check", "protection"]),
        IconEntry(name: "lock.fill", keywords: ["lock", "security", "private", "auth"]),
        IconEntry(name: "key.fill", keywords: ["key", "access", "auth", "api"]),
        IconEntry(name: "eye.fill", keywords: ["eye", "view", "watch", "monitor", "visibility"]),
        IconEntry(name: "hand.raised.fill", keywords: ["stop", "privacy", "permission", "block"]),

        // Shapes / Markers
        IconEntry(name: "star.fill", keywords: ["star", "favorite", "featured", "rating"]),
        IconEntry(name: "bolt.fill", keywords: ["bolt", "lightning", "fast", "power", "energy"]),
        IconEntry(name: "flag.fill", keywords: ["flag", "milestone", "mark", "country"]),
        IconEntry(name: "mappin.circle.fill", keywords: ["location", "map", "pin", "place"]),
        IconEntry(name: "tag.fill", keywords: ["tag", "label", "price", "category"]),
        IconEntry(name: "bookmark.fill", keywords: ["bookmark", "save", "reading"]),
        IconEntry(name: "pin.fill", keywords: ["pin", "sticky", "attach"]),
        IconEntry(name: "diamond.fill", keywords: ["diamond", "gem", "premium", "value"]),

        // Misc
        IconEntry(name: "cup.and.saucer.fill", keywords: ["coffee", "tea", "cafe", "drink"]),
        IconEntry(name: "fork.knife", keywords: ["food", "restaurant", "dining", "kitchen"]),
        IconEntry(name: "car.fill", keywords: ["car", "auto", "vehicle", "transport"]),
        IconEntry(name: "airplane", keywords: ["travel", "flight", "airplane", "trip"]),
        IconEntry(name: "gift.fill", keywords: ["gift", "present", "reward"]),
        IconEntry(name: "calendar", keywords: ["calendar", "schedule", "date", "event"]),
        IconEntry(name: "clock.fill", keywords: ["clock", "time", "schedule", "timer"]),
        IconEntry(name: "hourglass", keywords: ["time", "waiting", "loading", "timer"]),
        IconEntry(name: "fossil.shell.fill", keywords: ["shell", "shellspace", "terminal", "fossil"]),
        IconEntry(name: "ruler.fill", keywords: ["ruler", "measure", "size", "layout"]),
    ]
}

// MARK: - Reusable Icon Picker View

struct IconPickerView: View {
    @Binding var selectedIcon: String
    var columns: Int = 8
    var maxHeight: CGFloat = 200

    @State private var searchText = ""

    private var filteredIcons: [ProjectIcons.IconEntry] {
        guard !searchText.isEmpty else { return ProjectIcons.all }
        let query = searchText.lowercased()
        return ProjectIcons.all.filter { entry in
            entry.name.lowercased().contains(query) ||
            entry.keywords.contains { $0.contains(query) }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .font(.system(size: 12))
                TextField("Search icons...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                            .font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.primary.opacity(0.06))
            )

            ScrollView {
                if filteredIcons.isEmpty {
                    Text("No matching icons")
                        .font(.system(size: 13))
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 20)
                } else {
                    LazyVGrid(columns: Array(repeating: GridItem(.fixed(36), spacing: 8), count: columns), spacing: 8) {
                        ForEach(filteredIcons, id: \.name) { entry in
                            Button {
                                selectedIcon = entry.name
                            } label: {
                                Image(systemName: entry.name)
                                    .font(.system(size: 18))
                                    .foregroundStyle(selectedIcon == entry.name ? .white : .primary)
                                    .frame(width: 32, height: 32)
                                    .background(
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(selectedIcon == entry.name ? Color.accentColor : Color.primary.opacity(0.1))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .frame(maxHeight: maxHeight)
        }
    }
}
