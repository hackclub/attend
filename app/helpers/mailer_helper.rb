module MailerHelper
  BUTTON_STYLE = "display: inline-block; padding: 12px 24px; background-color: #ec3750; " \
                 "color: #ffffff; text-decoration: none; border-radius: 6px; font-weight: 600;".freeze

  def mail_button(text, url)
    link_to text, url, class: "button", style: BUTTON_STYLE
  end
end
