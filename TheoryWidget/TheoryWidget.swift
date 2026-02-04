import WidgetKit
import SwiftUI
import AppIntents

// MARK: - 1. SHARED MODELS (Must match App)
struct WidgetQuoteData: Codable {
    let id: String
    let text: String
    let author: String
    let work: String
    let year: String
    let sequentialID: Int
    var isFavorite: Bool
    var queueIndex: Int
    var queueTotal: Int
}

struct WidgetAuthorData: Codable, Identifiable {
    let id: String; let name: String; let hasImage: Bool
}

// MARK: - 2. INTENT & ENTITY
struct ConfigurationAppIntent: WidgetConfigurationIntent {
    static var title: LocalizedStringResource = "Quote Settings"
    
    @Parameter(title: "Source") var source: QuoteSource?
    @Parameter(title: "Specific Figures") var selectedAuthors: [PersonEntity]?
    @Parameter(title: "Saved Queue") var savedQueueName: String? // Simple String for now
    @Parameter(title: "Refresh", default: .hourly) var frequency: RefreshFrequency?
}

enum QuoteSource: String, AppEnum {
    case all = "All Quotes", favorites = "Favorites", specific = "Specific Figures", savedQueue = "Saved Queue"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Source"
    static var caseDisplayRepresentations: [QuoteSource : DisplayRepresentation] = [.all: "All Quotes", .favorites: "Favorites", .specific: "Specific Figures", .savedQueue: "Saved Queue"]
}

enum RefreshFrequency: String, AppEnum {
    case hourly = "Hourly", daily = "Daily"
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Frequency"
    static var caseDisplayRepresentations: [RefreshFrequency : DisplayRepresentation] = [.hourly: "Hourly", .daily: "Daily"]
}

struct PersonEntity: AppEntity {
    var id: String; var name: String
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Figure"
    static var defaultQuery = PersonQuery()
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

struct PersonQuery: EntityQuery {
    func entities(for identifiers: [String]) async throws -> [PersonEntity] { getAllAuthors().filter { identifiers.contains($0.id) } }
    func suggestedEntities() async throws -> [PersonEntity] { getAllAuthors() }
    private func getAllAuthors() -> [PersonEntity] {
        let appGroupID = "group.com.theory.quotes"
        guard let shared = UserDefaults(suiteName: appGroupID), let data = shared.data(forKey: "widget_authors_list"), let authors = try? JSONDecoder().decode([WidgetAuthorData].self, from: data) else { return [] }
        return authors.map { PersonEntity(id: $0.id, name: $0.name) }
    }
}

// MARK: - 3. PROVIDER
struct Provider: AppIntentTimelineProvider {
    let appGroupID = "group.com.theory.quotes"
    func placeholder(in context: Context) -> SimpleEntry { SimpleEntry(date: Date(), quote: WidgetQuoteData(id: "1", text: "Workers of the world, unite!", author: "Karl Marx", work: "Manifesto", year: "1848", sequentialID: 1, isFavorite: false, queueIndex: 1, queueTotal: 100), authorImage: nil, configuration: ConfigurationAppIntent()) }
    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry { let (quote, img) = getData(for: configuration); return SimpleEntry(date: Date(), quote: quote, authorImage: img, configuration: configuration) }
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        let (quote, img) = getData(for: configuration)
        let frequency = configuration.frequency ?? .hourly
        let nextDate = Calendar.current.date(byAdding: frequency == .hourly ? .hour : .day, value: 1, to: Date())!
        let entry = SimpleEntry(date: Date(), quote: quote, authorImage: img, configuration: configuration)
        return Timeline(entries: [entry], policy: .after(nextDate))
    }
    
    private func getData(for config: ConfigurationAppIntent) -> (WidgetQuoteData, UIImage?) {
        guard let shared = UserDefaults(suiteName: appGroupID), let data = shared.data(forKey: "widget_all_quotes"), let allQuotes = try? JSONDecoder().decode([WidgetQuoteData].self, from: data), !allQuotes.isEmpty else { return (WidgetQuoteData(id: "0", text: "Open App to Load Data", author: "Theory", work: "", year: "", sequentialID: 0, isFavorite: false, queueIndex: 0, queueTotal: 0), nil) }
        
        let source = config.source ?? .all
        var pool: [WidgetQuoteData] = []
        
        if source == .favorites {
            let favIDs = shared.array(forKey: "widget_favorites") as? [String] ?? []
            pool = allQuotes.filter { favIDs.contains($0.id) }
        } else if source == .specific, let selected = config.selectedAuthors, !selected.isEmpty {
            let selectedNames = selected.map { $0.id }
            pool = allQuotes.filter { selectedNames.contains($0.author) }
        } else {
            pool = allQuotes
        }
        
        if pool.isEmpty { pool = allQuotes }
        var selectedQuote = pool.randomElement()!
        
        // Update live favorite status
        let favIDs = shared.array(forKey: "widget_favorites") as? [String] ?? []
        selectedQuote.isFavorite = favIDs.contains(selectedQuote.id)
        
        var image: UIImage? = nil
        let isSingleFigure = (source == .specific && config.selectedAuthors?.count == 1)
        if isSingleFigure, let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            let path = container.appendingPathComponent("AuthorImages").appendingPathComponent("\(selectedQuote.author).jpg")
            if let imgData = try? Data(contentsOf: path) { image = UIImage(data: imgData) }
        }
        return (selectedQuote, image)
    }
}

