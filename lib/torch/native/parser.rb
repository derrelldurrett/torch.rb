module Torch
  module Native
    class Parser
      def initialize(functions)
        @functions = functions
        @name = @functions.first.ruby_name
        @min_args = @functions.map { |f| f.args.count { |a| a[:pos] && !a[:has_default] } }.min
        @max_args = @functions.map { |f| f.args.count { |a| a[:pos] } }.max
      end

      def parse(args, options)
        candidates = @functions.dup

        # remove nil
        while args.any? && args.last.nil?
          args.pop
        end

        # TODO account for args passed as options here
        if args.size < @min_args || args.size > @max_args
          expected = String.new(@min_args.to_s)
          expected += "..#{@max_args}" if @max_args != @min_args
          return {error: "wrong number of arguments (given #{args.size}, expected #{expected})"}
        end

        candidates.reject! { |f| args.size > f.args.size }

        # exclude functions missing required options
        candidates.reject! do |func|
          # TODO make more generic
          func.out? && !options[:out]
        end

        # handle out with multiple
        # there should only be one match, so safe to modify all
        out_func = candidates.find { |f| f.out? }
        if out_func && out_func.out_size > 1 && options[:out]
          out_args = out_func.args.last(2).map { |a| a[:name] }
          out_args.zip(options.delete(:out)).each do |k, v|
            options[k.to_sym] = v
          end
          candidates = [out_func]
        end

        # exclude functions where options don't match
        options.each do |k, v|
          candidates.select! do |func|
            func.args.any? { |a| a[:name] == k.to_s }
          end
          # TODO show all bad keywords at once like Ruby?
          return {error: "unknown keyword: #{k}"} if candidates.empty?
        end

        final_values = {}

        # check args
        candidates.select! do |func|
          good = true

          values = args.zip(func.args).map { |a, fa| [fa[:name], a] }.to_h
          values.merge!(options.map { |k, v| [k.to_s, v] }.to_h)
          func.args.each do |fa|
            values[fa[:name]] = fa[:default] if values[fa[:name]].nil?
          end

          arg_types = func.args.map { |a| [a[:name], a[:type]] }.to_h

          values.each_key do |k|
            v = values[k]
            t = arg_types[k].split("(").first

            good =
              case t
              when "Tensor"
                v.is_a?(Tensor)
              when "Tensor?"
                v.nil? || v.is_a?(Tensor)
              when "Tensor[]", "Tensor?[]"
                v.is_a?(Array) && v.all? { |v2| v2.is_a?(Tensor) }
              when "int"
                if k == "reduction"
                  v.is_a?(String)
                else
                  v.is_a?(Integer)
                end
              when "float"
                v.is_a?(Numeric)
              when /int\[.*\]/
                if v.is_a?(Integer)
                  size = t[4..-2]
                  raise Error, "Unknown size: #{size}. Please report a bug with #{@name}." unless size =~ /\A\d+\z/
                  v = [v] * size.to_i
                  values[k] = v
                end
                v.is_a?(Array) && v.all? { |v2| v2.is_a?(Integer) }
              when "Scalar"
                v.is_a?(Numeric)
              when "ScalarType?"
                v.nil?
              when "bool"
                v == true || v == false
              when "str"
                v.is_a?(String)
              else
                raise Error, "Unknown argument type: #{arg_types[k]}. Please report a bug with #{@name}."
              end

            if !good
              if candidates.size == 1
                k = "input" if k == "self"
                return {error: "#{@name}(): argument '#{k}' must be #{t}"}
              end
              break
            end
          end

          if good
            final_values = values
          end

          good
        end

        if candidates.size != 1
          raise Error, "This should never happen. Please report a bug with #{@name}."
        end

        func = candidates.first
        {
          name: func.cpp_name,
          args: func.args.map { |a| final_values[a[:name]] }
        }
      end
    end
  end
end
