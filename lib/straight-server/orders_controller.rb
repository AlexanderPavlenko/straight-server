require_relative './throttler'

module StraightServer

  class OrdersController

    attr_reader :response

    def initialize(env)
      @env          = env
      @params       = env.params
      @method       = env['REQUEST_METHOD']
      @request_path = env['REQUEST_PATH'].split('/').delete_if { |s| s.nil? || s.empty? }
    end

    def create

      unless @gateway.check_signature
        ip = @env['HTTP_X_FORWARDED_FOR'].to_s
        ip = @env['REMOTE_ADDR'] if ip.empty?
        if StraightServer::Throttler.new(@gateway.id).deny?(ip)
          StraightServer.logger.warn message = "Too many requests, please try again later"
          return [429, {}, message]
        end
      end

      begin

        # This is to inform users of previous version of a deprecated param
        # It will have to be removed at some point.
        if @params['order_id']
          return [409, {}, "Error: order_id is no longer a valid param. Use keychain_id instead and consult the documentation." ]
        end

        order_data = {
          amount:           @params['amount'], # this is satoshi
          currency:         @params['currency'],
          btc_denomination: @params['btc_denomination'],
          keychain_id:      @params['keychain_id'],
          signature:        @params['signature'],
          callback_data:    @params['callback_data'],
          data:             @params['data']
        }
        order = @gateway.create_order(order_data)
        StraightServer::Thread.new do
          # Because this is a new thread, we have to wrap the code inside in #watch_exceptions
          # once again. Otherwise, no watching is done. Oh, threads!
          StraightServer.logger.watch_exceptions do
            order.start_periodic_status_check
          end
        end
        order = add_callback_data_warning(order)
        [200, {}, order.to_json ]
      rescue Sequel::ValidationFailed => e
        StraightServer.logger.warn(
          "VALIDATION ERRORS in order, cannot create it:\n" +
          "#{e.message.split(",").each_with_index.map { |e,i| "#{i+1}. #{e.lstrip}"}.join("\n") }\n" +
          "Order data: #{order_data.inspect}\n"
        )
        [409, {}, "Invalid order: #{e.message}" ]
      rescue StraightServer::GatewayModule::InvalidSignature
        [409, {}, "Invalid signature for id: #{@params['order_id']}" ]
      rescue StraightServer::GatewayModule::InvalidOrderId
        StraightServer.logger.warn message = "An invalid id for order supplied: #{@params['order_id']}"
        [409, {}, message ]
      rescue StraightServer::GatewayModule::GatewayInactive
        StraightServer.logger.warn message = "The gateway is inactive, you cannot create order with it"
        [503, {}, message ]
      end
    end

    def show
      if (order = find_order)
        order.status(reload: true)
        order.save if order.status_changed?
        [200, {}, order.to_json]
      end
    end

    def websocket
      order = find_order
      if order
        begin
          ws = Faye::WebSocket.new(@env)
          @gateway.add_websocket_for_order ws, order
          ws.rack_response
        rescue Gateway::WebsocketExists
          [403, {}, "Someone is already listening to that order"]
        rescue Gateway::WebsocketForCompletedOrder
          [403, {}, "You cannot listen to this order because it is completed (status > 1)"]
        end
      end
    end

    def action(name)
      StraightServer.logger.blank_lines
      StraightServer.logger.info "#{@method} #{@env['REQUEST_PATH'.freeze]}\n#{@params}"

      @gateway = StraightServer::Gateway.find_by_hashed_id(@params['gateway_id'.freeze])
      unless @gateway
        StraightServer.logger.warn "Gateway not found".freeze
        return [404, {}, "Gateway not found".freeze]
      end

      @params['id'.freeze] = @params['id'.freeze].to_i if @params['id'.freeze] =~ /\A\d+\Z/

      @response = public_send(name) || [404, {}, "#{@method} /#{@request_path.join('/')} Not found"]
    end

    private

      def find_order
        if @params['id'] =~ /[^\d]+/
          Order[:payment_id => @params['id']]
        else
          Order[@params['id']]
        end
      end

      def add_callback_data_warning(order)
        o = order.to_h
        if @params['data'].kind_of?(String) && @params['callback_data'].nil?
          o[:WARNING] = "Maybe you meant to use callback_data? The API has changed now. Consult the documentation."
        end
        o
      end

  end

end
