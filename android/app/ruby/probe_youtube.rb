# A part of Klangten (GNU GPL v3, section 5a).
# Diagnostic: asks the YouTube bridge (NewPipeExtractor) directly, without the
# Klangten core. Start with: adb shell am start -n it.sixdots.klangten/.MainActivity --es entry probe_youtube.rb
require "fiddle"
require "json"

h = Fiddle.dlopen("libklangten.so")
call = lambda do |name, *args|
  types = args.map { Fiddle::TYPE_VOIDP }
  Fiddle::Function.new(h[name], types, Fiddle::TYPE_VOIDP).call(*args).to_s.force_encoding("UTF-8")
end
out = []
out << "verfügbar: #{Fiddle::Function.new(h["elten_host_youtube_available"], [], Fiddle::TYPE_INT).call}"

t = Time.now
json = call.call("elten_host_youtube_search", "hörspiel", "video")
data = JSON.parse(json) rescue { "error" => json[0, 120] }
if data.is_a?(Array)
  out << "Suche: #{data.size} Treffer in #{((Time.now - t) * 1000).round} ms"
  data.first(3).each { |v| out << "  #{v["title"].to_s[0, 50]} | #{v["author"]} | #{v["duration"]}s | #{v["id"]}" }
  first = data.first
  t = Time.now
  video = JSON.parse(call.call("elten_host_youtube_video", first["id"].to_s)) rescue {}
  streams = Array(video["streams"])
  out << "Video: #{video["title"].to_s[0, 40]} in #{((Time.now - t) * 1000).round} ms, #{streams.size} Tonspuren"
  streams.first(3).each { |s| out << "  #{s["codec"]} #{s["container"]} #{s["bitrate"]} #{s["url"].to_s[0, 60]}" }
else
  out << "Suche fehlgeschlagen: #{data["error"]}"
end
puts out.join("\n")
File.write(File.join(ENV["HOME"].to_s, "probe-result.txt"), out.join("\n"))
