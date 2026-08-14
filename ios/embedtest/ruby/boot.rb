out = ENV["ELTEN_TEST_OUT"] || "/tmp/elten_test.txt"
log = []; w = lambda { |m| log << m.to_s; File.write(out, log.join("\n")+"\n") rescue nil }
ENV["ELTEN_LAUNCHER_PLATFORM"]="ios"; ENV["ELTEN_BOOT_STOP_BEFORE_MAIN"]="1"
ENV["ELTEN_DATA_DIR"]=File.join(File.dirname(out),"eltendata")
require 'rbconfig' rescue nil; require 'rubygems' rescue nil
app=File.join(__dir__,"elten-app")
begin; load File.join(app,"elten.rb"); rescue SystemExit; end
w.call("core loaded (185 files)")

# what main.rb does first: make the EltenAPI mixin global
class Object; include EltenAPI; end
# capture speech / silence audio hardware (define AFTER include so these win)
$spoken = []
class Object
  def speak(text, *a, **k); $spoken << text.to_s; text; end
  def play_sound(*a, **k); nil; end
  def speech_wait(*a); nil; end
  def play_file(*a, **k); nil; end
end
w.call("EltenAPI mixed in; Configuration=#{defined?(Configuration)} ListBox=#{defined?(ListBox)} loop_update=#{respond_to?(:loop_update, true)}")

begin
  $mainthread = Thread.current; $currentthread = $mainthread
  $scenes ||= []; $activecontrols ||= []; $lastactivecontrols ||= []
  $reset=false; $exitproc=false; $exit=false
  Configuration.volume = 50 rescue nil
  EltenWindow.ensure_window; EltenWindow.show; IOSWindowNative.set_active(true)

  items = ["Forum", "Messages", "Contacts", "Conferences", "Settings"]
  lst = ListBox.new(items, header: "Main menu", index: 0, quiet: false)
  w.call("ListBox created index=#{lst.index}; opening speech=#{$spoken.last(2).inspect}")

  seen = [lst.index]; before = $spoken.size
  4.times do |i|
    IOSTouchInput.perform(:swipe_down)     # gesture -> Down arrow
    8.times { loop_update(false); lst.update }
    seen << lst.index
    w.call("swipe_down ##{i+1}: index=#{lst.index} last_spoke=#{$spoken.last.inspect}")
  end
  IOSTouchInput.perform(:swipe_up)
  8.times { loop_update(false); lst.update }
  w.call("swipe_up: index=#{lst.index} last_spoke=#{$spoken.last.inspect}")

  moved = seen.uniq.size > 1
  spoke_items = items.any? { |it| $spoken.include?(it) }
  w.call("")
  w.call("RESULT moved=#{moved} path=#{seen.inspect} spoke_item_names=#{spoke_items} total_utterances=#{$spoken.size-before}")
  w.call((moved && spoke_items) ? "✅ REAL ELTEN EVENT LOOP RUNS ON iOS: gesture -> loop_update -> ListBox -> speech" : "PARTIAL")
rescue Exception => e
  w.call("EXCEPTION #{e.class}: #{e.message}")
  (e.backtrace||[]).first(8).each { |b| w.call("  "+b.to_s.sub(app+"/","")) }
end
