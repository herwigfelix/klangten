module FileManagerPlaylist
  class MainTabIntegration
    TAB = :filemanager_playlist
    CORE_METHODS = %i[
      main_sections focus_current_control say_current_option update_current_main_control
    ].freeze
    HELPER_METHOD = :filemanager_playlist_tab_control

    def initialize(scene_class:, visible:, control:)
      @scene_class = scene_class
      @visible = visible
      @control_provider = control
      @originals = {}
      @visibilities = {}
      @scenes = []
      @installed = false
    end

    def install
      return true if @installed
      return false if CORE_METHODS.any? { |name| !method_available?(name) }
      remember_methods
      integration = self
      originals = @originals

      @scene_class.define_method(:main_sections) do
        sections = Array(originals[:main_sections].bind(self).call).dup
        sections << MainTabIntegration::TAB if integration.visible? && !sections.include?(MainTabIntegration::TAB)
        sections
      end

      @scene_class.define_method(HELPER_METHOD) do
        integration.control_for(self)
      end

      @scene_class.define_method(:focus_current_control) do
        if current_main_section == MainTabIntegration::TAB && integration.visible?
          integration.control_for(self)&.focus
        else
          originals[:focus_current_control].bind(self).call
        end
      end

      @scene_class.define_method(:say_current_option) do
        if current_main_section == MainTabIntegration::TAB && integration.visible?
          integration.control_for(self)&.sayoption
        else
          originals[:say_current_option].bind(self).call
        end
      end

      @scene_class.define_method(:update_current_main_control) do
        if current_main_section == MainTabIntegration::TAB && integration.visible?
          integration.control_for(self)&.update
        else
          originals[:update_current_main_control].bind(self).call
        end
      end

      @installed = true
      true
    rescue Exception => e
      clear_scene_controls
      restore_methods
      log_error("Cannot install playlist main tab", e)
      false
    end

    def uninstall
      return false if !@installed && @originals.empty?
      clear_scene_controls
      restore_methods
      @installed = false
      true
    rescue Exception => e
      log_error("Cannot uninstall playlist main tab", e)
      false
    end

    def visible?
      @visible.call == true
    rescue Exception
      false
    end

    def control_for(scene)
      return nil if !visible?
      @scenes << scene if !@scenes.include?(scene)
      current = scene.instance_variable_get(:@filemanager_playlist_tab)
      control = @control_provider.call(scene, current)
      scene.instance_variable_set(:@filemanager_playlist_tab, control)
      control
    rescue Exception => e
      log_error("Cannot build playlist main tab", e)
      nil
    end

    private

    def clear_scene_controls
      @scenes.each do |scene|
        %i[@filemanager_playlist_tab @filemanager_playlist_tab_controller].each do |name|
          scene.remove_instance_variable(name) if scene.instance_variable_defined?(name)
        end
      end
      @scenes.clear
    end

    def method_available?(name)
      @scene_class.method_defined?(name) ||
        @scene_class.private_method_defined?(name) ||
        @scene_class.protected_method_defined?(name)
    end

    def remember_methods
      (CORE_METHODS + [HELPER_METHOD]).each do |name|
        if method_available?(name)
          @originals[name] = @scene_class.instance_method(name)
          @visibilities[name] = method_visibility(name)
        else
          @originals[name] = nil
        end
      end
    end

    def method_visibility(name)
      return :private if @scene_class.private_method_defined?(name)
      return :protected if @scene_class.protected_method_defined?(name)
      :public
    end

    def restore_methods
      @originals.each do |name, original|
        if original == nil
          @scene_class.send(:remove_method, name) if method_available?(name)
        else
          @scene_class.define_method(name, original)
          @scene_class.send(@visibilities[name], name)
        end
      end
      @originals.clear
      @visibilities.clear
    end

    def log_error(message, error)
      Log.warning("#{message}: #{error.class}: #{error.message}") if defined?(Log)
    rescue Exception
    end
  end
end
