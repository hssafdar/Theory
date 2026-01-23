import SwiftUI
import UniformTypeIdentifiers
import PhotosUI
import WidgetKit

// MARK: - 1. SHARED CONSTANTS
let APP_GROUP_ID = "group.com.theory.quotes"

// MARK: - 2. DATA MODELS

struct Quote: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let text: String
    let author: String
    let workTitle: String
    let year: String
    var persistenceID: String { "\(author)-\(workTitle)-\(text.hashValue)" }
    
    init(id: UUID = UUID(), text: String, author: String, workTitle: String, year: String) {
        self.id = id
        self.text = text
        self.author = author
        self.workTitle = workTitle
        self.year = year
    }
}

struct Author: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let profileImagePath: String?
    var works: [Work]
}

struct Work: Identifiable, Hashable, Sendable {
    let id = UUID()
    let title: String
    let year: String
    let authorName: String
    var quotes: [Quote]
}

// SHARED WIDGET MODELS
struct WidgetQuoteData: Codable, Sendable {
    let id: String
    let text: String
    let author: String
    let work: String
    let year: String
    var isFavorite: Bool
}

struct WidgetDataAuthor: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    var hasImage: Bool
}

// MARK: - 3. VIEW MODEL

@Observable
class QuoteViewModel {
    var allQuotes: [Quote] = []
    var works: [Work] = []
    var displayItems: [DisplayItem] = []
    var isLoading = true
    
    // Persistence
    var favoriteIDs: Set<String> = []
    var viewedIDs: Set<String> = []
    var excludedWorks: Set<String> = []
    var notBasedIDs: Set<String> = []
    var disabledQuoteIDs: Set<String> = []
    
    // Feeds
    var mainFeedQuotes: [Quote] = []
    
    init() {
        setupFileSystem()
        loadPersistence()
        Task { await loadDataAsync() }
    }
    
    func loadDataAsync() async {
        let (loadedQuotes, loadedAuthors, loadedWorks) = await Task.detached(priority: .userInitiated) {
            return self.parseFiles()
        }.value
        
        await MainActor.run {
            self.allQuotes = loadedQuotes
            self.works = loadedWorks
            self.buildQueue(from: loadedAuthors)
            self.refreshFeed()
            self.syncWidgetData(authors: loadedAuthors)
            withAnimation { self.isLoading = false }
        }
    }
    
    func refreshFeed() {
        let activeNames = getActiveAuthorNames()
        let activeQuotes = allQuotes.filter { quote in
            activeNames.contains(quote.author) &&
            !excludedWorks.contains(quote.workTitle) &&
            !notBasedIDs.contains(quote.persistenceID) &&
            !disabledQuoteIDs.contains(quote.persistenceID)
        }
        self.mainFeedQuotes = activeQuotes.shuffled()
    }
    
    // MARK: - WIDGET SYNC
    func syncWidgetData(authors: [Author]? = nil) {
        guard let sharedDefaults = UserDefaults(suiteName: APP_GROUP_ID) else { return }
        
        // 1. Save Quotes
        let widgetQuotes = allQuotes.map { quote in
            WidgetQuoteData(
                id: quote.persistenceID,
                text: quote.text,
                author: quote.author,
                work: quote.workTitle,
                year: quote.year,
                isFavorite: favoriteIDs.contains(quote.persistenceID)
            )
        }
        if let encoded = try? JSONEncoder().encode(widgetQuotes) {
            sharedDefaults.set(encoded, forKey: "widget_all_quotes")
        }
        
        // 2. Save Favorites
        sharedDefaults.set(Array(favoriteIDs), forKey: "widget_favorites")
        
        // 3. Save Authors & Copy Images
        let authorList = authors ?? []
        var widgetAuthors: [WidgetDataAuthor] = []
        
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: APP_GROUP_ID) {
            let imagesDir = containerURL.appendingPathComponent("AuthorImages")
            try? FileManager.default.createDirectory(at: imagesDir, withIntermediateDirectories: true)
            
            for author in authorList {
                var hasImg = false
                if let localPath = author.profileImagePath,
                   let imageData = try? Data(contentsOf: URL(fileURLWithPath: localPath)) {
                    let sharedPath = imagesDir.appendingPathComponent("\(author.name).jpg")
                    try? imageData.write(to: sharedPath)
                    hasImg = true
                }
                widgetAuthors.append(WidgetDataAuthor(id: author.name, name: author.name, hasImage: hasImg))
            }
        }
        
