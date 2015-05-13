require 'new_relic/agent/instrumentation'
require 'new_relic/agent/instrumentation/controller_instrumentation'
require 'new_relic/agent/instrumentation/sinatra/transaction_namer'

require 'roda'

module NewRelic
  module Agent
    module Instrumentation
      module Roda
        TransactionNamer = NewRelic::Agent::Instrumentation::Sinatra::TransactionNamer

        module RequestMethods
          include ::NewRelic::Agent::MethodTracer
          add_method_tracer :match_all

          private

          def if_match(args, &block)
            instrumented = proc do |*captures|
              params = { env.fetch('new_relic.roda').last => captures }
              @scope.perform_action_with_newrelic_trace(category: :controller, params: params) do
                yield(*captures)
              end
            end
            super(args, &instrumented)
          end

          def match_all(args)
            if all = super
              (env['new_relic.roda'] ||= [nil]) << args
            end
            all
          end

          def block_result(result)
            begin
              txn_name = _route_name
              unless txn_name.nil?
                ::NewRelic::Agent::Transaction.set_default_transaction_name(
                    "#{self.class.name}/#{txn_name}", :category => :sinatra)
              end
            rescue => e
              ::NewRelic::Agent.logger.debug("Failed during route_eval to set transaction name", e)
            end

            super
          end

          def _route_name
            "#{request_method} #{env.fetch('new_relic.roda',['/']).join('/')}"
          end
        end

        module InstanceMethods
          def self.included(base)
            base.include ::NewRelic::Agent::Instrumentation::ControllerInstrumentation
          end

          def call(&block)
            super
          rescue => error
            ::NewRelic::Agent.notice_error(error)
            raise error
          end

          def _route(&block)
            perform_action_with_newrelic_trace(:category => :controller,
                                               :params => @_request.params) do
              super
            end
          end

        end
      end
    end
  end
end

DependencyDetection.defer do
  @name = :roda

  depends_on do
    defined?(::Roda) && ! ::NewRelic::Control.instance['disable_roda'] && ! ENV['DISABLE_NEW_RELIC_RODA']
  end

  executes do
    NewRelic::Agent.logger.debug 'Installing Roda instrumentation'
    Roda::RodaPlugins.register_plugin(:new_relic, NewRelic::Agent::Instrumentation::Roda)
    Roda.plugin(:new_relic)
  end

  executes do
  end

  executes do
    NewRelic::Agent::Instrumentation::MiddlewareProxy.class_eval do
      def self.needs_wrapping?(target)
        (
          !target.respond_to?(:_nr_has_middleware_tracing) &&
          !is_sinatra_app?(target) &&
          !target.is_a?(Proc)
        )
      end
    end
  end
end
