module MessageStore
  module Postgres
    module Get
      Error = Class.new(RuntimeError)

      def self.included(cls)
        cls.class_exec do
          include MessageStore::Get

          extend Assure

          prepend Call
          prepend BatchSize

          dependency :session, Session

          abstract :sql_command
          abstract :parameters
          abstract :parameter_values
          abstract :last_position
          abstract :log_text
        end
      end

      module BatchSize
        def batch_size
          @batch_size ||= Defaults.batch_size
        end
      end

      def self.build(stream_name, **args)
        cls = specialization(stream_name)

        cls.assure(stream_name, args)

        session = args.delete(:session)

        cls.build(stream_name, **args).tap do |instance|
          instance.configure(session: session)
        end
      end

      def self.configure(receiver, stream_name, **args)
        attr_name = args.delete(:attr_name)
        attr_name ||= :get

        instance = build(stream_name, **args)
        receiver.public_send("#{attr_name}=", instance)
      end

      def configure(session: nil)
        Session.configure(self, session: session)
      end

      def self.call(stream_name, **args)
        position = args.delete(:position)
        instance = build(stream_name, **args)
        instance.(position)
      end

      module Call
        def call(position=nil, stream_name: nil)
          position ||= self.class::Defaults.position

          stream_name ||= self.stream_name

          logger.trace(tag: :get) { "Getting message data (#{log_text(stream_name, position)})" }

          result = get_result(stream_name, position)

          message_data = convert(result)

          logger.info(tag: :get) { "Finished getting message data (Count: #{message_data.length}, #{log_text(stream_name, position)})" }
          logger.info(tags: [:data, :message_data]) { message_data.pretty_inspect }

          message_data
        end
      end

      def get_result(stream_name, position)
        logger.trace(tag: :get) { "Getting result (#{log_text(stream_name, position)})" }

        parameter_values = parameter_values(stream_name, position)

        begin
          result = session.execute(sql_command, parameter_values)
        rescue PG::RaiseException => e
          raise_error(e)
        end

        logger.debug(tag: :get) { "Finished getting result (Count: #{result.ntuples}, #{log_text(stream_name, position)})" }

        result
      end

      def convert(result)
        logger.trace(tag: :get) { "Converting result to message data (Result Count: #{result.ntuples})" }

        message_data = result.map do |record|
          record['data'] = Deserialize.data(record['data'])
          record['metadata'] = Deserialize.metadata(record['metadata'])
          record['time'] = Time.utc_coerced(record['time'])

          MessageData::Read.build(record)
        end

        logger.debug(tag: :get) { "Converted result to message data (Message Data Count: #{message_data.length})" }

        message_data
      end

      def raise_error(pg_error)
        error_message = pg_error.message.gsub('ERROR:', '').strip

        error_class = nil

        case
        when error_message.start_with?('Correlation must be a category')
          error_class = Correlation::Error
        when error_message.start_with?('Consumer group size must not be less than 1') ||
            error_message.start_with?('Consumer group member must be less than the group size') ||
            error_message.start_with?('Consumer group member must not be less than 0') ||
            error_message.start_with?('Consumer group member and size must be specified')
          error_class = Get::Category::ConsumerGroup::Error
        when error_message.start_with?('Retrieval with SQL condition is not activated')
          error_class = Get::Condition::Error
        end

        if not error_message.nil?
          logger.error { error_message }
          raise error_class, error_message
        end

        raise pg_error
      end

      def self.specialization(stream_name)
        if StreamName.category?(stream_name)
          Category
        else
          Stream
        end
      end

      module Deserialize
        def self.data(serialized_data)
          return nil if serialized_data.nil?
          Transform::Read.(serialized_data, :json, MessageData::Hash)
        end

        def self.metadata(serialized_metadata)
          return nil if serialized_metadata.nil?
          Transform::Read.(serialized_metadata, :json, MessageData::Hash)
        end
      end

      module Time
        def self.utc_coerced(local_time)
          Clock::UTC.coerce(local_time)
        end
      end

      module Assure
        def assure(*)
        end
      end

      module Defaults
        def self.batch_size
          1000
        end
      end
    end
  end
end
