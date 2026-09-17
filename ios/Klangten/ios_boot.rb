# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# Elten is free software: GNU General Public License v3.
#
# Entry point for the embedded runtime (loaded by ruby_shim.c after the CRuby
# runtime, the gem extensions and the load paths are set up). It loads the full
# Elten core, starts the gesture pump and runs the real app.

require "rbconfig" rescue nil
require "rubygems" rescue nil

root = File.join(__dir__, "eltencore")

# Load every core file (elten.rb honours ELTEN_BOOT_STOP_BEFORE_MAIN and exits
# before main.rb) so we can start the gesture pump before the event loop begins.
ENV["ELTEN_BOOT_STOP_BEFORE_MAIN"] = "1"
begin
  load File.join(root, "elten.rb")
rescue SystemExit
end

# Drain host-recognised gestures / keyboard events on a GVL-safe Ruby thread.
IOSTouchInput.start_host_pump if defined?(IOSTouchInput)

# Run the real Elten app. main.rb installs the EltenAPI mixin and enters the
# scene event loop; speech goes through IOSSpeech -> the host AVSpeechSynthesizer,
# input arrives from the touch layer as injected virtual keys. This blocks.
ENV.delete("ELTEN_BOOT_STOP_BEFORE_MAIN")
load File.join(root, "src", "main.rb")
