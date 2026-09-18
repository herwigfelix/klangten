// A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
// Elten: Copyright (C) 2014-2026 Dawid Pieper
// Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
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
        // No data directory is created here. Klangten keeps its data where every
        // platform keeps it - Klangten::Config.data_dir below Application Support,
        // i.e. sixdotsIT/klangten - and nothing ever read the variable this used to
        // set. The folder it created was empty, sat in Documents and was therefore
        // the first thing the user saw in the Files app and in the file manager,
        // named after the wrong program.
        if let frameworks = Bundle.main.privateFrameworksPath {
            setenv("ELTEN_IOS_FRAMEWORKS", frameworks, 1)
        }

        let entry = (appRoot as NSString).appendingPathComponent("ios_boot.rb")
        elten_ruby_boot(appRoot, entry)   // blocks: runs the Elten event loop
        NSLog("[Elten] Ruby thread exited")
        // The Ruby event loop only returns when Elten shut down (e.g. the Exit
        // menu option). Without terminating here the app would linger as a
        // black, silent, unresponsive screen.
        exit(0)
    }
}
