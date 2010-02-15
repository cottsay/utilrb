require 'utilrb/common'
require 'utilrb/object/singleton_class'
require 'utilrb/kernel/with_module'

module Kernel
    def load_dsl_filter_backtrace(file, full_backtrace = false, *exceptions)
        our_frame_pos = caller.size - 1

        yield

    rescue Exception => e
        if exceptions.any? { |e_class| e.kind_of?(e_class) }
            raise e
        end

        raise e if full_backtrace

        backtrace = e.backtrace.dup
        message   = e.message.dup

        # Filter out the message ... it can contain backtrace information as
        # well (!)
        message = message.split("\n").map do |line|
            if line =~ /^.*:\d+(:.*)$/
                backtrace.unshift line
                nil
            else
                line
            end
        end.compact.join("\n")


        if message.empty?
            message = backtrace.shift
            if message =~ /^(\s*[^\s]+:\d+:)\s*(.*)/
                location = $1
                message  = $2
                backtrace.unshift location
            else
                backtrace.unshift message
            end
        end

        filtered_backtrace = backtrace[0, backtrace.size - our_frame_pos].
            map do |line|
                if line =~ /load_dsl_file.*(method_missing|send)/
                    next
                end

                if line =~ /^(.*)\(eval\):(\d+)(:.*)?/
                    line_prefix  = $1
                    line_number  = $2
                    line_message = $3
                    if line_message =~ /_dsl_/ || line_message =~ /with_module/
                        line_message = ""
                    end

                    result = "#{line_prefix}#{file}:#{line_number}#{line_message}"
                else
                    if line =~ /(load_dsl_file\.rb|with_module\.rb):\d+:/
                        next
                    else
                        result = line
                    end
                end
                result

            end.compact


        backtrace = (filtered_backtrace[0, 1] + filtered_backtrace + backtrace[(backtrace.size - our_frame_pos)..-1])
        raise e, message, backtrace
    end

    def eval_dsl_block(block, proxied_object, context, full_backtrace, *exceptions)
        load_dsl_filter_backtrace(nil, full_backtrace, *exceptions) do
            proxied_object.with_module(*context, &block)
            true
        end
    end

    # Load the given file by eval-ing it in the provided binding. The
    # originality of this method is to translate errors that are detected in the
    # eval'ed code into 
    #
    # The caller of this method should call it at the end of its definition
    # file, or the translation method may not be robust at all
    def eval_dsl_file(file, proxied_object, context, full_backtrace, *exceptions, &block)
        if $LOADED_FEATURES.include?(file)
            return false
        elsif !File.readable?(file)
            raise ArgumentError, "#{file} does not exist"
        end

        loaded_file = file.gsub(/^#{Regexp.quote(Dir.pwd)}\//, '')
        load_dsl_filter_backtrace(file, full_backtrace, *exceptions) do
            file_content = File.read(file)
            sandbox = with_module(*context) do
                Class.new do
                    attr_reader :main_object
                    def initialize(main_object)
                        @main_object = main_object
                    end

                    def method_missing(*m, &block)
                        main_object.send(*m, &block)
                    end

                    class_eval <<-EOD
                    def __dsl_content; #{file_content}
                    end
                    EOD
                end
            end
            sandbox = sandbox.new(proxied_object)

            sandbox.with_module(*context) do
                __dsl_content
            end
            $LOADED_FEATURES << file
            true
        end
    end

    # Load the given file by eval-ing it in the provided binding. The
    # originality of this method is to translate errors that are detected in the
    # eval'ed code into 
    #
    # The caller of this method should call it at the end of its definition
    # file, or the translation method may not be robust at all
    def load_dsl_file(file, binding, full_backtrace, *exceptions)
        loaded_file = file.gsub(/^#{Regexp.quote(Dir.pwd)}\//, '')
        caller_string = caller(1)[0].split(':')
        eval_file = caller_string[0]
        eval_line = Integer(caller_string[1])

        if !File.readable?(file)
            raise ArgumentError, "#{file} does not exist"
        end
        Kernel.eval(File.read(file), binding)

    rescue *exceptions
        e = $!
        new_backtrace = e.backtrace.map do |line|
            if line =~ /^(#{Regexp.quote(eval_file)}:)(\d+)(.*)$/
                before, line_number, rest = $1, Integer($2), $3
                if line_number > eval_line
                    if rest =~ /:in `[^']+'/
                        rest = $'
                    end
                    newline = "#{File.expand_path(loaded_file)}:#{line_number - eval_line + 1}#{rest}"

                    if !full_backtrace
                        raise e, e.message, [newline]
                    else newline
                    end
                else line
                end
            else
                line
            end
        end
        raise e, e.message, new_backtrace
    end
end
