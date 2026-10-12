// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
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
        #if DEBUG
        // KLANGTEN_MUTE=1: the sound engine plays into its null device (set
        // before the Ruby core opens it); speech is muted in the host bridge.
        if hostMuted { setenv("KLANGTEN_AUDIO_NULL", "1", 1) }
        #endif
        RubyRuntime.shared.start()
        #if DEBUG
        scheduleTestGestures()
        #endif
        return true
    }

    #if DEBUG
    // Test facility (debug builds only): KLANGTEN_GESTURES="8:swipe_down,2:double_tap"
    // ("clear" empties the caption, "text=abc" types abc as the system keyboard would)
    // pushes each gesture after waiting the given seconds, the way the Android
    // host takes --es gesture. Set it with SIMCTL_CHILD_KLANGTEN_GESTURES for
    // `xcrun simctl launch`; used for screenshots without touching the simulator.
    private func scheduleTestGestures() {
        guard let script = ProcessInfo.processInfo.environment["KLANGTEN_GESTURES"], !script.isEmpty else { return }
        var delay = 0.0
        for step in script.split(separator: ",") {
            let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, let wait = Double(parts[0]) else { continue }
            delay += wait
            let gesture = parts[1]
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                NSLog("[Klangten] test gesture %@", gesture)
                if gesture == "clear" { EltenGestureViewController.current?.clearSpokenText(); return }
                if gesture.hasPrefix("text=") { EltenInputQueue.shared.pushKeyboardText(String(gesture.dropFirst(5))); return }
                EltenInputQueue.shared.pushGesture(gesture)
            }
        }
    }
    #endif
}
