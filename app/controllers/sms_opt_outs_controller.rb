# The page behind the "Stop texts" link at the bottom of texts sent from the
# "Hack Club" sender, which people can't reply STOP to. Opening the link
# changes nothing (link previews and scanners open it too); the button does.
class SmsOptOutsController < ApplicationController
  skip_before_action :set_current_attributes
  before_action :find_phone

  def show
    @opted_out = SmsOptOut.opted_out?(@phone)
  end

  def create
    SmsOptOut.opt_out!(@phone, source: :link)
    redirect_to sms_opt_out_path(params[:token]), notice: "Done. We won't text you about Hack Club events any more."
  end

  def destroy
    SmsOptOut.opt_in!(@phone)
    redirect_to sms_opt_out_path(params[:token]), notice: "Texts are back on."
  end

  private

  def find_phone
    response.headers["X-Robots-Tag"] = "noindex, nofollow"
    @phone = SmsOptOut.phone_for_token(params[:token])
    render :not_found, status: :not_found unless @phone
  end
end