        if let encodedAuthors = try? JSONEncoder().encode(widgetAuthors) {
            sharedDefaults.set(encodedAuthors, forKey: "widget_authors_list")
        }
        
        WidgetCenter.shared.reloadAllTimelines()
    }
    
    // MARK: - ACTIONS
    func findQuote(by id: String) -> Quote? {
        return allQuotes.first(where: { $0.persistenceID == id })
    }
    
    func toggleFavorite(_ quote: Quote) {
        if favoriteIDs.contains(quote.persistenceID) { favoriteIDs.remove(quote.persistenceID) }
        else { favoriteIDs.insert(quote.persistenceID) }
        savePersistence()
        syncWidgetData()
    }
    
    func toggleNotBased(_ quote: Quote) {
        if notBasedIDs.contains(quote.persistenceID) { notBasedIDs.remove(quote.persistenceID) }
        else { notBasedIDs.insert(quote.persistenceID) }
        savePersistence()
        refreshFeed()
    }
    
    func toggleDisabled(_ quote: Quote) {
        if disabledQuoteIDs.contains(quote.persistenceID) { disabledQuoteIDs.remove(quote.persistenceID) }
        else { disabledQuoteIDs.insert(quote.persistenceID) }
        savePersistence()
        refreshFeed()
    }
    
    func markAsViewed(_ quote: Quote) {
        if !viewedIDs.contains(quote.persistenceID) { viewedIDs.insert(quote.persistenceID); savePersistence() }
    }
    
    func resetReadHistory() { viewedIDs.removeAll(); savePersistence() }
    
    func toggleWorkExclusion(for workTitle: String) {
        if excludedWorks.contains(workTitle) { excludedWorks.remove(workTitle) }
        else { excludedWorks.insert(workTitle) }
        savePersistence()
        refreshFeed()
    }
    
    func isFavorite(_ quote: Quote) -> Bool { favoriteIDs.contains(quote.persistenceID) }
    func isNotBased(_ quote: Quote) -> Bool { notBasedIDs.contains(quote.persistenceID) }
    func isDisabled(_ quote: Quote) -> Bool { disabledQuoteIDs.contains(quote.persistenceID) }
    func isWorkExcluded(_ workTitle: String) -> Bool { excludedWorks.contains(workTitle) }
    func getViewedCount(for work: Work) -> Int { work.quotes.filter { viewedIDs.contains($0.persistenceID) }.count }
    
    // --- QUEUE ---
    private func getActiveAuthorNames() -> Set<String> {
        var names = Set<String>()
        for item in displayItems {
            if case .divider = item { break }
            if case .author(let author) = item { names.insert(author.name) }
        }
        return names
    }
    
    private func buildQueue(from authors: [Author]) {
        let savedOrder = UserDefaults.standard.array(forKey: "QueueOrder") as? [String] ?? []
        var organizedItems: [DisplayItem] = []
        var remainingAuthors = authors
        if !savedOrder.isEmpty {
            for name in savedOrder {
                if name == "DIVIDER_TOKEN" { organizedItems.append(.divider) }
                else if let index = remainingAuthors.firstIndex(where: { $0.name == name }) {
                    organizedItems.append(.author(remainingAuthors[index])); remainingAuthors.remove(at: index)
                }
            }
        } else {
            let defaults = ["Karl Marx", "Friedrich Engels", "Marx", "Engels"]
            for def in defaults {
                if let index = remainingAuthors.firstIndex(where: { $0.name.contains(def) }) {
                    organizedItems.append(.author(remainingAuthors[index])); remainingAuthors.remove(at: index)
                }
            }
            organizedItems.append(.divider)
        }
        for author in remainingAuthors { organizedItems.append(.author(author)) }
        if !organizedItems.contains(where: { if case .divider = $0 { return true }; return false }) { organizedItems.insert(.divider, at: 0) }
        self.displayItems = organizedItems
    }
    
    func moveItem(from source: IndexSet, to destination: Int) {
        let generator = UIImpactFeedbackGenerator(style: .medium); generator.impactOccurred()
        displayItems.move(fromOffsets: source, toOffset: destination); saveQueueOrder(); refreshFeed()
    }
    
    func toggleQueueStatus(for author: Author) {
        guard let currentIndex = displayItems.firstIndex(where: { if case .author(let a) = $0 { return a.id == author.id }; return false }) else { return }
        guard let dividerIndex = displayItems.firstIndex(of: .divider) else { return }
        var newItems = displayItems; let item = newItems.remove(at: currentIndex); _ = newItems.firstIndex(of: .divider) ?? 0
        if currentIndex < dividerIndex { newItems.append(item) } else { newItems.insert(item, at: 0) }
        displayItems = newItems; saveQueueOrder(); refreshFeed()
    }
    
    func isActive(_ author: Author) -> Bool {
        guard let authorIndex = displayItems.firstIndex(where: { if case .author(let a) = $0 { return a.id == author.id }; return false }) else { return false }
        guard let dividerIndex = displayItems.firstIndex(of: .divider) else { return false }
        return authorIndex < dividerIndex
    }
    
    private func saveQueueOrder() {
        let orderStrings: [String] = displayItems.map { item in switch item { case .author(let a): return a.name; case .divider: return "DIVIDER_TOKEN" } }
        UserDefaults.standard.set(orderStrings, forKey: "QueueOrder")
    }
    
    // --- FILES ---
    private func setupFileSystem() {
        let fileManager = FileManager.default
        guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let worksDestURL = docURL.appendingPathComponent("Works")
        if !fileManager.fileExists(atPath: worksDestURL.path) { try? fileManager.createDirectory(at: worksDestURL, withIntermediateDirectories: true) }
        if let bundleWorksURL = Bundle.main.url(forResource: "Works", withExtension: nil), let authorDirs = try? fileManager.contentsOfDirectory(at: bundleWorksURL, includingPropertiesForKeys: nil) {
            for authorDir in authorDirs {
                let authorName = authorDir.lastPathComponent
                let destAuthorDir = worksDestURL.appendingPathComponent(authorName)
                if !fileManager.fileExists(atPath: destAuthorDir.path) { try? fileManager.createDirectory(at: destAuthorDir, withIntermediateDirectories: true) }
                if let files = try? fileManager.contentsOfDirectory(at: authorDir, includingPropertiesForKeys: nil) {
                    for file in files {
                        let destFile = destAuthorDir.appendingPathComponent(file.lastPathComponent)
                        if !fileManager.fileExists(atPath: destFile.path) { try? fileManager.copyItem(at: file, to: destFile) }
                    }
                }
            }
        }
    }
    
    nonisolated private func parseFiles() -> ([Quote], [Author], [Work]) {
        var tempQuotes: [Quote] = []; var tempAuthors: [Author] = []; var tempWorks: [Work] = []
        let fileManager = FileManager.default
        guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return ([], [], []) }
        let worksURL = docURL.appendingPathComponent("Works")
        do {
            let authorURLs = try fileManager.contentsOfDirectory(at: worksURL, includingPropertiesForKeys: nil)
            for authorURL in authorURLs {
                if authorURL.lastPathComponent.hasPrefix(".") { continue }
                let authorName = authorURL.lastPathComponent
                var imagePath: String? = nil
                let fileURLs = try fileManager.contentsOfDirectory(at: authorURL, includingPropertiesForKeys: nil)
                if let exact = fileURLs.first(where: { $0.deletingPathExtension().lastPathComponent.lowercased() == authorName.lowercased() && ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }) { imagePath = exact.path }
                else if let any = fileURLs.first(where: { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }) { imagePath = any.path }
                let workURLs = fileURLs.filter { $0.pathExtension == "txt" }
                var currentAuthorWorks: [Work] = []
                for workURL in workURLs {
                    let fileName = workURL.deletingPathExtension().lastPathComponent
                    let components = fileName.components(separatedBy: "_"); let year = components.last ?? "Unknown Year"; let title = components.dropLast().joined(separator: "_")
                    if let content = try? String(contentsOf: workURL, encoding: .utf8) {
                        let rawLines = content.components(separatedBy: .newlines)
                        let quotes: [Quote] = rawLines.compactMap { line in
                            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                            if trimmed.isEmpty || (trimmed.hasPrefix("[") && trimmed.hasSuffix("]") && trimmed.count < 10) { return nil }
                            var cleanText = trimmed
                            if let range = cleanText.range(of: "\\", options: .regularExpression) { cleanText.removeSubrange(range) }
                            if cleanText.hasPrefix("\"") && cleanText.hasSuffix("\"") { cleanText.removeFirst(); cleanText.removeLast() }
                            if cleanText.isEmpty { return nil }
                            return Quote(text: cleanText, author: authorName, workTitle: title, year: year)
                        }
                        let work = Work(title: title, year: year, authorName: authorName, quotes: quotes); currentAuthorWorks.append(work); tempQuotes.append(contentsOf: quotes); tempWorks.append(work)
                    }
                }
                if !currentAuthorWorks.isEmpty { tempAuthors.append(Author(name: authorName, profileImagePath: imagePath, works: currentAuthorWorks)) }
            }
        } catch { print("Error parsing: \(error)") }
        return (tempQuotes, tempAuthors, tempWorks)
    }
    
    // --- PERSISTENCE ---
    private func savePersistence() {
        UserDefaults.standard.set(Array(favoriteIDs), forKey: "Favorites"); UserDefaults.standard.set(Array(viewedIDs), forKey: "Viewed")
        UserDefaults.standard.set(Array(excludedWorks), forKey: "ExcludedWorks"); UserDefaults.standard.set(Array(notBasedIDs), forKey: "NotBased")
        UserDefaults.standard.set(Array(disabledQuoteIDs), forKey: "DisabledQuotes")
        if let shared = UserDefaults(suiteName: APP_GROUP_ID) { shared.set(Array(favoriteIDs), forKey: "widget_favorites") }; WidgetCenter.shared.reloadAllTimelines()
    }
    private func loadPersistence() {
        if let savedFavs = UserDefaults.standard.array(forKey: "Favorites") as? [String] { favoriteIDs = Set(savedFavs) }
        if let savedViewed = UserDefaults.standard.array(forKey: "Viewed") as? [String] { viewedIDs = Set(savedViewed) }
        if let savedWorks = UserDefaults.standard.array(forKey: "ExcludedWorks") as? [String] { excludedWorks = Set(savedWorks) }
        if let savedNotBased = UserDefaults.standard.array(forKey: "NotBased") as? [String] { notBasedIDs = Set(savedNotBased) }
        if let savedDisabled = UserDefaults.standard.array(forKey: "DisabledQuotes") as? [String] { disabledQuoteIDs = Set(savedDisabled) }
    }
    
    func updateAuthorImage(author: Author, imageData: Data) {
        let fileManager = FileManager.default
        guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let authorFolder = docURL.appendingPathComponent("Works").appendingPathComponent(author.name)
        let destinationURL = authorFolder.appendingPathComponent("\(author.name).jpg")
        try? imageData.write(to: destinationURL)
        Task { await loadDataAsync() }
    }
    
    func importAuthorFolder(from url: URL) {
        guard url.startAccessingSecurityScopedResource() else { return }
        defer { url.stopAccessingSecurityScopedResource() }
        let fileManager = FileManager.default
        guard let docURL = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let worksURL = docURL.appendingPathComponent("Works")
        let destURL = worksURL.appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destURL.path) { try? fileManager.removeItem(at: destURL) }
        try? fileManager.copyItem(at: url, to: destURL)
        Task { await loadDataAsync() }
    }
}

