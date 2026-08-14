// A part of Elten - EltenLink / Elten Network desktop client.
// Copyright (C) 2026 Dawid Pieper
// Elten is free software: GNU General Public License v3.
#ifndef ELTEN_RUBY_SHIM_H
#define ELTEN_RUBY_SHIM_H

// Boot the embedded Elten Ruby core: initialise the interpreter, set the load
// path to app_root/src, and load `entry` (elten.rb). Blocks on the calling
// thread (RubyRuntime runs it on a dedicated thread).
void elten_ruby_boot(const char *app_root, const char *entry);

// Evaluate a snippet on the Ruby thread (used to start the input pump).
void elten_ruby_eval(const char *code);

#endif
