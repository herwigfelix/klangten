# A part of Klangten, a modified version of Elten - EltenLink / Elten Network desktop client.
# Elten: Copyright (C) 2014-2026 Dawid Pieper
# Klangten modifications: Copyright (C) 2026 Felix Valentin Herwig (sixdotsIT)
# This file was added for Klangten (GNU GPL v3, section 5a).
# Klangten is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, version 3.
# Klangten is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.
# You should have received a copy of the GNU General Public License along with Klangten. If not, see <https://www.gnu.org/licenses/>.

# The engine of the full Klangten browser: Chrome for Testing without a window.
#
# Chrome is not shipped. On first use, after a question, the current stable
# "Chrome for Testing" build (the full browser - the smaller headless shell is
# refused by Google's sign-in and loops in Cloudflare checks) is downloaded from
# Google's official download list into <data>/browser/<version> and started
# with --headless=new. Its profile (cookies, sign-ins) is <data>/browser/profile.
#
# Klangten drives it through the Chrome DevTools Protocol: a WebSocket on
# 127.0.0.1 (websocket.rb) read by one thread of its own (Connection). Calls are
# synchronous with a time limit; events are collected per tab and fetched with
# Tab#poll from the scene thread. What has to be decided at once is decided by
# the reader thread itself: document responses that are not pages (media,
# PDFs, archives) are held back (Fetch domain) and reported as "file", so the
# screen can ask whether to play or save them; saving then streams the held
# response into a file, keeping cookies and form posts valid.
#
# Chrome is closed with Browser.close, never by a signal first: Chrome writes
# new cookies to disk only about every 30 seconds, and a killed Chrome loses a
# sign-in made shortly before. A Chrome left behind by an earlier Klangten is
# closed the same way on the next start.

require "json"
require "base64"
require "fileutils"
require "timeout"

