# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# Headset and media buttons on macOS (see src/eapi/mediabuttons.rb): the
# remote commands of the MediaPlayer framework (media keys, AirPods, the
# Now Playing menu). A small Objective-C class made at run time receives them
# on the app thread and hands their code to a queue. macOS gives the buttons
# to the app that plays last, so the now-playing state is kept up to date.

module KlangtenMediaButtons
  module MacBackend
    PTR = Fiddle::TYPE_VOIDP
    MEDIA_PLAYER = "/System/Library/Frameworks/MediaPlayer.framework/MediaPlayer".freeze
    # MPRemoteCommandCenter property -> button code
    COMMANDS = {
      "togglePlayPauseCommand" => 1, "playCommand" => 2, "pauseCommand" => 3,
      "nextTrackCommand" => 4, "previousTrackCommand" => 5, "stopCommand" => 6
    }.freeze
    # MPNowPlayingPlaybackState
    STATES = { 0 => 3, 1 => 1, 2 => 2 }.freeze

    @queue = Queue.new

    class << self
      def supported?
        objc != nil && media_player != nil && defined?(OSXWindowNative) != nil
      rescue Exception
        false
      end

      def enable(on)
        OSXWindowNative.perform_on_app_thread(true) { on ? attach : detach }
      rescue Exception => e
        Log.error("Media buttons (macOS): #{e.class}: #{e.message}") if defined?(Log)
      end

      def poll
        @queue.pop(true)
      rescue ThreadError
        0
      end

      def now_playing(title, state)
        OSXWindowNative.perform_on_app_thread(false) do
          center = send_id(cls("MPNowPlayingInfoCenter"), "defaultCenter")
          next if center.to_i == 0
          if state.to_i == 0
            send_void(center, "setNowPlayingInfo:", 0)
          else
            info = send_id(cls("NSMutableDictionary"), "dictionary")
            send_void(info, "setObject:forKey:", nsstring(title.to_s == "" ? "Klangten" : title.to_s), nsstring("title"))
            send_void(info, "setObject:forKey:", nsstring("Klangten"), nsstring("artist"))
            rate = send_id(cls("NSNumber"), "numberWithDouble:", state.to_i == 1 ? 1.0 : 0.0, [Fiddle::TYPE_DOUBLE])
            send_void(info, "setObject:forKey:", rate, nsstring("MPNowPlayingInfoPropertyPlaybackRate"))
            send_void(center, "setNowPlayingInfo:", info)
          end
          send_void(center, "setPlaybackState:", STATES[state.to_i] || 3, [Fiddle::TYPE_SIZE_T])
        end
      rescue Exception => e
        Log.error("Media buttons (macOS): #{e.class}: #{e.message}") if defined?(Log)
      end

      private

      def attach
        return if @attached
        center = send_id(cls("MPRemoteCommandCenter"), "sharedCommandCenter")
        return if center.to_i == 0
        target = handler
        COMMANDS.each do |property, code|
          command = send_id(center, property)
          next if command.to_i == 0
          send_void(command, "setEnabled:", 1, [Fiddle::TYPE_CHAR])
          send_void(command, "addTarget:action:", target, sel("klangtenButton#{code}:"))
        end
        @attached = true
      end

      def detach
        return if !@attached
        center = send_id(cls("MPRemoteCommandCenter"), "sharedCommandCenter")
        COMMANDS.each_key do |property|
          command = send_id(center, property)
          next if command.to_i == 0
          send_void(command, "removeTarget:", handler)
          send_void(command, "setEnabled:", 0, [Fiddle::TYPE_CHAR])
        end
        send_void(send_id(cls("MPNowPlayingInfoCenter"), "defaultCenter"), "setNowPlayingInfo:", 0)
        @attached = false
      end

      # One object with a method per button; each returns
      # MPRemoteCommandHandlerStatusSuccess (0).
      def handler
        return @handler if @handler != nil
        name = "KlangtenMediaButtons_#{Process.pid}"
        klass = objc_allocate_class_pair.call(cls("NSObject"), name.b + "\0", 0)
        raise "objc_allocateClassPair failed" if klass.to_i == 0
        @closures = COMMANDS.values.map do |code|
          closure = Fiddle::Closure::BlockCaller.new(Fiddle::TYPE_LONG_LONG, [PTR, PTR, PTR]) do |_self, _cmd, _event|
            @queue << code
            0
          end
          ok = class_add_method.call(klass, sel("klangtenButton#{code}:"), closure, "q@:@\0")
          raise "class_addMethod failed" if ok.to_i == 0
          closure
        end
        objc_register_class_pair.call(klass)
        @handler = send_id(klass, "new")
      end

      def nsstring(text)
        send_id(cls("NSString"), "stringWithUTF8String:", text.to_s.encode("UTF-8", invalid: :replace, undef: :replace) + "\0")
      end

      def objc
        return @objc if defined?(@objc)
        @objc = Fiddle.dlopen("/usr/lib/libobjc.A.dylib")
      rescue Exception
        @objc = nil
      end

      def media_player
        return @media_player if defined?(@media_player)
        @media_player = Fiddle.dlopen(MEDIA_PLAYER)
      rescue Exception
        @media_player = nil
      end

      def cls(name)
        @get_class ||= Fiddle::Function.new(objc["objc_getClass"], [PTR], PTR)
        @get_class.call(name.to_s + "\0")
      end

      def sel(name)
        @sel_register ||= Fiddle::Function.new(objc["sel_registerName"], [PTR], PTR)
        @sel_register.call(name.to_s + "\0")
      end

      def objc_allocate_class_pair
        @allocate ||= Fiddle::Function.new(objc["objc_allocateClassPair"], [PTR, PTR, Fiddle::TYPE_SIZE_T], PTR)
      end

      def objc_register_class_pair
        @register ||= Fiddle::Function.new(objc["objc_registerClassPair"], [PTR], Fiddle::TYPE_VOID)
      end

      def class_add_method
        @add_method ||= Fiddle::Function.new(objc["class_addMethod"], [PTR, PTR, PTR, PTR], Fiddle::TYPE_CHAR)
      end

      def msg_send(types, ret)
        @msg_send ||= {}
        @msg_send[[types, ret]] ||= Fiddle::Function.new(objc["objc_msgSend"], [PTR, PTR] + types, ret)
      end

      def send_id(receiver, selector, *args)
        types = args.last.is_a?(Array) ? args.pop : Array.new(args.size, PTR)
        msg_send(types, PTR).call(receiver, sel(selector), *args)
      end

      def send_void(receiver, selector, *args)
        types = args.last.is_a?(Array) ? args.pop : Array.new(args.size, PTR)
        msg_send(types, Fiddle::TYPE_VOID).call(receiver, sel(selector), *args)
      end
    end
  end
end