enum DisplayItem: Identifiable, Hashable { case author(Author); case divider; var id: String { switch self { case .author(let a): return a.id.uuidString; case .divider: return "DIVIDER" } } }

// MARK: - 5. UI

struct ContentView: View {
    @State private var viewModel = QuoteViewModel()
    @State private var deepLinkToast: String? = nil
    @Binding var deepLinkQuoteID: String?
    @State private var scrollToQuoteID: String? = nil
    
    var body: some View {
        ZStack {
            if viewModel.isLoading {
                SplashScreen()
            } else {
                TabView {
                    FeedViewWithDeepLink(quotes: viewModel.mainFeedQuotes, viewModel: viewModel, scrollToQuoteID: $scrollToQuoteID)
                        .tabItem { Label("Discover", systemImage: "sparkles.rectangle.stack") }
                    FiguresView(viewModel: viewModel)
                        .tabItem { Label("Figures", systemImage: "person.2.crop.square.stack") }
                    FeedView(quotes: viewModel.mainFeedQuotes.filter { viewModel.isFavorite($0) }, viewModel: viewModel)
                        .tabItem { Label("Favorites", systemImage: "heart.fill") }
                    LibraryView(viewModel: viewModel)
                        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                }
                .preferredColorScheme(.dark)
                .onChange(of: deepLinkQuoteID) { _, newValue in
                    if let id = newValue {
                        scrollToQuoteID = id
                        deepLinkQuoteID = nil
                    }
                }
            }
            if let message = deepLinkToast {
                VStack {
                    VStack(spacing: 12) {
                        Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundColor(.white).padding(12).background(Circle().stroke(Color.white, lineWidth: 3))
                        Text("Copied").font(.title3).bold().foregroundColor(.white)
                        Text(message).font(.caption).foregroundColor(.white.opacity(0.8))
                    }
                    .padding(30).background(Color.black.opacity(0.8)).cornerRadius(25).shadow(radius: 20)
                    Spacer()
                }
                .padding(.top, 100).zIndex(100)
                .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 2) { deepLinkToast = nil } }
            }
        }
        .onOpenURL { url in
            if url.absoluteString.contains("theoryapp://copy/") {
                let id = url.absoluteString.replacingOccurrences(of: "theoryapp://copy/", with: "").removingPercentEncoding ?? ""
                if let quote = viewModel.findQuote(by: id) {
                    UIPasteboard.general.string = "\"\(quote.text)\" - \(quote.author)"
                    deepLinkToast = "Copied to Clipboard"
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
            }
        }
    }
}

