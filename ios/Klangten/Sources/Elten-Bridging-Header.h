// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.
//
// Swift sees the Ruby boot shim through this bridging header. When the iOS
// static libruby + headers are present the RubyC path in RubyRuntime.swift is
// compiled in (guarded by `#if canImport(RubyC)` / the ELTEN_HAS_RUBY flag).

#import "ruby_shim.h"
