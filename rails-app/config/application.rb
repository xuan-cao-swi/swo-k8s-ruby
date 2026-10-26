require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

# Requires the gems listed in Gemfile in order; solarwinds_apm is last.
Bundler.require(*Rails.groups)

module RailsSwoDemo
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true
    config.autoload_lib(ignore: %w[tasks])
  end
end