module KlangtenWeb
  module Chrome
    VERSIONS_URL = "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json".freeze
    DOWNLOAD_HOSTS = %w[storage.googleapis.com edgedl.me.gvt1.com dl.google.com].freeze
    PACKAGE = "chrome".freeze
    CALL_TIMEOUT = 10.0
    # Answers to calls the reader thread sends itself (Fetch decisions) are
    # dropped by id; CDP ids must fit into 32 bits.
    OWN_ID_BASE = 1_500_000_000
    START_TIMEOUT = 25

    class Error < StandardError; end

    # Injected into every document: keeps new windows in the same tab and
    # reports changes (debounced) and live regions.
    INJECT = <<~JS.freeze
      (function () {
        if (window.__klangtenWatch) return;
        window.__klangtenWatch = true;
        var send = function (data) { try { window.__klangtenNotify(JSON.stringify(data)); } catch (e) {} };
        document.addEventListener('click', function (event) {
          var link = event.target && event.target.closest ? event.target.closest('a[target]') : null;
          if (link && ['_self', '_top', '_parent', ''].indexOf(link.target) < 0) link.target = '_self';
        }, true);
        try {
          window.open = function (address) {
            if (address) { try { location.href = new URL(address, location.href).href; } catch (e) {} }
            return window;
          };
        } catch (e) {}
        var liveQuery = '[aria-live]:not([aria-live="off"]),[role=alert],[role=status],[role=log]';
        var liveRegion = function (node) {
          var element = node && (node.nodeType === 1 ? node : node.parentElement);
          while (element) {
            if (element.matches && element.matches(liveQuery)) return element;
            element = element.parentElement;
          }
          return null;
        };
        var textOf = function (node) { return node.nodeType === 3 ? node.data : (node.innerText || node.textContent || ''); };
        var pending = null;
        var observer = new MutationObserver(function (records) {
          records.forEach(function (record) {
            if (record.type === 'attributes') return;
            var region = liveRegion(record.target);
            var text = '';
            if (region) {
              if (record.type === 'characterData') text = record.target.data;
              else record.addedNodes.forEach(function (node) { text += ' ' + textOf(node); });
            } else if (record.type === 'childList') {
              record.addedNodes.forEach(function (node) {
                if (node.nodeType === 1 && node.matches && node.matches('[role=alert],[role=status],[aria-live=assertive],[aria-live=polite]')) {
                  text += ' ' + textOf(node);
                  region = node;
                }
              });
            }
            text = (text || '').replace(/\\s+/g, ' ').trim();
            if (text && region) {
              var urgent = region.getAttribute('aria-live') === 'assertive' || region.getAttribute('role') === 'alert';
              send({ t: 'live', text: text.slice(0, 500), a: urgent ? 1 : 0 });
            }
          });
          if (!pending) pending = setTimeout(function () { pending = null; send({ t: 'mut' }); }, 300);
        });
        var watch = function () {
          try {
            observer.observe(document.documentElement || document, {
              childList: true, subtree: true, characterData: true, attributes: true,
              attributeFilter: ['aria-expanded', 'aria-checked', 'aria-selected', 'aria-pressed', 'aria-hidden',
                'hidden', 'open', 'disabled', 'class', 'value', 'aria-valuenow', 'aria-valuetext']
            });
          } catch (e) {}
        };
        if (document.documentElement) watch(); else document.addEventListener('DOMContentLoaded', watch);
      })();
    JS

    # The focused element, also inside shadow roots and same-origin frames.
    JS_FOCUSED = <<~JS.freeze
      (function () {
        var element = document.activeElement;
        for (var depth = 0; depth < 20 && element; depth++) {
          if (element.shadowRoot && element.shadowRoot.activeElement) { element = element.shadowRoot.activeElement; continue; }
          if (element.tagName === 'IFRAME' || element.tagName === 'FRAME') {
            try {
              var inner = element.contentDocument;
              if (inner && inner.activeElement) { element = inner.activeElement; continue; }
            } catch (e) {}
          }
          break;
        }
        return element;
      })()
    JS

    # Editing state of an element: value, caret, multi-line, password.
    JS_EDIT_STATE = <<~JS.freeze
      function () {
        var element = this, out = { tag: element.tagName || '', type: String(element.type || '') };
        var plain = ['checkbox', 'radio', 'button', 'submit', 'reset', 'image', 'file', 'range', 'color'];
        if ((element.tagName === 'INPUT' || element.tagName === 'TEXTAREA') && ('value' in element)) {
          if (plain.indexOf(out.type) < 0) {
            out.edit = 1;
            out.value = String(element.value);
            try { out.ss = element.selectionStart; out.se = element.selectionEnd; } catch (e) {}
            out.ml = element.tagName === 'TEXTAREA' ? 1 : 0;
            if (out.type === 'password') out.pw = 1;
          }
        } else if (element.isContentEditable) {
          out.edit = 1;
          out.ml = 1;
          out.value = element.innerText || '';
          try {
            var selection = element.ownerDocument.getSelection();
            if (selection && selection.rangeCount) {
              var range = selection.getRangeAt(0), before = range.cloneRange();
              before.selectNodeContents(element);
              before.setEnd(range.startContainer, range.startOffset);
              out.ss = before.toString().length;
              out.se = out.ss + range.toString().length;
            }
          } catch (e) {}
        }
        try {
          var active = element.getAttribute && element.getAttribute('aria-activedescendant');
          if (active) {
            var item = element.ownerDocument.getElementById(active);
            if (item) out.ad = (item.getAttribute('aria-label') || item.innerText || item.textContent || '').replace(/\\s+/g, ' ').trim();
          }
        } catch (e) {}
        return out;
      }
    JS

    # Options of a <select> or of an ARIA list box (also through aria-controls).
    JS_OPTIONS = <<~JS.freeze
      function () {
        var element = this, items = [];
        var clean = function (text) { return (text || '').replace(/\\s+/g, ' ').trim(); };
        if (element.tagName === 'SELECT') {
          for (var i = 0; i < element.options.length; i++) {
            var option = element.options[i];
            items.push({ text: clean(option.label || option.text), selected: option.selected, disabled: option.disabled });
          }
          return { native: true, multiple: element.multiple, items: items };
        }
        var owner = element.getAttribute('aria-controls') ? element.ownerDocument.getElementById(element.getAttribute('aria-controls')) : element;
        owner = owner || element;
        owner.querySelectorAll('[role=option]').forEach(function (option) {
          items.push({ text: clean(option.getAttribute('aria-label') || option.innerText),
            selected: option.getAttribute('aria-selected') === 'true', disabled: option.getAttribute('aria-disabled') === 'true' });
        });
        return { native: false, items: items };
      }
    JS

    JS_CHOOSE = <<~JS.freeze
      function (index) {
        var element = this;
        if (element.tagName === 'SELECT') {
          var option = element.options[index];
          if (!option) return false;
          if (element.multiple) option.selected = !option.selected; else element.selectedIndex = index;
          element.dispatchEvent(new Event('input', { bubbles: true }));
          element.dispatchEvent(new Event('change', { bubbles: true }));
          return true;
        }
        var owner = element.getAttribute('aria-controls') ? element.ownerDocument.getElementById(element.getAttribute('aria-controls')) : element;
        owner = owner || element;
        var target = owner.querySelectorAll('[role=option]')[index];
        if (!target) return false;
        var init = { bubbles: true, cancelable: true, view: window };
        target.dispatchEvent(new MouseEvent('mousedown', init));
        target.dispatchEvent(new MouseEvent('mouseup', init));
        target.click();
        return true;
      }
    JS

    # Whether a real mouse click at x, y reaches the element.
    JS_HIT_TEST = <<~JS.freeze
      function (x, y) {
        var element = this.nodeType === 3 ? this.parentElement : this;
        if (!element) return 'miss';
        if (window.top !== window) return 'frame';
        var hit = document.elementFromPoint(x, y);
        return hit && (hit === element || element.contains(hit) || hit.contains(element)) ? 'hit' : 'miss';
      }
    JS

    JS_CLICK = <<~JS.freeze
      function () {
        var element = this.nodeType === 3 ? this.parentElement : this;
        if (!element) return;
        var init = { bubbles: true, cancelable: true, view: window };
        try { element.dispatchEvent(new PointerEvent('pointerdown', init)); } catch (e) {}
        element.dispatchEvent(new MouseEvent('mousedown', init));
        try { element.dispatchEvent(new PointerEvent('pointerup', init)); } catch (e) {}
        element.dispatchEvent(new MouseEvent('mouseup', init));
        if (element.click) element.click(); else element.dispatchEvent(new MouseEvent('click', init));
      }
    JS

    JS_SELECTION = <<~JS.freeze
      (function () {
        var element = #{JS_FOCUSED.strip};
        try {
          if (element && ('selectionStart' in element) && element.value !== undefined && element.selectionEnd > element.selectionStart)
            return element.value.substring(element.selectionStart, element.selectionEnd);
        } catch (e) {}
        var owner = element && element.ownerDocument ? element.ownerDocument : document;
        return String(owner.getSelection() || '');
      })()
    JS

    # ------------------------------------------------------------ installing

    @install_mutex = Mutex.new

    class << self
      # Chrome for Testing's name of this system, or nil.
      def platform
        arm = RbConfig::CONFIG["host_cpu"].to_s =~ /arm|aarch64/i ? true : false
        case KlangtenWeb.platform_os
        when "osx" then arm ? "mac-arm64" : "mac-x64"
        when "windows"
          architecture = (ENV["PROCESSOR_ARCHITEW6432"] || ENV["PROCESSOR_ARCHITECTURE"]).to_s.upcase
          architecture == "X86" ? "win32" : "win64"
        when "linux" then arm ? nil : "linux64"
        end
      end

      def base_dir
        dir = File.join(KlangtenWeb.data_dir, "engine")
        FileUtils.mkdir_p(dir)
        dir
      end

      def profile_dir
        File.join(base_dir, "profile")
      end

      def current_version
        value = File.read(File.join(base_dir, "current")).strip
        value == "" ? nil : value
      rescue SystemCallError
        nil
      end

      def executable_for(version)
        target = platform
        return nil if target == nil || version.to_s == ""
        folder = File.join(base_dir, version, "chrome-#{target}")
        path = case KlangtenWeb.platform_os
               when "osx" then File.join(folder, "Google Chrome for Testing.app", "Contents", "MacOS", "Google Chrome for Testing")
               when "windows" then File.join(folder, "chrome.exe")
               else File.join(folder, "chrome")
               end
        File.file?(path) ? path : nil
      end

      def executable
        override = ENV["KLANGTEN_WEB_CHROME"].to_s
        return override if override != "" && File.file?(override)
        version = current_version
        version == nil ? nil : executable_for(version)
      end

      def installed?
        executable != nil
      end

      # The newest stable build: [version, download url].
      def latest(token: nil)
        body = KlangtenWeb.http_get(VERSIONS_URL, token: token) do |response, _url|
          raise Error, "version list: HTTP #{response.code}" unless response.is_a?(Net::HTTPSuccess)
          response.body.to_s
        end
        data = JSON.parse(body)
        stable = data.dig("channels", "Stable") || {}
        version = stable["version"].to_s
        entry = Array(stable.dig("downloads", PACKAGE)).find { |row| row.is_a?(Hash) && row["platform"] == platform }
        raise Error, "no Chrome for #{platform.inspect}" if version == "" || entry == nil
        url = entry["url"].to_s
        host = (URI.parse(url).host rescue "").to_s
        raise Error, "untrusted download address #{url}" unless url.start_with?("https://") && DOWNLOAD_HOSTS.include?(host)
        [version, url]
      end

      def update_available?(token: nil)
        version, = latest(token: token)
        version != current_version || !installed?
      end

      # Downloads and unpacks the current stable build (a worker thread; call
      # through EltenAPI::Tasks.run). progress: proc(percent, message).
      def install(token: nil, &progress)
        @install_mutex.synchronize do
          raise Error, "this system is not supported" if platform == nil
          version, url = latest(token: token)
          return version if current_version == version && executable_for(version) != nil
          archive = File.join(base_dir, "#{version}.zip")
          KlangtenWeb.http_download(url, archive, token: token) do |got, total|
            progress.call(total > 0 ? (got * 90 / total) : 0, got) if progress != nil
          end
          progress.call(92, nil) if progress != nil
          staging = File.join(base_dir, "#{version}.new")
          FileUtils.rm_rf(staging)
          extract(archive, staging, token)
          File.delete(archive) rescue nil
          destination = File.join(base_dir, version)
          shutdown
          FileUtils.rm_rf(destination)
          File.rename(staging, destination)
          raise Error, "the package holds no browser" if executable_for(version) == nil
          File.write(File.join(base_dir, "current"), version)
          Dir.children(base_dir).each do |name|
            next unless name =~ /\A\d/ && name != version
            FileUtils.rm_rf(File.join(base_dir, name)) rescue nil
          end
          progress.call(100, nil) if progress != nil
          KlangtenWeb.log_info("Browser: Chrome for Testing #{version} installed")
          version
        end
      ensure
        File.delete(archive) if archive != nil && File.exist?(archive) rescue nil
        FileUtils.rm_rf(staging) if staging != nil && File.exist?(staging) rescue nil
      end

      # Removes Chrome (and its profile with cookies and sign-ins).
      def uninstall
        shutdown
        FileUtils.rm_rf(base_dir)
      end

      def extract(archive, directory, token)
        FileUtils.mkdir_p(directory)
        # ditto keeps the symbolic links and permissions of the app bundle.
        if KlangtenWeb.osx? && File.executable?("/usr/bin/ditto")
          ok = system("/usr/bin/ditto", "-x", "-k", archive, directory, out: File::NULL, err: File::NULL)
          if ok
            system("/usr/bin/xattr", "-dr", "com.apple.quarantine", directory, out: File::NULL, err: File::NULL)
            return
          end
          FileUtils.rm_rf(directory)
          FileUtils.mkdir_p(directory)
        end
        require "zip"
        root = File.expand_path(directory)
        Zip::File.open(archive) do |zip|
          zip.each do |entry|
            token.raise_if_cancelled! if token != nil
            target = File.expand_path(entry.name, root)
            next unless target.start_with?(root + "/") || target.start_with?(root + File::SEPARATOR)
            if entry.directory?
              FileUtils.mkdir_p(target)
            elsif entry.symlink?
              next if KlangtenWeb.windows?
              FileUtils.mkdir_p(File.dirname(target))
              link = entry.get_input_stream(&:read).to_s
              File.delete(target) if File.symlink?(target) || File.exist?(target)
              File.symlink(link, target)
            elsif entry.file?
              FileUtils.mkdir_p(File.dirname(target))
              entry.get_input_stream do |input|
                File.open(target, "wb") do |file|
                  while (chunk = input.read(262_144)) && !chunk.empty?
                    file.write(chunk)
                  end
                end
              end
              mode = entry.unix_perms.to_i & 0o777
              File.chmod(mode, target) if !KlangtenWeb.windows? && mode != 0
            end
          end
        end
      end

      # ------------------------------------------------------------ running

      def browser
        @browser_mutex ||= Mutex.new
        @browser_mutex.synchronize do
          if @browser == nil || !@browser.alive?
            old = @browser
            @browser = nil
            old.shutdown rescue nil if old != nil
            @browser = Browser.new(KlangtenWeb.language)
          end
          @browser
        end
      end

      def running?
        @browser != nil && @browser.alive?
      end

      def current_pid
        @browser == nil ? nil : @browser.pid
      end

      # A new tab, or raises Error.
      def open_tab
        Tab.new(browser, KlangtenWeb.language)
      end

      def shutdown
        browser = @browser
        @browser = nil
        browser.shutdown if browser != nil
      rescue Exception => e
        KlangtenWeb.log_warning("Browser: shutdown failed: #{e.class}: #{e.message}")
      end

      # Deletes cookies and the cache.
      def clear_data
        return false if @browser == nil
        @browser.clear_data
      end

      def pid_alive?(pid)
        return false if pid.to_i <= 0
        Process.kill(0, pid.to_i)
        true
      rescue Errno::EPERM
        true
      rescue SystemCallError, RangeError
        false
      end
    end

    # --------------------------------------------------------- the connection

    class Connection
      attr_accessor :download_dir
      attr_reader :queues

      def initialize(socket)
        @socket = socket
        @mutex = Mutex.new
        @arrived = ConditionVariable.new
        @next_id = 1
        @own_id = OWN_ID_BASE
        @replies = {}
        @abandoned = {}
        @queues = {}
        @targets = {}
        @downloads = {}
        @alive = true
        @reader = Thread.new { read_loop }
        @reader.report_on_exception = false
      end

      def alive?
        @alive == true
      end

      def register(session, target)
        @mutex.synchronize do
          @targets[session] = target
          @queues[session] = []
        end
      end

      def unregister(session)
        @mutex.synchronize do
          @queues.delete(session)
          @targets.delete(session)
        end
      end

      def sessions
        @mutex.synchronize { @targets.keys }
      end

      # Sends a call and waits for its answer. stop: a proc checked while
      # waiting; when it returns true, the call is given up and nil returned.
      def call(method, params = {}, session = nil, timeout: CALL_TIMEOUT, stop: nil)
        raise Error, "the browser has ended" unless alive?
        id = @mutex.synchronize { (@next_id += 1) - 1 }
        message = { "id" => id, "method" => method, "params" => params || {} }
        message["sessionId"] = session if session != nil
        begin
          @socket.send_text(JSON.generate(message))
        rescue StandardError
          raise Error, "the browser has ended"
        end
        deadline = monotonic + timeout
        loop do
          @mutex.synchronize do
            if @replies.key?(id)
              reply = @replies.delete(id)
              raise Error, ((reply["error"] || {})["message"] || "error").to_s if reply.key?("error")
              return reply["result"] || {}
            end
            raise Error, "the browser has ended" unless alive?
            now = monotonic
            if now >= deadline
              @abandoned[id] = true
              raise Error, "#{method}: no answer"
            end
            @arrived.wait(@mutex, [0.05, deadline - now].min)
          end
          # Checked without the lock: the proc may look at the event queues.
          if stop != nil && stop.call
            @mutex.synchronize { @abandoned[id] = true unless @replies.delete(id) }
            return nil
          end
        end
      end

      def push(session, event)
        @mutex.synchronize { push_locked(session, event) }
      end

      def take(session)
        @mutex.synchronize do
          queue = @queues[session]
          return [] if queue == nil
          events = queue.dup
          queue.clear
          events
        end
      end

      def peek?(session)
        @mutex.synchronize { Array(@queues[session]).any? { |event| yield(event) } }
      end

      def close
        @alive = false
        @socket.close rescue nil
      end

      private

      def monotonic
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def push_locked(session, event)
        queue = @queues[session]
        return if queue == nil
        return if event[:type] == "mut" && queue.any? { |queued| queued[:type] == "mut" }
        queue << event if queue.size < 2000
      end

      def push_to(session, event)
        @mutex.synchronize do
          if session != nil && @queues.key?(session)
            push_locked(session, event)
          else
            @queues.each_key { |key| push_locked(key, event.dup) }
          end
        end
      end

      def send_own(method, params, session)
        id = @mutex.synchronize { @own_id += 1 }
        message = { "id" => id, "method" => method, "params" => params }
        message["sessionId"] = session if session != nil && session != ""
        @socket.send_text(JSON.generate(message))
      rescue StandardError
        nil
      end

      def read_loop
        while (raw = @socket.receive) != nil
          begin
            message = JSON.parse(raw)
          rescue JSON::ParserError
            next
          end
          id = message["id"]
          if id.is_a?(Integer)
            next if id >= OWN_ID_BASE
            @mutex.synchronize do
              if @abandoned.delete(id)
                next
              end
              @replies[id] = message
              @arrived.broadcast
            end
            next
          end
          begin
            event(message)
          rescue StandardError => e
            KlangtenWeb.log_warning("Browser: event #{message["method"]}: #{e.class}: #{e.message}")
          end
        end
      rescue Exception => e
        KlangtenWeb.log_warning("Browser: reader ended: #{e.class}: #{e.message}")
      ensure
        @alive = false
        @mutex.synchronize { @arrived.broadcast }
      end

      def session_of_frame(frame)
        return nil if frame.to_s == ""
        @mutex.synchronize { @targets.key(frame) }
      end

      def event(message)
        method = message["method"].to_s
        params = message["params"] || {}
        session = message["sessionId"].to_s
        main_frame = @mutex.synchronize { @targets[session] }.to_s
        case method
        when "Fetch.requestPaused"
          paused(params, session, main_frame)
        when "Runtime.bindingCalled"
          return unless params["name"] == "__klangtenNotify"
          data = JSON.parse(params["payload"].to_s) rescue nil
          return unless data.is_a?(Hash)
          if data["t"] == "mut"
            push(session, { type: "mut" })
          elsif data["t"] == "live"
            push(session, { type: "live", text: data["text"].to_s, assertive: data["a"] == 1 })
          end
        when "Page.frameNavigated"
          frame = params["frame"] || {}
          push(session, { type: "nav", url: frame["url"].to_s }) if frame["parentId"] == nil
        when "Page.navigatedWithinDocument"
          push(session, { type: "spa", url: params["url"].to_s }) if params["frameId"] == main_frame
        when "Page.frameStartedLoading"
          push(session, { type: "loading" }) if params["frameId"] == main_frame
        when "Page.frameStoppedLoading"
          push(session, { type: "stopped" }) if params["frameId"] == main_frame
        when "Page.domContentEventFired"
          push(session, { type: "dom" })
        when "Page.loadEventFired"
          push(session, { type: "load" })
        when "Page.javascriptDialogOpening"
          if params["type"] == "beforeunload"
            send_own("Page.handleJavaScriptDialog", { "accept" => true }, session)
          else
            push(session, { type: "dialog", kind: params["type"].to_s, message: params["message"].to_s, default: params["defaultPrompt"].to_s })
          end
        when "Inspector.targetCrashed"
          push(session, { type: "crash" })
        when "Browser.downloadWillBegin"
          # Browser-wide and without a session: the frame tells which tab
          # started it.
          guid = params["guid"].to_s
          name = params["suggestedFilename"].to_s
          name = "download" if name == ""
          owner = session_of_frame(params["frameId"])
          @mutex.synchronize { @downloads[guid] = [name, owner] }
          push_to(owner, { type: "download_started", name: name })
        when "Browser.downloadProgress"
          guid = params["guid"].to_s
          case params["state"]
          when "completed"
            name, owner = @mutex.synchronize { @downloads.delete(guid) } || ["download", nil]
            source = File.join(@download_dir.to_s, guid)
            target = KlangtenWeb.unique_path(KlangtenWeb.downloads_dir, name)
            begin
              FileUtils.mv(source, target)
              push_to(owner, { type: "downloaded", path: target })
            rescue StandardError => e
              push_to(owner, { type: "download_failed", name: name, error: e.message })
            end
          when "canceled"
            name, owner = @mutex.synchronize { @downloads.delete(guid) } || ["", nil]
            push_to(owner, { type: "download_failed", name: name })
          end
        end
      end

      def paused(params, session, main_frame)
        request = params["requestId"].to_s
        status = params["responseStatusCode"]
        if status == nil
          send_own("Fetch.continueRequest", { "requestId" => request }, session)
          return
        end
        status = status.to_i
        if params["frameId"].to_s != main_frame || (300..399).include?(status) || [204, 205].include?(status) || status >= 400
          send_own("Fetch.continueResponse", { "requestId" => request }, session)
          return
        end
        headers = {}
        Array(params["responseHeaders"]).each { |header| headers[header["name"].to_s.downcase] = header["value"].to_s }
        mime = headers["content-type"].to_s.split(";").first.to_s.strip.downcase
        disposition = headers["content-disposition"].to_s
        attachment = disposition.strip.downcase.start_with?("attachment")
        if Chrome.renderable?(mime) && !attachment
          send_own("Fetch.continueResponse", { "requestId" => request }, session)
          return
        end
        url = (params["request"] || {})["url"].to_s
        size = headers["content-length"].to_s =~ /\A\d+\z/ ? headers["content-length"].to_i : -1
        push(session, { type: "file", request: request, url: url, mime: mime, name: KlangtenWeb.file_name_for(disposition, url), size: size })
      end
    end

    # Whether Chrome should show a response of this type as a page.
    def self.renderable?(mime)
      mime = mime.to_s
      return true if mime == "" || mime.include?("html") || mime.include?("json")
      return true if %w[text/plain text/xml application/xml text/css text/javascript application/javascript].include?(mime)
      mime.end_with?("+xml") && mime != "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
    end

    # ------------------------------------------------------------ the browser

    class Browser
      attr_reader :connection, :major, :user_agent

      def initialize(language)
        executable = Chrome.executable
        raise Error, "the browser is not installed" if executable == nil
        base = Chrome.base_dir
        @profile, @temporary_profile = choose_profile(base)
        FileUtils.mkdir_p(@profile)
        @download_dir = File.join(base, "downloads")
        FileUtils.mkdir_p(@download_dir)
        port_file = File.join(@profile, "DevToolsActivePort")
        File.delete(port_file) if File.exist?(port_file)
        arguments = [executable]
        arguments << "--headless=new" if ENV["KLANGTEN_WEB_WINDOW"].to_s == ""
        arguments += [
          "--disable-blink-features=AutomationControlled",
          "--remote-debugging-port=0",
          "--user-data-dir=#{@profile}",
          "--no-first-run", "--no-default-browser-check",
          "--force-renderer-accessibility",
          "--window-size=1920,1080", "--screen-info={1920x1080}",
          # Sound of the page stays on, and pages may start it: Klangten's
          # clicks come through DevTools and are no user gesture for Chrome.
          "--autoplay-policy=no-user-gesture-required",
          "--disable-background-networking", "--disable-component-update",
          "--disable-features=IsolateOrigins,site-per-process,Translate,MediaRouter",
          "--disable-site-isolation-trials",
          "--password-store=basic", "--use-mock-keychain",
          "--lang=#{language}", "about:blank"
        ]
        # Klangten's own sound comes first on weak machines.
        arguments = ["nice", "-n", "10"] + arguments if KlangtenWeb.platform_os == "linux" && File.executable?("/usr/bin/nice")
        @pid = Process.spawn(*arguments, in: File::NULL, out: File::NULL, err: File::NULL)
        @waiter = Process.detach(@pid)
        File.write(File.join(base, "chrome.pid"), "#{@pid} #{Process.pid}") rescue nil
        port, path = wait_for_port(port_file)
        socket = KlangtenWeb::WebSocket.new("127.0.0.1", port, path)
        @connection = Connection.new(socket)
        @connection.download_dir = @download_dir
        product = @connection.call("Browser.getVersion")["product"].to_s
        @major = product.include?("/") ? product.split("/")[1].to_s.split(".").first : "140"
        @user_agent = Browser.user_agent_for(@major)
        begin
          @connection.call("Browser.setDownloadBehavior", { "behavior" => "allowAndName", "downloadPath" => @download_dir, "eventsEnabled" => true })
        rescue Error
        end
        KlangtenWeb.log_info("Browser: Chrome #{product} started (pid #{@pid})")
      rescue Exception
        kill_process
        raise
      end

      def self.user_agent_for(major)
        system = KlangtenWeb.windows? ? "Windows NT 10.0; Win64; x64" : (KlangtenWeb.osx? ? "Macintosh; Intel Mac OS X 10_15_7" : "X11; Linux x86_64")
        "Mozilla/5.0 (#{system}) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/#{major}.0.0.0 Safari/537.36"
      end

      def pid
        @pid
      end

      def alive?
        @connection != nil && @connection.alive? && @waiter != nil && @waiter.alive?
      end

      def clear_data
        ok = true
        begin
          @connection.call("Storage.clearCookies")
        rescue Error
          ok = false
        end
        @connection.sessions.each do |session|
          @connection.call("Network.clearBrowserCache", {}, session) rescue nil
        end
        ok
      end

      # Browser.close first: it saves the cookies. Only then by force.
      def shutdown
        if @connection != nil
          begin
            @connection.call("Browser.close", {}, nil, timeout: 1.5)
          rescue Error
          end
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep(0.05) while @waiter != nil && @waiter.alive? && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        kill_process if @waiter != nil && @waiter.alive?
        @connection.close if @connection != nil
        if @temporary_profile
          FileUtils.rm_rf(@profile) rescue nil
        else
          File.delete(File.join(Chrome.base_dir, "chrome.pid")) rescue nil
        end
      end

      private

      def kill_process
        return if @pid == nil
        Process.kill(KlangtenWeb.windows? ? "KILL" : "TERM", @pid) rescue nil
        @waiter.join(2) if @waiter != nil
      end

      def wait_for_port(port_file)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        loop do
          if File.file?(port_file)
            lines = File.read(port_file).split(/\r?\n/)
            return [lines[0].to_i, lines[1].to_s.strip] if lines.size >= 2 && lines[0].to_i > 0
          end
          raise Error, "the browser has ended" if !@waiter.alive?
          raise Error, "the browser does not answer" if Process.clock_gettime(Process::CLOCK_MONOTONIC) - started > START_TIMEOUT
          sleep(0.05)
        end
      end

      # A second Klangten that is still running keeps the profile; this one
      # then works in a temporary profile. A Chrome left behind by an ended
      # Klangten is closed properly first.
      def choose_profile(base)
        profile = Chrome.profile_dir
        pid_file = File.join(base, "chrome.pid")
        chrome_pid, owner_pid = File.read(pid_file).split.map(&:to_i) rescue [0, 0]
        if owner_pid.to_i > 0 && owner_pid != Process.pid && Chrome.pid_alive?(owner_pid) && Chrome.pid_alive?(chrome_pid)
          temporary = File.join(base, "profile-#{Process.pid}")
          return [temporary, true]
        end
        close_orphan(profile, chrome_pid) if chrome_pid.to_i > 0 && Chrome.pid_alive?(chrome_pid)
        File.delete(pid_file) if File.exist?(pid_file)
        [profile, false]
      end

      def close_orphan(profile, chrome_pid)
        begin
          lines = File.read(File.join(profile, "DevToolsActivePort")).split(/\r?\n/)
          socket = KlangtenWeb::WebSocket.new("127.0.0.1", lines[0].to_i, lines[1].to_s.strip, timeout: 3)
          socket.send_text(JSON.generate({ "id" => 1, "method" => "Browser.close" }))
          Timeout.timeout(3) { socket.receive } rescue nil
          socket.close
        rescue StandardError
        end
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
        sleep(0.1) while Chrome.pid_alive?(chrome_pid) && Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        if Chrome.pid_alive?(chrome_pid)
          Process.kill(KlangtenWeb.windows? ? "KILL" : "TERM", chrome_pid) rescue nil
          sleep(0.3)
        end
      end
    end

    # -------------------------------------------------------------- a tab

    class Tab
      attr_reader :target, :session

      def initialize(browser, language)
        @browser = browser
        @connection = browser.connection
        @target = @connection.call("Target.createTarget", { "url" => "about:blank" })["targetId"]
        @session = @connection.call("Target.attachToTarget", { "targetId" => @target, "flatten" => true })["sessionId"]
        @connection.register(@session, @target)
        %w[Page.enable DOM.enable Accessibility.enable].each { |method| call(method) }
        base = language.split("-").first
        # Only the list: Chrome adds the weights itself.
        languages = ([language, base, "en"].uniq).join(",")
        brands_version = browser.major.to_s
        begin
          call("Network.setUserAgentOverride", {
            "userAgent" => browser.user_agent,
            "acceptLanguage" => languages,
            "platform" => KlangtenWeb.windows? ? "Win32" : (KlangtenWeb.osx? ? "MacIntel" : "Linux x86_64"),
            "userAgentMetadata" => {
              "brands" => [{ "brand" => "Google Chrome", "version" => brands_version }, { "brand" => "Chromium", "version" => brands_version }, { "brand" => "Not=A?Brand", "version" => "24" }],
              "fullVersion" => "#{brands_version}.0.0.0",
              "fullVersionList" => [{ "brand" => "Google Chrome", "version" => "#{brands_version}.0.0.0" }, { "brand" => "Chromium", "version" => "#{brands_version}.0.0.0" }, { "brand" => "Not=A?Brand", "version" => "24.0.0.0" }],
              "platform" => KlangtenWeb.windows? ? "Windows" : (KlangtenWeb.osx? ? "macOS" : "Linux"),
              "platformVersion" => KlangtenWeb.windows? ? "10.0.0" : "14.0.0",
              "architecture" => Chrome.platform.to_s.include?("arm") ? "arm" : "x86",
              "model" => "", "mobile" => false
            }
          })
        rescue Error
        end
        # Without a window nothing has the focus; without a virtual
        # authenticator a passkey prompt (Google) waits forever.
        [["Emulation.setFocusEmulationEnabled", { "enabled" => true }],
         ["WebAuthn.enable", { "enableUI" => false }],
         ["WebAuthn.addVirtualAuthenticator", { "options" => { "protocol" => "ctap2", "transport" => "internal", "hasResidentKey" => true,
                                                               "hasUserVerification" => true, "isUserVerified" => false, "automaticPresenceSimulation" => true } }]].each do |method, params|
          call(method, params) rescue nil
        end
        # Runtime.enable is needed, or Chrome does not create the binding.
        call("Runtime.enable")
        call("Runtime.addBinding", { "name" => "__klangtenNotify" })
        call("Page.addScriptToEvaluateOnNewDocument", { "source" => INJECT })
        call("Page.setInterceptFileChooserDialog", { "enabled" => false }) rescue nil
        call("Fetch.enable", { "patterns" => [{ "resourceType" => "Document", "requestStage" => "Response" }] })
      rescue Exception
        @connection.unregister(@session) if @session != nil
        raise
      end

      def call(method, params = {}, timeout: CALL_TIMEOUT, stop: nil)
        @connection.call(method, params, @session, timeout: timeout, stop: stop)
      end

      def alive?
        @connection.alive?
      end

      def close
        @connection.call("Target.closeTarget", { "targetId" => @target }, nil, timeout: 3) rescue nil
        @connection.unregister(@session)
      end

      # [true, nil] or [false, error text].
      def navigate(url)
        waiting_file = proc { @connection.peek?(@session) { |event| event[:type] == "file" } }
        result = call("Page.navigate", { "url" => url }, timeout: 30, stop: waiting_file)
        error = (result || {})["errorText"].to_s
        return [false, error] if error != "" && error != "net::ERR_ABORTED"
        [true, nil]
      rescue Error => e
        [false, e.message]
      end

      def poll
        events = @connection.take(@session)
        events << { type: "crash" } unless @connection.alive?
        events
      end

      def snapshot
        snapshot = call("DOMSnapshot.captureSnapshot", { "computedStyles" => ["display"], "includeDOMRects" => false }, timeout: 30)
        display = AX.display_map(snapshot)
        nodes = Array(call("Accessibility.getFullAXTree", {}, timeout: 30)["nodes"])
        frames = {}
        begin
          tree = call("Page.getFrameTree")["frameTree"] || {}
          ids = []
          collect = lambda do |node, depth|
            next if depth > 8
            Array(node["childFrames"]).each do |child|
              id = (child["frame"] || {})["id"]
              ids << id if id != nil
              collect.call(child, depth + 1)
            end
          end
          collect.call(tree, 0)
          ids.first(40).each do |frame|
            owner = (call("DOM.getFrameOwner", { "frameId" => frame })["backendNodeId"] rescue nil).to_i
            next if owner == 0
            frame_nodes = (call("Accessibility.getFullAXTree", { "frameId" => frame }, timeout: 30)["nodes"] rescue nil)
            frames[owner] = frame_nodes if frame_nodes.is_a?(Array)
          end
        rescue Error
        end
        AX.linearize(nodes, frames, display)
      end

      def info
        out = {}
        begin
          target = @connection.call("Target.getTargetInfo", { "targetId" => @target })["targetInfo"] || {}
          out[:url] = target["url"].to_s
          out[:title] = target["title"].to_s
        rescue Error
        end
        begin
          history = call("Page.getNavigationHistory")
          current = history["currentIndex"].to_i
          count = Array(history["entries"]).size
          out[:can_back] = current > 0
          out[:can_forward] = current + 1 < count
        rescue Error
        end
        out
      end

      # [[{url, title, id}], current index (0-based)] or [[], 0].
      def history
        result = call("Page.getNavigationHistory")
        entries = Array(result["entries"]).map { |entry| { url: entry["url"].to_s, title: entry["title"].to_s, id: entry["id"] } }
        [entries, result["currentIndex"].to_i]
      rescue Error
        [[], 0]
      end

      def history_go(id)
        call("Page.navigateToHistoryEntry", { "entryId" => id })
        true
      rescue Error
        false
      end

      def reload
        call("Page.reload") rescue nil
      end

      def stop_loading
        call("Page.stopLoading") rescue nil
      end

      def click(backend)
        call("DOM.scrollIntoViewIfNeeded", { "backendNodeId" => backend }) rescue nil
        object = resolve(backend)
        point = nil
        begin
          quads = Array(call("DOM.getContentQuads", { "backendNodeId" => backend })["quads"])
          if !quads.empty? && quads[0].size == 8
            quad = quads[0]
            point = [(quad[0] + quad[2] + quad[4] + quad[6]) / 4.0, (quad[1] + quad[3] + quad[5] + quad[7]) / 4.0]
          end
        rescue Error
        end
        if point != nil
          x, y = point
          hit = (call_on(object, JS_HIT_TEST, [{ "value" => x }, { "value" => y }]) rescue "miss")
          if %w[hit frame].include?(hit)
            # A short pointer path before the click, as a hand would make.
            [4, 3, 2, 1].each do |step|
              call("Input.dispatchMouseEvent", { "type" => "mouseMoved", "x" => x - 12 * step, "y" => y - 5 * step, "button" => "none" })
              sleep(0.015)
            end
            call("Input.dispatchMouseEvent", { "type" => "mouseMoved", "x" => x, "y" => y, "button" => "none" })
            sleep(0.06)
            call("Input.dispatchMouseEvent", { "type" => "mousePressed", "x" => x, "y" => y, "button" => "left", "buttons" => 1, "clickCount" => 1, "force" => 0.5, "pointerType" => "mouse" })
            sleep(0.08)
            call("Input.dispatchMouseEvent", { "type" => "mouseReleased", "x" => x, "y" => y, "button" => "left", "buttons" => 0, "clickCount" => 1 })
            return [true, nil]
          end
        end
        call_on(object, JS_CLICK)
        [true, nil]
      rescue Error => e
        [false, e.message]
      end

      def focus(backend)
        call("DOM.scrollIntoViewIfNeeded", { "backendNodeId" => backend }) rescue nil
        call("DOM.focus", { "backendNodeId" => backend })
        true
      rescue Error
        false
      end

      def node_info(params)
        Array(call("Accessibility.getPartialAXTree", params)["nodes"]).each do |raw|
          next if raw["ignored"] == true
          return AX::Node.blank(backend: raw["backendDOMNodeId"].to_i, role: (raw["role"] || {})["value"].to_s,
                                name: AX.value_of(raw, "name"), value: AX.value_of(raw, "value"),
                                desc: AX.value_of(raw, "description"), props: AX.properties(raw))
        end
        nil
      rescue Error
        nil
      end

      def node_info_for(backend)
        node_info({ "backendNodeId" => backend, "fetchRelatives" => false })
      end

      def options(backend)
        call_on(resolve(backend), JS_OPTIONS)
      rescue Error
        nil
      end

      # index is 0-based.
      def choose_option(backend, index)
        call_on(resolve(backend), JS_CHOOSE, [{ "value" => index }]) == true
      rescue Error
        false
      end

      # modifiers: CDP bit mask (1 Alt, 2 Control, 4 Meta, 8 Shift).
      def send_key(vk, character = nil, modifiers = 0, numpad: false)
        key, code = Chrome.key_names(vk, character, numpad)
        text = nil
        if character == "\r"
          text = "\r"
        elsif character.to_s != "" && character.to_s =~ /\A[[:print:]]\z/ && (modifiers & 6 == 0 || modifiers & 1 != 0)
          text = character
        end
        down = { "type" => text ? "keyDown" : "rawKeyDown", "modifiers" => modifiers, "key" => key, "code" => code,
                 "windowsVirtualKeyCode" => vk, "nativeVirtualKeyCode" => vk }
        if text
          down["text"] = text
          down["unmodifiedText"] = text
        end
        commands = Chrome.mac_commands(vk, modifiers)
        down["commands"] = commands if !commands.empty?
        call("Input.dispatchKeyEvent", down)
        call("Input.dispatchKeyEvent", { "type" => "keyUp", "modifiers" => modifiers, "key" => key, "code" => code,
                                         "windowsVirtualKeyCode" => vk, "nativeVirtualKeyCode" => vk })
        true
      rescue Error
        false
      end

      def insert_text(text)
        call("Input.insertText", { "text" => text.to_s })
        true
      rescue Error
        false
      end

      def selected_text
        value = (call("Runtime.evaluate", { "expression" => JS_SELECTION, "returnByValue" => true })["result"] || {})["value"]
        value.is_a?(String) ? value : nil
      rescue Error
        nil
      end

      # What has the focus in the page: editing state plus role, name, value
      # and properties from the accessibility tree.
      def focus_info
        object = (call("Runtime.evaluate", { "expression" => JS_FOCUSED, "returnByValue" => false })["result"] || {})["objectId"]
        return nil if object == nil
        state = (call_on(object, JS_EDIT_STATE) rescue nil)
        state = {} unless state.is_a?(Hash)
        node = node_info({ "objectId" => object, "fetchRelatives" => false })
        if node != nil
          state["id"] = node.backend
          state["role"] = node.role
          state["name"] = node.name
          state["axvalue"] = node.value if node.value != ""
          state["desc"] = node.desc if node.desc != ""
          state["p"] = node.props
        end
        call("Runtime.releaseObject", { "objectId" => object }) rescue nil
        state
      rescue Error
        nil
      end

      def dialog_answer(accept, text = nil)
        params = { "accept" => accept == true }
        params["promptText"] = text if text != nil
        call("Page.handleJavaScriptDialog", params)
      rescue Error
        nil
      end

      def evaluate(script)
        (call("Runtime.evaluate", { "expression" => script, "returnByValue" => true, "userGesture" => true })["result"] || {})["value"]
      rescue Error
        nil
      end

      # For a "file" event: "abort", or "save" to path (returns a SaveJob that
      # runs on its own thread).
      def file_action(request, action, path = nil)
        if action == "save"
          job = SaveJob.new(path)
          thread = Thread.new { save_body(request, job) }
          thread.report_on_exception = false
          return job
        end
        call("Fetch.failRequest", { "requestId" => request, "errorReason" => "Aborted" }) rescue nil
        nil
      end

      private

      def resolve(backend)
        object = (call("DOM.resolveNode", { "backendNodeId" => backend })["object"] || {})["objectId"]
        raise Error, "the element is gone" if object == nil
        object
      end

      def call_on(object, function, arguments = [])
        result = call("Runtime.callFunctionOn", { "objectId" => object, "functionDeclaration" => function, "arguments" => arguments,
                                                  "returnByValue" => true, "awaitPromise" => false, "userGesture" => true })
        raise Error, (result["exceptionDetails"]["text"] || "script error").to_s if result["exceptionDetails"]
        (result["result"] || {})["value"]
      end

      def save_body(request, job)
        stream = call("Fetch.takeResponseBodyAsStream", { "requestId" => request })["stream"]
        raise Error, "no data stream" if stream == nil
        File.open(job.path, "wb") do |file|
          loop do
            if job.cancel
              call("IO.close", { "handle" => stream }) rescue nil
              raise Error, "cancelled"
            end
            chunk = call("IO.read", { "handle" => stream, "size" => 1 << 20 }, timeout: 120)
            data = chunk["data"].to_s
            bytes = chunk["base64Encoded"] ? Base64.decode64(data) : data.b
            file.write(bytes)
            job.got += bytes.bytesize
            break if chunk["eof"]
          end
        end
        call("IO.close", { "handle" => stream }) rescue nil
        job.state = :done
      rescue Exception => e
        File.delete(job.path) if File.exist?(job.path.to_s) rescue nil
        job.error = e.message
        job.state = job.cancel ? :cancelled : :error
      ensure
        call("Fetch.failRequest", { "requestId" => request, "errorReason" => "Aborted" }) rescue nil
      end
    end

    class SaveJob
      attr_accessor :state, :got, :total, :path, :error, :cancel

      def initialize(path)
        @state = :running
        @got = 0
        @total = -1
        @path = path
        @error = ""
        @cancel = false
      end

      def running?
        @state == :running
      end
    end

    # ---------------------------------------------------------------- keys

    NAMED_KEYS = {
      8 => %w[Backspace Backspace], 9 => %w[Tab Tab], 27 => %w[Escape Escape], 32 => [" ", "Space"],
      33 => %w[PageUp PageUp], 34 => %w[PageDown PageDown], 35 => %w[End End], 36 => %w[Home Home],
      37 => %w[ArrowLeft ArrowLeft], 38 => %w[ArrowUp ArrowUp], 39 => %w[ArrowRight ArrowRight],
      40 => %w[ArrowDown ArrowDown], 45 => %w[Insert Insert], 46 => %w[Delete Delete]
    }.freeze

    # DOM key and code of a Windows virtual key.
    def self.key_names(vk, character, numpad = false)
      return ["Enter", numpad ? "NumpadEnter" : "Enter"] if vk == 13
      return NAMED_KEYS[vk] if NAMED_KEYS.key?(vk)
      printable = character.to_s != "" && character.to_s =~ /\A[[:print:]]\z/
      return [printable ? character : vk.chr.downcase, "Key#{vk.chr}"] if vk.between?(65, 90)
      return [printable ? character : vk.chr, "Digit#{vk.chr}"] if vk.between?(48, 57)
      return ["F#{vk - 111}", "F#{vk - 111}"] if vk.between?(112, 123)
      [character.to_s, ""]
    end

    # Headless Chrome on macOS has no key bindings: text fields move the caret
    # only with editing commands sent along. Both keyboard schemes of Klangten
    # are understood (Control or Command, Option for words).
    def self.mac_commands(vk, modifiers)
      return [] unless KlangtenWeb.osx?
      shift = modifiers & 8 != 0
      control = modifiers & 2 != 0
      command = modifiers & 4 != 0
      option = modifiers & 1 != 0
      word = (control && !command) || (option && !control && !command)
      line = command && !control
      pick = lambda { |plain, selecting| [shift ? selecting : plain] }
      case vk
      when 8
        return ["deleteToBeginningOfLine"] if line
        return [word ? "deleteWordBackward" : "deleteBackward"]
      when 46
        return ["deleteToEndOfLine"] if line
        return [word ? "deleteWordForward" : "deleteForward"]
      when 37
        return pick.call("moveToBeginningOfLine", "moveToBeginningOfLineAndModifySelection") if line
        return word ? pick.call("moveWordLeft", "moveWordLeftAndModifySelection") : pick.call("moveLeft", "moveLeftAndModifySelection")
      when 39
        return pick.call("moveToEndOfLine", "moveToEndOfLineAndModifySelection") if line
        return word ? pick.call("moveWordRight", "moveWordRightAndModifySelection") : pick.call("moveRight", "moveRightAndModifySelection")
      when 38
        return pick.call("moveToBeginningOfDocument", "moveToBeginningOfDocumentAndModifySelection") if line
        return pick.call("moveToBeginningOfParagraph", "moveToBeginningOfParagraphAndModifySelection") if word
        return pick.call("moveUp", "moveUpAndModifySelection")
      when 40
        return pick.call("moveToEndOfDocument", "moveToEndOfDocumentAndModifySelection") if line
        return pick.call("moveToEndOfParagraph", "moveToEndOfParagraphAndModifySelection") if word
        return pick.call("moveDown", "moveDownAndModifySelection")
      when 36
        return control ? pick.call("moveToBeginningOfDocument", "moveToBeginningOfDocumentAndModifySelection") : pick.call("moveToBeginningOfLine", "moveToBeginningOfLineAndModifySelection")
      when 35
        return control ? pick.call("moveToEndOfDocument", "moveToEndOfDocumentAndModifySelection") : pick.call("moveToEndOfLine", "moveToEndOfLineAndModifySelection")
      when 33
        return pick.call("pageUp", "pageUpAndModifySelection")
      when 34
        return pick.call("pageDown", "pageDownAndModifySelection")
      when 65
        return ["selectAll"] if control || command
      when 90
        return [shift ? "redo" : "undo"] if control || command
      when 89
        return ["redo"] if control
      end
      []
    end
  end
end
