#!/usr/bin/env ruby
# A part of Klangten. GNU GPL v3 (see license).
#
# Loads a page with the engine of the Klangten browser, without a window, and
# prints the reading buffer as the browser screen reads it. For testing the
# engine on a machine (also over SSH) without starting Klangten.
#
#   ruby tools/web-probe.rb [options] URL
#     --dir DIR       data folder (default: a "web-probe" folder in the temp dir)
#     --install       download Chrome for Testing into DIR if it is missing
#     --click TEXT    click the first element whose name contains TEXT, then reload the buffer
#     --type TEXT     focus the first text box, type TEXT and press Enter
#     --save DIR      save a file response (download) into DIR
#     --text          use the plain text browser (no Chrome)
#
# Chrome is closed with Browser.close at the end; the process id is printed.

require "optparse"
require "tmpdir"
require "rbconfig"

options = { dir: File.join(Dir.tmpdir, "web-probe") }
OptionParser.new do |parser|
  parser.on("--dir DIR") { |value| options[:dir] = value }
  parser.on("--install") { options[:install] = true }
  parser.on("--click TEXT") { |value| options[:click] = value }
  parser.on("--type TEXT") { |value| options[:type] = value }
  parser.on("--save DIR") { |value| options[:save] = value }
  parser.on("--text") { options[:text] = true }
end.parse!
url = ARGV[0] || "about:blank"

module EltenSystemHelpers
  def self.platform_os
    case RbConfig::CONFIG["host_os"]
    when /darwin/ then "osx"
    when /mswin|mingw|cygwin/ then "windows"
    else "linux"
    end
  end
end

module Dirs
  def self.user
    Dir.home
  end

  def self.documents
    File.join(Dir.home, "Documents")
  end
end

root = File.expand_path("..", __dir__)
%w[websocket web ax chrome textpage].each { |name| require File.join(root, "src", "eapi", "web", name) }

$stdout.sync = true
KlangtenWeb.data_dir = options[:dir]
puts "Data folder: #{KlangtenWeb.data_dir}"

if options[:text]
  page = KlangtenWeb::TextPage.load(url)
  puts "Title: #{page.title}"
  puts "Address: #{page.url}"
  puts "Error: #{page.error}" if page.error
  puts page.plain_text
  page.links.each_with_index { |link, index| puts "[link #{index + 1}] #{link[:text]} -> #{link[:url]}" }
  exit 0
end

unless KlangtenWeb::Chrome.installed?
  unless options[:install]
    warn "Chrome for Testing is not installed in #{options[:dir]} (use --install)"
    exit 1
  end
  last = -1
  version = KlangtenWeb::Chrome.install do |percent, _got|
    if percent / 10 != last
      last = percent / 10
      puts "Installing: #{percent}%"
    end
  end
  puts "Installed Chrome for Testing #{version}"
end

def wait_for_page(tab, options)
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  while Process.clock_gettime(Process::CLOCK_MONOTONIC) - started < 30
    tab.poll.each do |event|
      case event[:type]
      when "file"
        puts "[file] #{event[:name]} (#{event[:mime]}, #{event[:size]} bytes) from #{event[:url]}"
        if options[:save]
          path = KlangtenWeb.unique_path(options[:save], event[:name])
          job = tab.file_action(event[:request], "save", path)
          sleep(0.1) while job.running?
          puts "[saved] #{job.state} #{path} #{job.got} bytes #{job.error}"
        else
          tab.file_action(event[:request], "abort")
        end
        return
      when "load", "stopped"
        return
      when "live"
        puts "[live] #{event[:text]}"
      end
    end
    sleep(0.1)
  end
end

def print_document(document)
  puts "Title: #{document.title}"
  document.lines.each_with_index do |line, index|
    tags = line.enter.map { |entry| "[#{document.nodes[entry - 1].role}]" }
    tags << "<#{document.nodes[line.blk - 1].role}>" if line.blk > 0
    tags << "(#{line.row},#{line.col})" if line.tbl > 0
    owners = line.segs.map { |seg| seg.owner }.uniq.reject(&:zero?).map { |owner| "#{document.nodes[owner - 1].role}:#{document.nodes[owner - 1].name[0, 30]}" }
    puts format("%4d %s %s%s", index + 1, tags.join(" "), line.text, owners.empty? ? "" : "   {#{owners.join(" | ")}}")
  end
end

started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
tab = KlangtenWeb::Chrome.open_tab
puts "Chrome pid #{KlangtenWeb::Chrome.current_pid}, started in #{(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).round(2)} s"
begin
  ok, error = tab.navigate(url)
  puts "Navigation error: #{error}" unless ok
  wait_for_page(tab, options)
  document = tab.snapshot
  if options[:click]
    node = document.nodes.find { |entry| entry.name.downcase.include?(options[:click].downcase) }
    if node
      puts "Clicking #{node.role} #{node.name.inspect}: #{tab.click(node.backend).inspect}"
      sleep(0.5)
      wait_for_page(tab, options)
      document = tab.snapshot
    else
      puts "Nothing named #{options[:click].inspect}"
    end
  end
  if options[:type]
    node = document.nodes.find { |entry| %w[textbox searchbox combobox].include?(entry.role) }
    if node
      tab.focus(node.backend)
      tab.insert_text(options[:type])
      info = tab.focus_info
      puts "Focused: #{info && info["role"]} #{info && info["name"].inspect} value=#{info && info["value"].inspect}"
      tab.send_key(13, "\r")
      sleep(0.5)
      wait_for_page(tab, options)
      document = tab.snapshot
    end
  end
  print_document(document)
  info = tab.info
  puts "Address: #{info[:url]}"
ensure
  tab.close
  pid = KlangtenWeb::Chrome.current_pid
  KlangtenWeb::Chrome.shutdown
  puts "Chrome #{pid} closed: #{!KlangtenWeb::Chrome.pid_alive?(pid)}"
end