// WRAPPER FOR SCROLLING
struct FeedViewWithDeepLink: View {
    let quotes: [Quote]
    var viewModel: QuoteViewModel
    @Binding var scrollToQuoteID: String?
    
    var body: some View {
        if quotes.isEmpty {
            VStack {
                Image(systemName: "book.closed").font(.largeTitle)
                Text("No quotes found.").padding(.top).foregroundColor(.gray)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVStack(spacing: 0) {
                        ForEach(quotes) { quote in
                            QuoteCard(quote: quote, viewModel: viewModel)
                                .containerRelativeFrame([.horizontal, .vertical])
                                .id(quote.persistenceID)
                                .onAppear { viewModel.markAsViewed(quote) }
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollTargetBehavior(.paging)
                .ignoresSafeArea()
                .background(Color.black)
                .onChange(of: scrollToQuoteID) { _, newValue in
                    if let target = newValue {
                        DispatchQueue.main.async { withAnimation { proxy.scrollTo(target, anchor: .center) } }
                    }
                }
            }
        }
    }
}

struct SplashScreen: View {
    @State private var message: String = ""
    let messages = ["Greetings, comrade...", "Stay off those brainrot apps...", "Repairing your attention span..."]
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack { Spacer(); Text(message).font(.title2).bold().foregroundColor(.white); ProgressView().progressViewStyle(CircularProgressViewStyle(tint: .red)).scaleEffect(1.5).padding(); Spacer() }
        }
        .onAppear { message = messages.randomElement() ?? messages[0] }
    }
}

