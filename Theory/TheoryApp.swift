import SwiftUI

@main
struct TheoryApp: App {
    // Stores the ID from the URL (widget tap)
    @State private var deepLinkQuoteID: String? = nil
    
    // Connects the AppDelegate to lock orientation
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
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
        // CASE 2: Copy specific quote (Handled in ContentView.onOpenURL, but passing ID ensures app wakes up)
        else if string.contains("theoryapp://copy/") {
            let encodedID = string.replacingOccurrences(of: "theoryapp://copy/", with: "")
            if let decodedID = encodedID.removingPercentEncoding {
                deepLinkQuoteID = decodedID
            }
        }
    }
}

// Class to force Portrait orientation
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        return .portrait
    }
}
