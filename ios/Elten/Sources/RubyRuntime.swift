// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.
//
// Boots the embedded Elten Ruby core on a dedicated thread. The Elten sources,
// the CRuby stdlib and the gem libs are staged into the app bundle by
// ios/scripts/build-app.sh; ruby_shim.c wires up the runtime and runs
// ios_boot.rb, which starts the gesture pump and the real app event loop.

import Foundation

final class RubyRuntime {
    static let shared = RubyRuntime()
    private var thread: Thread?

    func start() {
        guard thread == nil else { return }
        let t = Thread { [weak self] in self?.run() }
        t.stackSize = 24 * 1024 * 1024
        t.name = "elten-ruby"
        thread = t
        t.start()
    }

    private func run() {
        guard let appRoot = Bundle.main.resourcePath else { return }

        setenv("ELTEN_LAUNCHER_PLATFORM", "ios", 1)
        let documents = NSSearchPathForDirectoriesInDomains(.documentDirectory, .userDomainMask, true).first
            ?? NSTemporaryDirectory()
        let dataDir = (documents as NSString).appendingPathComponent("Elten")
        try? FileManager.default.createDirectory(atPath: dataDir, withIntermediateDirectories: true)
        setenv("ELTEN_DATA_DIR", dataDir, 1)
        if let frameworks = Bundle.main.privateFrameworksPath {
            setenv("ELTEN_IOS_FRAMEWORKS", frameworks, 1)
        }

        let entry = (appRoot as NSString).appendingPathComponent("ios_boot.rb")
        elten_ruby_boot(appRoot, entry)   // blocks: runs the Elten event loop
        NSLog("[Elten] Ruby thread exited")
    }
}
