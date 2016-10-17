module ExceptionNotifier
  class SlackNotifier < BaseNotifier
    include ExceptionNotifier::BacktraceCleaner

    attr_accessor :notifier

    def initialize(options)
      super
      begin
        @ignore_data_if = options[:ignore_data_if]
        @backtrace_lines = options[:backtrace_lines]

        webhook_url = options.fetch(:webhook_url)
        @message_opts = options.fetch(:additional_parameters, {})
        @notifier = Slack::Notifier.new webhook_url, options
      rescue
        @notifier = nil
      end
    end

    def call(exception, options={})
      exception_name = "*#{exception.class.to_s =~ /^[aeiou]/i ? 'An' : 'A'}* `#{exception.class.to_s}`"

      if options[:env].nil?
        data = options[:data] || {}
        text = "#{exception_name} *occured in background*\n"
      else
        env = options[:env]
        data = (env['exception_notifier.exception_data'] || {}).merge(options[:data] || {})

        kontroller = env['action_controller.instance']
        request_uri = env['REQUEST_URI']
        if env['REQUEST_METHOD'] == 'GET'
          uri = Addressable::URI.parse(request_uri)
          sanitized_params = {}
          unless uri.query_values.empty?
            uri.query_values.each do |field, value|
              value = 'FILTERED' if Rails.application.config.filter_parameters.include? field.to_sym
              sanitized_params[field] = value
            end
          end
          uri.query_values = sanitized_params
          request_uri = uri.to_s
        end

        text = "#{exception_name} *occurred while* `#{env['REQUEST_METHOD']} <#{request_uri}>`"
        text += " *was processed by* `#{kontroller.controller_name}##{kontroller.action_name}`" if kontroller
        text += "\n"
      end

      clean_message = exception.message.gsub("`", "'")
      fields = [ { title: 'Exception', value: clean_message} ]

      fields.push({ title: 'Hostname', value: Socket.gethostname })

      if exception.backtrace
        formatted_backtrace = @backtrace_lines ? "```#{exception.backtrace.first(@backtrace_lines).join("\n")}```" : "```#{exception.backtrace.join("\n")}```"
        fields.push({ title: 'Backtrace', value: formatted_backtrace })
      end

      unless data.empty?
        deep_reject(data, @ignore_data_if) if @ignore_data_if.is_a?(Proc)
        data_string = data.map{|k,v| "#{k}: #{v}"}.join("\n")
        fields.push({ title: 'Data', value: "```#{data_string}```" })
      end

      attchs = [color: 'danger', text: text, fields: fields, mrkdwn_in: %w(text fields)]

      if valid?
        send_notice(exception, options, clean_message, @message_opts.merge(attachments: attchs)) do |msg, message_opts|
          @notifier.ping '', message_opts
        end
      end
    end

    protected

    def valid?
      !@notifier.nil?
    end

    def deep_reject(hash, block)
      hash.each do |k, v|
        if v.is_a?(Hash)
          deep_reject(v, block)
        end

        if block.call(k, v)
          hash.delete(k)
        end
      end
    end

  end
end