// Standard Feed View (for Favorites tab)
struct FeedView: View {
    let quotes: [Quote]
    var viewModel: QuoteViewModel
    var body: some View {
        if quotes.isEmpty {
            VStack { Image(systemName: "book.closed").font(.largeTitle); Text("No quotes found.").padding(.top).foregroundColor(.gray) }
                .frame(maxWidth: .infinity, maxHeight: .infinity).background(Color.black)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                LazyVStack(spacing: 0) {
                    ForEach(quotes) { quote in
                        QuoteCard(quote: quote, viewModel: viewModel).containerRelativeFrame([.horizontal, .vertical]).id(quote.id).onAppear { viewModel.markAsViewed(quote) }
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging).ignoresSafeArea().background(Color.black)
        }
    }
}

struct FiguresView: View {
    var viewModel: QuoteViewModel
    @State private var showImporter = false
    
    var body: some View {
        NavigationView {
            List {
                ForEach(viewModel.displayItems) { item in
                    switch item {
                    case .author(let author):
                        NavigationLink(destination: AuthorDetailView(author: author, viewModel: viewModel)) {
                            HStack(spacing: 12) {
                                if let imagePath = author.profileImagePath, let uiImage = UIImage(contentsOfFile: imagePath) {
                                    Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fill).frame(width: 40, height: 40).clipShape(Circle())
                                } else {
                                    Circle().fill(Color.gray.opacity(0.3)).frame(width: 40, height: 40).overlay(Text(author.name.prefix(1)).bold())
                                }
                                VStack(alignment: .leading) {
                                    Text(author.name).font(.headline)
                                    Text("\(author.works.count) Works").font(.caption).foregroundColor(.secondary)
                                }
                            }
                        }
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            let isActive = viewModel.isActive(author)
                            Button { withAnimation { viewModel.toggleQueueStatus(for: author) } } label: { Label(isActive ? "Remove" : "Add", systemImage: isActive ? "minus.circle" : "plus.circle") }.tint(isActive ? .red : .green)
                        }
                    case .divider:
                        HStack { Rectangle().frame(height: 1).foregroundColor(.red); Text("INACTIVE BELOW").font(.caption2).fontWeight(.bold).foregroundColor(.red).fixedSize(); Rectangle().frame(height: 1).foregroundColor(.red) }.padding(.vertical, 8).listRowInsets(EdgeInsets())
                    }
                }
                .onMove(perform: viewModel.moveItem)
            }
            .navigationTitle("Figures")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { EditButton() }
                ToolbarItem(placement: .navigationBarTrailing) { Button(action: { showImporter = true }) { Image(systemName: "folder.badge.plus") } }
            }
            .fileImporter(isPresented: $showImporter, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
                if let url = try? result.get().first { viewModel.importAuthorFolder(from: url) }
            }
        }
    }
}

