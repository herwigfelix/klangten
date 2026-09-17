// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.

import UIKit

@main
final class AppDelegate: UIResponder, UIApplicationDelegate {
    var window: UIWindow?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        let window = UIWindow(frame: UIScreen.main.bounds)
        window.rootViewController = EltenGestureViewController()
        window.makeKeyAndVisible()
        self.window = window

        // Boot the embedded Elten Ruby core. ios_boot.rb starts the gesture pump
        // and runs the real app event loop on the Ruby thread.
        eltenHostBridgeKeepAlive()
        RubyRuntime.shared.start()
        return true
    }
}
