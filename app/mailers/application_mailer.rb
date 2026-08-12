class ApplicationMailer < ActionMailer::Base
  default from: "Hack Club <team@hackclub.com>"
  layout "mailer"

  helper MailerHelper

  after_action :set_delivery_metadata

  private

  def set_delivery_metadata
    message.instance_variable_set(:@_emailable, @emailable)
    message.instance_variable_set(:@_event, @event)
    message.instance_variable_set(:@_mailer_action, action_name)
  end
end
