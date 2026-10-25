# frozen_string_literal: true

module Buzz
  # Loads the module's app/ directories (models, services, jobs, controllers,
  # views) into the host app and plugs it into the few core hook points:
  #
  #   * routes      config/routes/buzz.rb, drawn by `draw(:buzz)` in the host's routes
  #   * navigation  one ModuleRegistry entry (Team -> People)
  #   * permissions one group on the Permissions screen (buzz.read, buzz.post)
  #   * browser     its Stimulus controller and stylesheet, pinned and precompiled here
  #
  # Not isolated on purpose: its pages render inside Rupert's shell and use the
  # host's helpers and route names, like every other page.
  class Engine < ::Rails::Engine
    engine_name 'buzz'

    PERMISSIONS = ['buzz.read', 'buzz.post'].freeze

    initializer 'buzz.assets' do |app|
      app.config.assets.paths << root.join('app/javascript') << root.join('app/assets/stylesheets')
      app.config.assets.precompile += ['buzz/buzz_chat_controller.js', 'buzz/chat.css']
    end

    initializer 'buzz.importmap', before: 'importmap' do |app|
      app.config.importmap.paths << root.join('config/importmap.rb')
      app.config.importmap.cache_sweepers << root.join('app/javascript')
    end

    # Registries live in reloadable app/ classes, so register again after each reload.
    config.to_prepare do
      ModuleRegistry.register(
        ModuleRegistry::Entry.new(key: 'buzz', name: 'Buzz', path: -> { buzz_chat_path }, permission: 'buzz.read', position: 85.6),
        area: 'team', group: 'People'
      )
      User.register_permission_group(area: 'Team chat (Buzz)', permissions: Buzz::Engine::PERMISSIONS)
    end
  end
end
