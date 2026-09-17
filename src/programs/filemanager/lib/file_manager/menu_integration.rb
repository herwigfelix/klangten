module FileManagerPlaylist
  class MenuIntegration
    def initialize(scene_class:, menu_module:, action_id:, label:, visible: nil,
                   main_visible: nil, menu_visible: nil, &open_action)
      @scene_class = scene_class
      @menu_module = menu_module
      @action_id = action_id
      @label = label
      fallback_visibility = visible || proc { true }
      @main_visible = main_visible || fallback_visibility
      @menu_visible = menu_visible || fallback_visibility
      @open_action = open_action
      @original_construct = nil
      @construct_visibility = nil
      @installed_construct = nil
      @main_action_registered = false
      @installed = false
    end

    def install
      return true if @installed
      refresh
      install_global_menu
      @installed = true
      true
    rescue Exception => e
      uninstall
      log_error("Cannot install playlist menu integration", e)
      false
    end

    def uninstall
      uninstall_main_action
      uninstall_global_menu
      @installed = false
      true
    rescue Exception => e
      log_error("Cannot uninstall playlist menu integration", e)
      false
    end

    def call_original(receiver, defaults, force_context)
      @original_construct.bind(receiver).call(defaults, force_context: force_context)
    end

    def append_playlist_option(menu)
      return if menu == nil || !menu_visible?
      action = @open_action
      menu.option(@label.call) { action.call }
    end

    def refresh
      if main_visible?
        install_main_action if !@main_action_registered
      else
        uninstall_main_action if @main_action_registered
      end
      true
    end

    private

    def install_main_action
      return if @scene_class == nil || !@scene_class.respond_to?(:register_specialaction)
      action = @open_action
      @scene_class.register_specialaction(@action_id, @label.call) { action.call }
      @main_action_registered = true
    end

    def uninstall_main_action
      return if @scene_class == nil || !@scene_class.respond_to?(:unregister_specialaction)
      @scene_class.unregister_specialaction(@action_id)
      @main_action_registered = false
    end

    def main_visible?
      @main_visible.call == true
    rescue Exception
      false
    end

    def menu_visible?
      @menu_visible.call == true
    rescue Exception
      false
    end

    def install_global_menu
      return if @menu_module == nil
      singleton = class << @menu_module; self; end
      return if !singleton.method_defined?(:construct)
      @original_construct = singleton.instance_method(:construct)
      @construct_visibility = method_visibility(singleton, :construct)
      integration = self
      singleton.define_method(:construct) do |defaults = true, force_context: false|
        result = integration.call_original(self, defaults, force_context)
        if result == true && defaults == true
          integration.append_playlist_option(instance_variable_get(:@menu))
        end
        result
      end
      singleton.send(@construct_visibility, :construct)
      @installed_construct = singleton.instance_method(:construct)
    end

    def uninstall_global_menu
      return if @menu_module == nil || @original_construct == nil
      singleton = class << @menu_module; self; end
      if singleton.instance_method(:construct) == @installed_construct
        singleton.define_method(:construct, @original_construct)
        singleton.send(@construct_visibility, :construct)
      end
      @original_construct = nil
      @installed_construct = nil
      @construct_visibility = nil
    end

    def method_visibility(singleton, name)
      return :private if singleton.private_method_defined?(name)
      return :protected if singleton.protected_method_defined?(name)
      :public
    end

    def log_error(message, error)
      Log.warning("#{message}: #{error.class}: #{error.message}") if defined?(Log)
    rescue Exception
    end
  end
end
