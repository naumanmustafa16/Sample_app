# frozen_string_literal: true

require "set"

module ActiveSupport
  # Error generated by +delegate+ when a method is called on +nil+ and +allow_nil+
  # option is not used.
  class DelegationError < NoMethodError
    class << self
      def nil_target(method_name, target) # :nodoc:
        new("#{method_name} delegated to #{target}, but #{target} is nil")
      end
    end
  end

  module Delegation # :nodoc:
    RUBY_RESERVED_KEYWORDS = %w(__ENCODING__ __LINE__ __FILE__ alias and BEGIN begin break
    case class def defined? do else elsif END end ensure false for if in module next nil
    not or redo rescue retry return self super then true undef unless until when while yield)
    RESERVED_METHOD_NAMES = (RUBY_RESERVED_KEYWORDS + %w(_ arg args block)).to_set.freeze

    class << self
      def generate(owner, methods, location: nil, to: nil, prefix: nil, allow_nil: nil, nilable: true, private: nil, as: nil, signature: nil)
        unless to
          raise ArgumentError, "Delegation needs a target. Supply a keyword argument 'to' (e.g. delegate :hello, to: :greeter)."
        end

        if prefix == true && /^[^a-z_]/.match?(to)
          raise ArgumentError, "Can only automatically set the delegation prefix when delegating to a method."
        end

        method_prefix = \
          if prefix
            "#{prefix == true ? to : prefix}_"
          else
            ""
          end

        location ||= caller_locations(1, 1).first
        file, line = location.path, location.lineno

        receiver = if to.is_a?(Module)
          if to.name.nil?
            raise ArgumentError, "Can't delegate to anonymous class or module: #{to}"
          end

          unless Inflector.safe_constantize(to.name).equal?(to)
            raise ArgumentError, "Can't delegate to detached class or module: #{to.name}"
          end

          "::#{to.name}"
        else
          to.to_s
        end
        receiver = "self.#{receiver}" if RESERVED_METHOD_NAMES.include?(receiver)

        explicit_receiver = false
        receiver_class = if as
          explicit_receiver = true
          as
        elsif to.is_a?(Module)
          to.singleton_class
        elsif receiver == "self.class"
          nilable = false # self.class can't possibly be nil
          owner.singleton_class
        end

        method_def = []
        method_names = []

        method_def << "self.private" if private

        methods.each do |method|
          method_name = prefix ? "#{method_prefix}#{method}" : method
          method_names << method_name.to_sym

          # Attribute writer methods only accept one argument. Makes sure []=
          # methods still accept two arguments.
          definition = \
            if signature
              signature
            elsif /[^\]]=\z/.match?(method)
              "arg"
            else
              method_object = if receiver_class
                begin
                  receiver_class.public_instance_method(method)
                rescue NameError
                  raise if explicit_receiver
                  # Do nothing. Fall back to `"..."`
                end
              end

              if method_object
                parameters = method_object.parameters

                if parameters.map(&:first).intersect?([:opt, :rest, :keyreq, :key, :keyrest])
                  "..."
                else
                  defn = parameters.filter_map { |type, arg| arg if type == :req }
                  defn << "&"
                  defn.join(", ")
                end
              else
                "..."
              end
            end

          # The following generated method calls the target exactly once, storing
          # the returned value in a dummy variable.
          #
          # Reason is twofold: On one hand doing less calls is in general better.
          # On the other hand it could be that the target has side-effects,
          # whereas conceptually, from the user point of view, the delegator should
          # be doing one call.
          if nilable == false
            method_def <<
              "def #{method_name}(#{definition})" <<
              "  (#{receiver}).#{method}(#{definition})" <<
              "end"
          elsif allow_nil
            method = method.to_s

            method_def <<
              "def #{method_name}(#{definition})" <<
              "  _ = #{receiver}" <<
              "  if !_.nil? || nil.respond_to?(:#{method})" <<
              "    _.#{method}(#{definition})" <<
              "  end" <<
              "end"
          else
            method = method.to_s
            method_name = method_name.to_s

            method_def <<
              "def #{method_name}(#{definition})" <<
              "  _ = #{receiver}" <<
              "  _.#{method}(#{definition})" <<
              "rescue NoMethodError => e" <<
              "  if _.nil? && e.name == :#{method}" <<
              "    raise ::ActiveSupport::DelegationError.nil_target(:#{method_name}, :'#{receiver}')" <<
              "  else" <<
              "    raise" <<
              "  end" <<
              "end"
          end
        end
        owner.module_eval(method_def.join(";"), file, line)
        method_names
      end

      def generate_method_missing(owner, target, allow_nil: nil)
        target = target.to_s
        target = "self.#{target}" if RESERVED_METHOD_NAMES.include?(target) || target == "__target"

        if allow_nil
          owner.module_eval <<~RUBY, __FILE__, __LINE__ + 1
            def respond_to_missing?(name, include_private = false)
              # It may look like an oversight, but we deliberately do not pass
              # +include_private+, because they do not get delegated.

              return false if name == :marshal_dump || name == :_dump
              #{target}.respond_to?(name) || super
            end

            def method_missing(method, ...)
              __target = #{target}
              if __target.nil? && !nil.respond_to?(method)
                nil
              elsif __target.respond_to?(method)
                __target.public_send(method, ...)
              else
                super
              end
            end
          RUBY
        else
          owner.module_eval <<~RUBY, __FILE__, __LINE__ + 1
            def respond_to_missing?(name, include_private = false)
              # It may look like an oversight, but we deliberately do not pass
              # +include_private+, because they do not get delegated.

              return false if name == :marshal_dump || name == :_dump
              #{target}.respond_to?(name) || super
            end

            def method_missing(method, ...)
              __target = #{target}
              if __target.nil? && !nil.respond_to?(method)
                raise ::ActiveSupport::DelegationError.nil_target(method, :'#{target}')
              elsif __target.respond_to?(method)
                __target.public_send(method, ...)
              else
                super
              end
            end
          RUBY
        end
      end
    end
  end
end
