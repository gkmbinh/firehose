require 'faye/websocket'
require 'json'
require "rack/utils"

module Firehose
  module Rack
    class Consumer
      class WebSocket
        # Setup a handler for the websocket connection.
        def call(env)
          ws = Faye::WebSocket.new(env)
          if enable_multiplexing?(env)
            MultiplexingHandler.new(ws)
          else
            Handler.new(ws)
          end
          ws.rack_response
        end

        def enable_multiplexing?(env)
          qs = env["QUERY_STRING"]
          return false if qs.empty?
          params = ::Rack::Utils.parse_nested_query(qs)
          params["multiplexing"] == "enabled"
        end

        # Determine if the rack request is a WebSocket request.
        def self.request?(env)
          Faye::WebSocket.websocket?(env)
        end

        class BaseHandler
          def initialize(ws)
            @ws = ws
            @req = ::Rack::Request.new ws.env
            # Setup the event handlers from this class.
            @ws.onopen    = method :open
            @ws.onclose   = method :close
            @ws.onerror   = method :error
            @ws.onmessage = method :message
          end

          def parse_message(event)
            JSON.parse(event.data, :symbolize_names => true) rescue {}
          end

          # Log errors if a socket fails. `close` will fire after this to clean up any
          # remaining connectons.
          def error(event)
            Firehose.logger.error "WS connection `#{@req.path}` error. Message: `#{event.message.inspect}`"
          end
        end

        # Manages connection state for the web socket that's connected
        # by the Consumer::WebSocket class. Deals with message sequence,
        # connection, failures, and subscription state.
        class Handler < BaseHandler
          # Subscribe the client to the channel on the server. Asks for
          # the last sequence for clients that reconnect.
          def subscribe(last_sequence)
            @subscribed = true
            @channel    = Server::Channel.new @req.path
            @deferrable = @channel.next_message last_sequence
            @deferrable.callback do |message, sequence|
              Firehose.logger.debug "WS sent `#{message}` to `#{@req.path}` with sequence `#{sequence}`"
              @ws.send wrap_frame(message, last_sequence)
              subscribe sequence
            end
            @deferrable.errback do |e|
              EM.next_tick { raise e.inspect } unless e == :disconnect
            end
          end

          # Manages messages sent from the connect client to the server. This is mostly
          # used to handle heart-beats that are designed to prevent the WebSocket connection
          # from timing out from inactivity.
          def message(event)
            msg = parse_message(event)
            seq = msg[:message_sequence]
            if msg[:ping] == 'PING'
              Firehose.logger.debug "WS ping received, sending pong"
              @ws.send JSON.generate :pong => 'PONG'
            elsif !@subscribed && seq.kind_of?(Integer)
              Firehose.logger.debug "Subscribing at message_sequence #{seq}"
              subscribe seq
            end
          end

          # Log a message that the client has connected.
          def open(event)
            Firehose.logger.debug "WebSocket subscribed to `#{@req.path}`. Waiting for message_sequence..."
          end

          # Log a message that hte client has disconnected and reset the state for the class. Clean
          # up the subscribers to the channels.
          def close(event)
            if @deferrable
              @deferrable.fail :disconnect
              @channel.unsubscribe(@deferrable) if @channel
            end
            Firehose.logger.debug "WS connection `#{@req.path}` closing. Code: #{event.code.inspect}; Reason #{event.reason.inspect}"
          end

          # Wrap a message in a sequence so that the client can record this and give us
          # the sequence when it reconnects.
          def wrap_frame(message, last_sequence)
            JSON.generate :message => message, :last_sequence => last_sequence
          end
        end

        class MultiplexingHandler < BaseHandler
          class Subscription < Struct.new(:channel, :deferrable)
            def close
              deferrable.fail :disconnect
              channel.unsubscribe(deferrable)
            end
          end

          def initialize(ws)
            super(ws)
            @subscriptions = {}
          end

          def message(event)
            msg = parse_message(event)

            if wanted_subscriptions = msg[:multiplex_subscribe]
              return subscribe_multiplexed(wanted_subscriptions)
            end

            if msg[:ping] == 'PING'
              Firehose.logger.debug "WS ping received, sending pong"
              return @ws.send JSON.generate :pong => 'PONG'
            end
          end

          def open(event)
            Firehose.logger.debug "Multiplexing Websocket connected: #{@req.path}"
          end

          def close(event)
            @subscriptions.each_value(&:close)
            @subscriptions.clear
          end

          def subscribe_multiplexed(subscriptions)
            subscriptions.each do |sub|
              channel, sequence = sub[:channel], sub[:message_sequence]
              next if channel.nil? || sequence.nil?

              Firehose.logger.debug "Subscribing multiplexed to: #{sub}"
              subscribe(channel, sequence)
            end
          end

          # Subscribe the client to the channel on the server. Asks for
          # the last sequence for clients that reconnect.
          def subscribe(channel_name, last_sequence)
            channel      = Server::Channel.new channel_name
            deferrable   = channel.next_message last_sequence
            subscription = Subscription.new(channel, deferrable)

            @subscriptions[channel_name] = subscription

            deferrable.callback do |message, sequence|
              Firehose.logger.debug "WS sent `#{message}` to `#{channel_name}` with sequence `#{sequence}`"
              @ws.send wrap_frame(channel_name, message, last_sequence)
              subscribe channel_name, sequence
            end

            deferrable.errback do |e|
              EM.next_tick { raise e.inspect } unless e == :disconnect
            end
          end

          # Wrap a message in a sequence so that the client can record this and give us
          # the sequence when it reconnects.
          def wrap_frame(channel, message, last_sequence)
            JSON.generate :channel => channel,
                          :message => message,
                          :last_sequence => last_sequence
          end
        end
      end
    end
  end
end
