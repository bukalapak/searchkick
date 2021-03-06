# based on https://gist.github.com/mnutt/566725
require "active_support/core_ext/module/attr_internal"

module Searchkick
  module QueryWithInstrumentation
    def execute_search
      name = searchkick_klass ? "#{searchkick_klass.name} Search" : "Search"
      event = {
        name: name,
        body: params,
        body_size: params.to_json.size
      }
      ActiveSupport::Notifications.instrument("search.searchkick", event) do
        super
      end
    end
  end

  module SearchkickWithInstrumentation
    def multi_search(searches)
      body = searches.map{ |q| "#{q.params.except(:body).to_json}\n#{q.body.to_json}" }.join("\n")
      event = {
        name: "Multi Search",
        body: body,
        body_size: body.size
      }
      ActiveSupport::Notifications.instrument("multi_search.searchkick", event) do
        super
      end
    end

    def perform_items(items)
      event = {
        name: "Bulk",
        body_size: items.to_json.size,
        body: items
      }
      ActiveSupport::Notifications.instrument("request.searchkick", event) do
        super
      end
    end
  end

  # https://github.com/rails/rails/blob/master/activerecord/lib/active_record/log_subscriber.rb
  class LogSubscriber < ActiveSupport::LogSubscriber
    def self.runtime=(value)
      Thread.current[:searchkick_runtime] = value
    end

    def self.runtime
      Thread.current[:searchkick_runtime] ||= 0
    end

    def self.reset_runtime
      rt = runtime
      self.runtime = 0
      rt
    end

    def search(event)
      self.class.runtime += event.duration
      return unless logger.debug?

      payload = event.payload
      name = "#{payload[:name]} (#{event.duration.round(1)}ms)"
      type = payload[:body][:type]
      index = payload[:body][:index].is_a?(Array) ? payload[:body][:index].join(",") : payload[:body][:index]

      # no easy way to tell which host the client will use
      host = Searchkick.client.transport.hosts.first
      debug "  #{color(name, YELLOW, true)}  curl #{host[:protocol]}://#{host[:host]}:#{host[:port]}/#{CGI.escape(index)}#{type ? "/#{type.map { |t| CGI.escape(t) }.join(',')}" : ''}/_search?pretty -d '#{payload[:body].to_json}'"
    end

    def request(event)
      self.class.runtime += event.duration
      return unless logger.debug?

      payload = event.payload
      name = "#{payload[:name]} (#{event.duration.round(1)}ms)"

      debug "  #{color(name, YELLOW, true)}  #{payload.except(:name).to_json}"
    end

    def multi_search(event)
      self.class.runtime += event.duration
      return unless logger.debug?

      payload = event.payload
      name = "#{payload[:name]} (#{event.duration.round(1)}ms)"

      # no easy way to tell which host the client will use
      host = Searchkick.client.transport.hosts.first
      debug "  #{color(name, YELLOW, true)}  curl #{host[:protocol]}://#{host[:host]}:#{host[:port]}/_msearch?pretty -d '#{payload[:body]}'"
    end
  end

  # https://github.com/rails/rails/blob/master/activerecord/lib/active_record/railties/controller_runtime.rb
  module ControllerRuntime
    extend ActiveSupport::Concern

    protected

    attr_internal :searchkick_runtime

    def process_action(action, *args)
      # We also need to reset the runtime before each action
      # because of queries in middleware or in cases we are streaming
      # and it won't be cleaned up by the method below.
      Searchkick::LogSubscriber.reset_runtime
      super
    end

    def cleanup_view_runtime
      searchkick_rt_before_render = Searchkick::LogSubscriber.reset_runtime
      runtime = super
      searchkick_rt_after_render = Searchkick::LogSubscriber.reset_runtime
      self.searchkick_runtime = searchkick_rt_before_render + searchkick_rt_after_render
      runtime - searchkick_rt_after_render
    end

    def append_info_to_payload(payload)
      super
      payload[:searchkick_runtime] = (searchkick_runtime || 0) + Searchkick::LogSubscriber.reset_runtime
    end

    module ClassMethods
      def log_process_action(payload)
        messages = super
        runtime = payload[:searchkick_runtime]
        messages << ("Searchkick: %.1fms" % runtime.to_f) if runtime.to_f > 0
        messages
      end
    end
  end
end
Searchkick::Query.send(:prepend, Searchkick::QueryWithInstrumentation)
Searchkick.singleton_class.send(:prepend, Searchkick::SearchkickWithInstrumentation)
Searchkick::LogSubscriber.attach_to :searchkick
ActiveSupport.on_load(:action_controller) do
  include Searchkick::ControllerRuntime
end