struct SimpleEntry: TimelineEntry { let date: Date; let quote: WidgetQuoteData; let authorImage: UIImage?; let configuration: ConfigurationAppIntent }

// MARK: - 4. VIEW
struct TheoryWidgetEntryView : View {
    var entry: Provider.Entry
    @Environment(\.widgetFamily) var family

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 0) {
                if entry.quote.id != "0" {
                    HStack(alignment: .top, spacing: 12) {
                        // EXPLAIN (Deep Link)
                        Link(destination: URL(string: "theoryapp://explain/\(entry.quote.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                            Image(systemName: "magnifyingglass").font(.system(size: 16, weight: .bold)).foregroundColor(.white.opacity(0.5)).padding(4)
                        }
                        // COPY (Deep Link)
                        Link(destination: URL(string: "theoryapp://copy/\(entry.quote.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                            Image(systemName: "doc.on.doc").font(.system(size: 16, weight: .bold)).foregroundColor(.white.opacity(0.5)).padding(4)
                        }
                        Spacer()
                        
                        // PROGRESS (Small Fraction)
                        if entry.quote.queueTotal > 0 {
                            Text("\(entry.quote.queueIndex)/\(entry.quote.queueTotal)")
                                .font(.caption2).monospacedDigit().foregroundColor(.white.opacity(0.4))
                        }
                        
                        if let img = entry.authorImage {
                            Image(uiImage: img).resizable().aspectRatio(contentMode: .fill).frame(width: 28, height: 28).clipShape(Circle()).overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 1))
                        }
                        Button(intent: NextQuoteIntent()) {
                            Image(systemName: "arrow.forward").font(.system(size: 16, weight: .bold)).foregroundColor(.white.opacity(0.8)).padding(4)
                        }.buttonStyle(.plain)
                    }.padding(.bottom, 4)
                }
                
                Link(destination: URL(string: "theoryapp://quote/\(entry.quote.id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")")!) {
                    GeometryReader { geo in
                        VStack(alignment: .center) {
                            Text("“\(entry.quote.text)”")
                                .font(.system(size: 24, weight: .bold, design: .serif))
                                .multilineTextAlignment(.center).foregroundColor(.white).minimumScaleFactor(0.4)
                                .frame(width: geo.size.width, height: geo.size.height, alignment: .center)
                        }
                    }
                }.frame(maxHeight: .infinity)
                
                if entry.quote.id != "0" {
                    HStack {
                        Spacer()
                        VStack(spacing: 1) {
                            Text(entry.quote.author).font(.caption).fontWeight(.black).foregroundColor(.yellow)
                            Text(entry.quote.work).font(.caption2).foregroundColor(.gray).lineLimit(1)
                        }
                        Spacer()
                        // HEART (Direct Intent + Larger)
                        Button(intent: ToggleFavoriteIntent(quoteID: entry.quote.id)) {
                            Image(systemName: entry.quote.isFavorite ? "heart.fill" : "heart").font(.system(size: 22)).foregroundColor(entry.quote.isFavorite ? .red : .gray).padding(4)
                        }.buttonStyle(.plain)
                    }.padding(.top, 4)
                }
            }.padding(14)
        }
    }
}

struct NextQuoteIntent: AppIntent {
    static var title: LocalizedStringResource = "Next Quote"
    func perform() async throws -> some IntentResult { WidgetCenter.shared.reloadAllTimelines(); return .result() }
}

struct ToggleFavoriteIntent: AppIntent {
    static var title: LocalizedStringResource = "Toggle Favorite"
    @Parameter(title: "Quote ID") var quoteID: String
    init() {}
    init(quoteID: String) { self.quoteID = quoteID }
    func perform() async throws -> some IntentResult {
        let appGroupID = "group.com.theory.quotes"
        guard let shared = UserDefaults(suiteName: appGroupID) else { return .result() }
        var favorites = shared.array(forKey: "widget_favorites") as? [String] ?? []
        if favorites.contains(quoteID) { favorites.removeAll { $0 == quoteID } } else { favorites.append(quoteID) }
        shared.set(favorites, forKey: "widget_favorites")
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}

@main
struct TheoryWidget: Widget {
    let kind: String = "TheoryWidget"
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            TheoryWidgetEntryView(entry: entry).containerBackground(Color.black, for: .widget)
        }.configurationDisplayName("Theory Quote").description("Daily or Hourly quotes.").supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}
