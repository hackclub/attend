class ApiTokenMailer < ApplicationMailer
  # Sent when a token is revoked through the unauthenticated kill switch
  # (POST /api/v1/tokens/revoke). Invoked with:
  #   ApiTokenMailer.with(
  #     email:, token_name:, token_kind:, event_name:
  #   ).revoked.deliver_later
  def revoked
    @token_name = params[:token_name]
    @token_kind = params[:token_kind] # "global" or "event"
    @event_name = params[:event_name]

    mail(
      to: params[:email],
      subject: "[Attend] An API token was revoked"
    )
  end
end
