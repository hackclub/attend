module Support
  module Tickets
    class MessagesController < Admin::BaseController
      before_action :set_ticket
      after_action :verify_authorized

      def create
        authorize @ticket, :update?

        message_body = params.require(:ticket_message).fetch(:body)

        begin
          @message = ::Support::SendTicketMessage.call(
            ticket: @ticket,
            body: message_body,
            user: current_user
          )

          respond_to do |format|
            format.turbo_stream
            format.html { redirect_to support_ticket_path(@ticket) }
          end
        rescue ::Support::SendTicketMessage::DeliveryError => e
          @error = e.message
          respond_to do |format|
            format.turbo_stream { render :error }
            format.html { redirect_to support_ticket_path(@ticket), alert: "Failed to send: #{e.message}" }
          end
        end
      end

      private

      def set_ticket
        @ticket = Ticket.find(params[:ticket_id])
      end
    end
  end
end
