import SwiftUI

@main
struct TheoryApp: App {
    // Stores the ID from the URL (widget tap)
    @State private var deepLinkQuoteID: String? = nil
    
    var body: some Scene {
        WindowGroup {
            // Pass the binding ($) so ContentView can read/reset it
            ContentView(deepLinkQuoteID: $deepLinkQuoteID)
                .onOpenURL { url in
                    handleDeepLink(url)
                }
        }
    }
    
    private func handleDeepLink(_ url: URL) {
        let string = url.absoluteString
        
        // CASE 1: Open specific quote
        if string.contains("theoryapp://quote/") {
            let encodedID = string.replacingOccurrences(of: "theoryapp://quote/", with: "")
            if let decodedID = encodedID.removingPercentEncoding {
                deepLinkQuoteID = decodedID
                print("🔗 Deep link: Opening quote with ID: \(decodedID)")
            }
        }
        // CASE 2: Copy specific quote
        else if string.contains("theoryapp://copy/") {
            let encodedID = string.replacingOccurrences(of: "theoryapp://copy/", with: "")
            if let decodedID = encodedID.removingPercentEncoding {
                deepLinkQuoteID = decodedID // We pass it down; ContentView handles the logic
            }
        }
    }
}