struct LibraryView: View {
    var viewModel: QuoteViewModel
    @State private var showResetConfirm = false
    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Collections")) {
                    NavigationLink(destination: AllQuotesListView(viewModel: viewModel)) { Label("All Quotes", systemImage: "quote.bubble") }
                    NavigationLink(destination: FeedView(quotes: viewModel.allQuotes.filter { viewModel.isFavorite($0) }, viewModel: viewModel)) { Label("Favorites (All)", systemImage: "heart.fill") }
                    NavigationLink(destination: FeedView(quotes: viewModel.allQuotes.filter { viewModel.isNotBased($0) }, viewModel: viewModel)) { HStack { Label("Not Based", systemImage: "hand.thumbsdown.fill"); Spacer(); Text("\(viewModel.allQuotes.filter { viewModel.isNotBased($0) }.count)").foregroundColor(.secondary) } }
                }
                Section(header: Text("Options")) { Button(role: .destructive, action: { showResetConfirm = true }) { Label("Reset Read History", systemImage: "clock.arrow.circlepath") } }
            }
            .navigationTitle("Library")
            .alert("Reset Read History?", isPresented: $showResetConfirm) { Button("Cancel", role: .cancel) { }; Button("Reset", role: .destructive) { viewModel.resetReadHistory() } } message: { Text("This will mark all quotes as unread.") }
        }
    }
}

