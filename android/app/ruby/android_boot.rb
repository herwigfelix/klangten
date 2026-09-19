# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Entry point on Android (started by klangten_jni.c). The counterpart of
# ios/Klangten/ios_boot.rb: loads the Klangten core with the Android platform
# tag (which also pulls in the iOS layer), starts the gesture pump and runs
# the app.

ENV["ELTEN_LAUNCHER_PLATFORM"] = "android"
# stdout goes into a pipe that the host forwards to logcat; without this Ruby
# buffers it and diagnostic output only shows up much later, or not at all.
STDOUT.sync = true
STDERR.sync = true
require "rbconfig" rescue nil
require "rubygems" rescue nil

root = File.join(__dir__, "app", "eltencore")

# src/eapi/tls.rb reads its CA bundle from resources/ssl/cert.pem. Android keeps
# the trusted roots as one PEM file per certificate; the bundle is rebuilt from
# them at every start, so system updates to the roots take effect.
begin
  dirs = ["/apex/com.android.conscrypt/cacerts", "/system/etc/security/cacerts"].select { |d| File.directory?(d) }
  pems = dirs.flat_map { |d| Dir.children(d).sort.map { |f| File.join(d, f) } }
  bundle = pems.map { |p| File.read(p)[/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m] }.compact.uniq
  target = File.join(root, "resources", "ssl", "cert.pem")
  Dir.mkdir(File.dirname(target)) unless File.directory?(File.dirname(target))
  File.write(target, bundle.join("\n") + "\n")
rescue Exception => e
  warn "[Klangten] CA bundle: #{e.class}: #{e.message}"
end

ENV["ELTEN_BOOT_STOP_BEFORE_MAIN"] = "1"
begin
  load File.join(root, "elten.rb")
rescue SystemExit
end

IOSTouchInput.start_host_pump if defined?(IOSTouchInput)

ENV.delete("ELTEN_BOOT_STOP_BEFORE_MAIN")
load File.join(root, "src", "main.rb")
