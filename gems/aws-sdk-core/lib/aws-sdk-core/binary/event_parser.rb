module Aws
  module Binary
    # @api private
    class EventParser

      include Seahorse::Model::Shapes

      # @param [Class] parser_class
      # @param [Seahorse::Model::ShapeRef] rules (of eventstream member)
      # @param [Seahorse::Model::ShapeRef] output_ref
      def initialize(parser_class, rules, output_ref)
        @parser_class = parser_class
        @rules = rules
        @output_ref = output_ref
      end

      # Parse raw event message into event struct
      # based on its ShapeRef
      #
      # @return [Struct] Event Struct
      def apply(raw_event)
        parse(raw_event)
      end

      private

      def parse(raw_event)
        message_type = raw_event.headers.delete(":message-type")
        if message_type
          case message_type.value
          when 'error'
            parse_error_event(raw_event)
          when 'event'
            parse_event(raw_event)
          when 'exception'
            # TODO need to test
            parse_exception(raw_event)
          else
            raise Aws::Errors::EventStreamParserError.new(
              'Unrecognized :message-type value for the event')
          end
        else
          # no :message-type header, regular event by default
          parse_event(raw_event)
        end
      end

      def parse_exception(raw_event)
        exception_type = raw_event.headers.delete(":exception-type").value
        name, ref = @rules.shape.member_by_location_name(exception_type)
        # exception lives in payload implictly
        exception = parse_payload(raw_event.payload.read, ref)
        exception.event_type = name
        exception
      end

      def parse_error_event(raw_event)
        error_code = raw_event.headers.delete(":error-code")
        error_message = raw_event.headers.delete(":error-message")
        Aws::Errors::EventError.new(
          :error,
          error_code ? error_code.value : error_code,
          error_message ? error_message.value : error_message
        )
      end

      def parse_event(raw_event)
        event_type = raw_event.headers.delete(":event-type").value
        # content_type = raw_event.headers.delete(":content-type").value

        if event_type == 'initial-response'
          event = Struct.new(:event_type, :response).new
          event.event_type = :initial_response
          event.response = parse_payload(raw_event.payload.read, @output_ref)
          return event
        end

        # locate event from eventstream
        name, ref = @rules.shape.member_by_location_name(event_type)
        raise "Failed to locate event shape for the event" unless ref.event

        event = ref.shape.struct_class.new

        explicit_payload = false
        implicit_payload_members = {}
        ref.shape.members.each do |member_name, member_ref|
          unless member_ref.eventheader
            if member_ref.eventpayload
              explicit_payload = true
            else
              implicit_payload_members[member_name] = member_ref
            end
          end
        end

        # handle implicit payload
        if !explicit_payload && !implicit_payload_members.empty?
          if implicit_payload_members.size > 1
            event = parse_payload(raw_event.payload.read, ref)
          else
            m_name, m_ref = implicit_payload_members.first
            parse_payload_member(event, raw_event.payload, m_name, m_ref)
          end
        end
        event.event_type = name

        # locate payload and headers in the event
        ref.shape.members.each do |member_name, member_ref|
          if member_ref.eventheader
            # allow incomplete event members in response
            if raw_event.headers.key?(member_ref.location_name)
              event.send("#{member_name}=", raw_event.headers[member_ref.location_name].value)
            end
          elsif member_ref.eventpayload
            parse_payload_member(event, raw_event.payload, member_name, member_ref)
          end
        end
        event
      end

      def parse_payload_member(event, payload, name, ref)
        eventpayload_streaming?(ref) ?
         event.send("#{name}=", payload) :
         event.send("#{name}=", parse_payload(payload.read, ref))
        event
      end

      def eventpayload_streaming?(ref)
        BlobShape === ref.shape || StringShape === ref.shape
      end

      def parse_payload(body, rules)
        @parser_class.new(rules).parse(body) if body.size > 0
      end

    end

  end
end
