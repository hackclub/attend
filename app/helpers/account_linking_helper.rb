# Account linking selects on the admin series and event forms.
module AccountLinkingHelper
  ACCOUNT_LINKING_MODE_LABELS = { "off" => "Don't ask", "optional" => "Optional", "required" => "Required" }.freeze

  # An event in a series gets a "same as series" choice, stored as blank.
  def event_account_linking_options(event, provider)
    modes = ACCOUNT_LINKING_MODE_LABELS.map { |mode, label| [ label, mode ] }
    own = event.config&.[]("#{provider}_linking").presence
    if event.event_series
      series_mode = ACCOUNT_LINKING_MODE_LABELS[event.event_series.account_linking_mode(provider)]
      options_for_select([ [ "Same as series (#{series_mode})", "" ] ] + modes, own || "")
    else
      options_for_select(modes, own || "off")
    end
  end

  def account_linking_credentials_warning(provider)
    return if AccountLinking.available?(provider)

    name = AccountLinking.provider_name(provider)
    %(#{name} OAuth credentials aren't configured, so participants can't connect yet and "Required" won't block anyone.)
  end
end
