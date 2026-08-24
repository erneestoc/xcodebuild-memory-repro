import UIKit

// Minimal host app: a single empty view controller. It exists only so the
// test bundle has an app process to be injected into, mirroring a standard
// app-hosted XCTest setup.
@main
class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
    ) -> Bool {
        window = UIWindow(frame: UIScreen.main.bounds)
        window?.rootViewController = UIViewController()
        window?.makeKeyAndVisible()
        return true
    }
}