struct AllQuotesListView: View {
    var viewModel: QuoteViewModel
    @State private var searchText = ""
    var filteredQuotes: [Quote] {
        if searchText.isEmpty { return viewModel.allQuotes.filter { !viewModel.isDisabled($0) } }
        return viewModel.allQuotes.filter { !viewModel.isDisabled($0) && ($0.text.localizedCaseInsensitiveContains(searchText) || $0.author.localizedCaseInsensitiveContains(searchText)) }
    }
    var body: some View {
        VStack {
            List {
                Section(header: Text("\(filteredQuotes.count) Quotes")) {
                    ForEach(filteredQuotes) { quote in
                        VStack(alignment: .leading) { Text(quote.text).lineLimit(3).font(.subheadline); Text("\(quote.author) - \(quote.year)").font(.caption).foregroundColor(.secondary) }
                        .contentShape(Rectangle())
                        .contextMenu { Button { UIPasteboard.general.string = "\"\(quote.text)\" - \(quote.author)" } label: { Label("Copy", systemImage: "doc.on.doc") }; Button { let q = "\(quote.text) \(quote.author) \(quote.workTitle) \(quote.year)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""; if let w = URL(string: "https://www.perplexity.ai/search?q=\(q)") { UIApplication.shared.open(w) } } label: { Label("Explain", systemImage: "magnifyingglass") } }
                        .swipeActions(edge: .leading) { Button { viewModel.toggleDisabled(quote) } label: { Label("Disable", systemImage: "eye.slash") }.tint(.gray) }
                    }
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always))
            NavigationLink(destination: FeedView(quotes: filteredQuotes.shuffled(), viewModel: viewModel)) { HStack { Image(systemName: "shuffle"); Text("Shuffle Results") }.font(.headline).frame(maxWidth: .infinity).padding().background(Color.blue).foregroundColor(.white).cornerRadius(12).padding() }
        }
        .navigationTitle("All Quotes")
    }
}

struct QuoteCard: View {
    let quote: Quote
    var viewModel: QuoteViewModel
    @State private var isHeartAnimating = false
    @State private var isThumbsDownAnimating = false
    @State private var showToast = false
    @State private var toastMessage = ""
    
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                HStack { Spacer(); Button(action: { searchInPerplexity(quote: quote) }) { HStack(spacing: 6) { Image(systemName: "magnifyingglass"); Text("Explain").font(.caption).fontWeight(.bold) }.padding(8).background(Color.gray.opacity(0.3)).foregroundColor(.white).clipShape(Capsule()) }.padding(.top, 60).padding(.trailing, 20) }
                Spacer()
            }.zIndex(10)
            VStack(spacing: 0) {
                Spacer(); Text("“\(quote.text)”").font(.system(size: 28, weight: .semibold, design: .serif)).multilineTextAlignment(.center).padding(.horizontal, 30).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
                    .contextMenu { Button { copyToClipboard() } label: { Label("Copy", systemImage: "doc.on.doc") }; Button { searchInPerplexity(quote: quote) } label: { Label("Explain", systemImage: "magnifyingglass") } }
                VStack(spacing: 8) { Text(quote.author).font(.headline).foregroundStyle(.yellow); Text("\(quote.workTitle) • \(quote.year)").font(.caption).foregroundStyle(.gray) }.padding(.top, 24); Spacer()
            }
            HStack {
                Spacer(); VStack(spacing: 30) {
                    Spacer()
                    Button(action: { withAnimation(.spring()) { viewModel.toggleFavorite(quote); isHeartAnimating = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isHeartAnimating = false } }) { VStack { Image(systemName: viewModel.isFavorite(quote) ? "heart.fill" : "heart").font(.system(size: 30)).foregroundStyle(viewModel.isFavorite(quote) ? .red : .white).scaleEffect(isHeartAnimating ? 1.3 : 1.0); Text("Save").font(.caption2).foregroundStyle(.white) } }
                    Button(action: { withAnimation(.spring()) { viewModel.toggleNotBased(quote); isThumbsDownAnimating = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isThumbsDownAnimating = false } }) { VStack { Image(systemName: viewModel.isNotBased(quote) ? "hand.thumbsdown.fill" : "hand.thumbsdown").font(.system(size: 28)).foregroundStyle(viewModel.isNotBased(quote) ? .red : .white).scaleEffect(isThumbsDownAnimating ? 1.3 : 1.0); Text("Not Based").font(.caption2).foregroundStyle(.white) } }
                    ShareLink(item: "\"\(quote.text)\"\n— \(quote.author) (\(quote.year))") { VStack { Image(systemName: "square.and.arrow.up").font(.system(size: 26)).foregroundStyle(.white); Text("Share").font(.caption2).foregroundStyle(.white) } }
                    Spacer().frame(height: 100)
                }.padding(.trailing, 20)
            }
            if showToast { VStack { VStack(spacing: 12) { Image(systemName: "checkmark").font(.system(size: 44, weight: .bold)).foregroundColor(.white).padding(12).background(Circle().stroke(Color.white, lineWidth: 3)).shadow(radius: 5); Text("Copied").font(.title3).bold().foregroundColor(.white); Text(toastMessage).font(.caption).foregroundColor(.white.opacity(0.8)).multilineTextAlignment(.center) }.padding(30).frame(maxWidth: 260).background(Color.black.opacity(0.8)).cornerRadius(25).shadow(radius: 20).transition(.scale.combined(with: .opacity)); Spacer() }.padding(.top, 100).zIndex(100) }
        }
    }
    func copyToClipboard() { UIPasteboard.general.string = "\"\(quote.text)\" - \(quote.author)"; let toasts = ["Propaganda has been successfully spread :)", "Copied the truth to clipboard", "Now that’s dialectical", "Tell all your comrades"]; toastMessage = toasts.randomElement() ?? toasts[0]; withAnimation { showToast = true }; DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { withAnimation { showToast = false } } }
    func searchInPerplexity(quote: Quote) { let q = "\(quote.text) \(quote.author) \(quote.workTitle) \(quote.year)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""; if let u = URL(string: "perplexity://search?q=\(q)"), UIApplication.shared.canOpenURL(u) { UIApplication.shared.open(u) } else if let w = URL(string: "https://www.perplexity.ai/search?q=\(q)") { UIApplication.shared.open(w) } }
}

struct AuthorDetailView: View {
    let author: Author
    @Bindable var viewModel: QuoteViewModel
    @State private var selectedItem: PhotosPickerItem? = nil
    
