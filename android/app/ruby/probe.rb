# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
#
# Phase 1 probe: checks inside the app sandbox everything the Klangten core
# needs from the runtime. Writes one line per check to probe-result.txt in the
# files directory (shown by MainActivity) and to logcat.

RESULTS = []
def check(name)
  value = yield
  RESULTS << format("%-14s %s", name, value)
rescue Exception => e
  RESULTS << format("%-14s FEHLER %s: %s", name, e.class, e.message.to_s[0, 200])
end

files = ENV["HOME"].to_s

check("Ruby") { RUBY_DESCRIPTION }
check("Kodierung") { "#{Encoding.default_external} / #{'Klängten'.encoding} / #{'Klängten'.length} Zeichen" }
check("RubyGems") do
  before = defined?(Gem::VERSION) ? "vom Prelude geladen" : "Prelude ohne Gem"
  require "rubygems"
  "#{before}, Gem #{Gem::VERSION}"
end

check("Fiddle") do
  require "fiddle"
  strlen = Fiddle::Function.new(Fiddle.dlopen(nil)["strlen"], [Fiddle::TYPE_VOIDP], Fiddle::TYPE_SIZE_T)
  closure = Class.new(Fiddle::Closure) { def call(x) x * 2 end }.new(Fiddle::TYPE_INT, [Fiddle::TYPE_INT])
  doubled = Fiddle::Function.new(closure, [Fiddle::TYPE_INT], Fiddle::TYPE_INT).call(21)
  "strlen #{strlen.call('Klangten')}, Closure #{doubled}"
end

check("json/psych/zlib") do
  require "json"; require "yaml"; require "zlib"
  data = { "a" => [1, "ü"] }
  ok = JSON.parse(data.to_json) == data && YAML.safe_load(data.to_yaml) == data &&
       Zlib::Inflate.inflate(Zlib::Deflate.deflate("x" * 100)) == "x" * 100
  ok ? "ok" : "falsches Ergebnis"
end

# Android keeps its trusted roots as single PEM files; OpenSSL wants one bundle.
check("CA-Zertifikate") do
  dirs = ["/system/etc/security/cacerts", "/apex/com.android.conscrypt/cacerts"].select { |d| File.directory?(d) }
  pems = dirs.flat_map { |d| Dir.children(d).map { |f| File.join(d, f) } }
  bundle = File.join(files, "cacert.pem")
  File.write(bundle, pems.map { |p| File.read(p)[/-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----/m].to_s }.join("\n"))
  # Like src/eapi/tls.rb: straight into the default store. OpenSSL ignores
  # SSL_CERT_FILE here (app processes count as "secure" for getenv).
  require "openssl"
  OpenSSL::SSL::SSLContext::DEFAULT_CERT_STORE.add_file(bundle)
  "#{pems.size} Zertifikate aus #{dirs.join(', ')}"
end

check("OpenSSL") do
  require "openssl"
  OpenSSL::OPENSSL_LIBRARY_VERSION
end

check("HTTPS") do
  require "net/http"
  uri = URI("https://ten.klango.online/")
  t = Time.now
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true, open_timeout: 10, read_timeout: 10) { |h| h.head("/") }
  "#{uri.host}: HTTP #{response.code}, Zertifikat geprüft, #{((Time.now - t) * 1000).round} ms"
end

check("BASS") do
  require "fiddle"
  # The libraries stay inside the APK (extractNativeLibs=false): open them by
  # name, the app's linker namespace finds them there.
  bass = Fiddle.dlopen("libbass.so")
  v = Fiddle::Function.new(bass["BASS_GetVersion"], [], Fiddle::TYPE_INT).call
  init = Fiddle::Function.new(bass["BASS_Init"], [Fiddle::TYPE_INT] * 3 + [Fiddle::TYPE_VOIDP] * 2, Fiddle::TYPE_INT)
  ok = init.call(-1, 48000, 0, nil, nil)
  code = Fiddle::Function.new(bass["BASS_ErrorGetCode"], [], Fiddle::TYPE_INT).call
  plugins = %w[bassopus bassflac basshls basswebm].map do |m|
    h = Fiddle::Function.new(bass["BASS_PluginLoad"], [Fiddle::TYPE_VOIDP, Fiddle::TYPE_INT], Fiddle::TYPE_INT).call("lib#{m}.so", 0)
    "#{m}#{h == 0 ? '✗' : '✓'}"
  end
  format("%d.%d.%d.%d, BASS_Init %s, %s", (v >> 24) & 255, (v >> 16) & 255, (v >> 8) & 255, v & 255,
         ok != 0 ? "ok" : "Fehler #{code}", plugins.join(" "))
end

check("TeamConference") do
  tc = Fiddle.dlopen("libteamconference_core.so")
  version = Fiddle::Function.new(tc["tc_version"], [], Fiddle::TYPE_VOIDP).call.to_s
  tc["tc_join_group_room"]
  "#{version}, Gruppenräume vorhanden"
end

check("Klangten-Kern") do
  core = File.join(ENV["KLANGTEN_RUBY_ROOT"].to_s, "app", "eltencore", "elten.rb")
  File.exist?(core) ? "vorhanden (noch nicht gestartet)" : "noch nicht im APK"
end

text = RESULTS.join("\n")
puts text
File.write(File.join(files, "probe-result.txt"), text + "\n")