    var body: some View {
        List {
            Section {
                HStack {
                    Spacer()
                    VStack {
                        if let imagePath = author.profileImagePath, let uiImage = UIImage(contentsOfFile: imagePath) {
                            Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fill).frame(width: 120, height: 120).clipShape(Circle()).shadow(radius: 5)
                        } else {
                            Circle().fill(Color.gray.opacity(0.3)).frame(width: 120, height: 120).overlay(Text(author.name.prefix(1)).font(.largeTitle).bold())
                        }
                        PhotosPicker(selection: $selectedItem, matching: .images, photoLibrary: .shared()) {
                            Label(author.profileImagePath == nil ? "Add Photo" : "Change Photo", systemImage: "photo").font(.footnote).padding(.top, 4)
                        }
                        .onChange(of: selectedItem) { _, newItem in
                            Task {
                                if let item = newItem, let data = try? await item.loadTransferable(type: Data.self) {
                                    viewModel.updateAuthorImage(author: author, imageData: data)
                                }
                            }
                        }
                    }
                    Spacer()
                }
                .listRowBackground(Color.clear)
            }
            Section(header: Text("Configuration")) {
                NavigationLink(destination: FeedView(quotes: author.works.flatMap { $0.quotes }.shuffled(), viewModel: viewModel)) {
                    Label("Shuffle all quotes", systemImage: "shuffle").foregroundColor(.blue)
                }
                NavigationLink(destination: FeedView(quotes: author.works.flatMap { $0.quotes }, viewModel: viewModel)) {
                    Label("Play Selected in Order", systemImage: "play.circle.fill").foregroundColor(.green)
                }
            }
            Section(header: Text("Works")) {
                ForEach(author.works) { work in
                    VStack {
                        NavigationLink(destination: WorkDetailView(work: work, viewModel: viewModel)) {
                            VStack(alignment: .leading) {
                                Text(work.title).font(.headline).strikethrough(viewModel.isWorkExcluded(work.title)).foregroundColor(viewModel.isWorkExcluded(work.title) ? .gray : .primary)
                                Text(work.year).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        Toggle(isOn: Binding(
                            get: { !viewModel.isWorkExcluded(work.title) },
                            set: { _ in viewModel.toggleWorkExclusion(for: work.title) }
                        )) {
                            Text("Include in Feed").font(.caption).foregroundColor(.gray)
                        }
                        .toggleStyle(SwitchToggleStyle(tint: .blue))
                    }
                }
            }
        }
        .navigationTitle(author.name)
    }
}

struct WorkDetailView: View {
    let work: Work
    var viewModel: QuoteViewModel
    
    var body: some View {
        VStack(spacing: 0) {
            VStack {
                Text(work.title).font(.headline).multilineTextAlignment(.center).padding(.top, 8)
                HStack {
                    VStack { Text("\(work.quotes.count)").font(.title3).bold(); Text("Total").font(.caption) }
                    Spacer()
                    VStack { Text("\(viewModel.getViewedCount(for: work))").font(.title3).bold().foregroundColor(.green); Text("Viewed").font(.caption) }
                }
                .padding()
                NavigationLink(destination: FeedView(quotes: work.quotes, viewModel: viewModel)) {
                    HStack { Image(systemName: "book.fill"); Text("Read Feed") }
                        .frame(maxWidth: .infinity).padding(10).background(Color.blue).foregroundColor(.white).cornerRadius(10)
                }
                .padding(.horizontal).padding(.bottom, 10)
            }
            .background(Color(UIColor.systemBackground)).shadow(color: Color.black.opacity(0.1), radius: 2, x: 0, y: 2)
            
            List {
                ForEach(work.quotes) { quote in
                    let isDisabled = viewModel.isDisabled(quote)
                    HStack {
                        Text(quote.text).lineLimit(2).font(.subheadline).foregroundColor(isDisabled ? .gray : .primary)
                        Spacer()
                        if viewModel.isFavorite(quote) { Image(systemName: "heart.fill").foregroundColor(.red).font(.caption) }
                    }
                    .contentShape(Rectangle())
                    .contextMenu {
                        Button { UIPasteboard.general.string = "\"\(quote.text)\" - \(quote.author)" } label: { Label("Copy", systemImage: "doc.on.doc") }
                        Button { let q = "\(quote.text) \(quote.author) \(quote.workTitle) \(quote.year)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""; if let w = URL(string: "https://www.perplexity.ai/search?q=\(q)") { UIApplication.shared.open(w) } } label: { Label("Explain", systemImage: "magnifyingglass") }
                    }
                    .swipeActions(edge: .leading) {
                        Button { viewModel.toggleDisabled(quote) } label: { Label(isDisabled ? "Enable" : "Disable", systemImage: isDisabled ? "eye" : "eye.slash") }.tint(isDisabled ? .green : .gray)
                    }
                }
            }
            .listStyle(.plain)
        }
        .navigationBarTitleDisplayMode(.inline)
    }
}
