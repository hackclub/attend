module ApplicationHelper
  THEMES = {
    "light"                  => "Hack Club (light)",
    "dark"                   => "Dark",
    "catppuccin-latte"       => "Catppuccin Latte",
    "catppuccin-frappe"      => "Catppuccin Frappé",
    "catppuccin-macchiato"   => "Catppuccin Macchiato",
    "catppuccin-mocha"       => "Catppuccin Mocha",
    "dracula"                => "Dracula",
    "nord"                   => "Nord",
    "solarized-dark"         => "Solarized Dark"
  }.freeze

  def current_theme
    raw = current_user.respond_to?(:theme) && current_user&.theme.presence
    raw ||= cookies[:attend_theme].presence
    THEMES.key?(raw) ? raw : "light"
  end

  def theme_options_for_select(selected = nil)
    options_for_select(THEMES.map { |k, label| [ label, k ] }, selected || current_theme)
  end

  def debug_footer_info
    return nil unless Rails.env.development? || current_user&.global_admin?

    unique_queries = QueryCounter.unique_query_count
    cached_queries = QueryCounter.cached_query_count
    rails_version = Rails.version
    ruby_version = RUBY_VERSION
    build_info = git_build_info

    {
      queries: unique_queries,
      cached: cached_queries,
      rails_version: rails_version,
      ruby_version: ruby_version,
      commit: build_info[:commit],
      built_at: build_info[:built_at]
    }
  end

  def git_build_info
    revision_file = Rails.root.join("REVISION")
    commit = if revision_file.exist?
      revision_file.read.strip[0, 7]
    elsif Rails.env.development?
      `git rev-parse --short HEAD 2>/dev/null`.strip.presence
    end

    built_at = if revision_file.exist?
      File.mtime(revision_file)
    elsif Rails.env.development?
      Time.current
    end

    { commit: commit, built_at: built_at }
  end

  def google_maps_api_key
    Rails.application.credentials.dig(:google, :key)
  end

def admin_tool(class_name = "", element = "div", **options, &block)
    return unless current_user&.admin?

    concat content_tag(element, class: "border-2 border-dashed border-orange-400 bg-yellow-100 rounded-lg p-2 #{class_name}", **options, &block)
  end

  def required_indicator
    content_tag(:span, "*", class: "text-red-500 ml-0.5")
  end

  def label_text(text, required: false)
    if required
      safe_join([ text, required_indicator ])
    else
      text
    end
  end

  COUNTRIES = [
    "United States",
    "United Kingdom",
    "Canada",
    "Australia",
    "---",
    "Afghanistan",
    "Albania",
    "Algeria",
    "Andorra",
    "Angola",
    "Antigua and Barbuda",
    "Argentina",
    "Armenia",
    "Austria",
    "Azerbaijan",
    "Bahamas",
    "Bahrain",
    "Bangladesh",
    "Barbados",
    "Belarus",
    "Belgium",
    "Belize",
    "Benin",
    "Bhutan",
    "Bolivia",
    "Bosnia and Herzegovina",
    "Botswana",
    "Brazil",
    "Brunei",
    "Bulgaria",
    "Burkina Faso",
    "Burundi",
    "Cambodia",
    "Cameroon",
    "Cape Verde",
    "Central African Republic",
    "Chad",
    "Chile",
    "China",
    "Colombia",
    "Comoros",
    "Congo",
    "Costa Rica",
    "Croatia",
    "Cuba",
    "Cyprus",
    "Czech Republic",
    "Denmark",
    "Djibouti",
    "Dominica",
    "Dominican Republic",
    "East Timor",
    "Ecuador",
    "Egypt",
    "El Salvador",
    "Equatorial Guinea",
    "Eritrea",
    "Estonia",
    "Eswatini",
    "Ethiopia",
    "Fiji",
    "Finland",
    "France",
    "Gabon",
    "Gambia",
    "Georgia",
    "Germany",
    "Ghana",
    "Greece",
    "Grenada",
    "Guatemala",
    "Guinea",
    "Guinea-Bissau",
    "Guyana",
    "Haiti",
    "Honduras",
    "Hungary",
    "Iceland",
    "India",
    "Indonesia",
    "Iran",
    "Iraq",
    "Ireland",
    "Israel",
    "Italy",
    "Ivory Coast",
    "Jamaica",
    "Japan",
    "Jordan",
    "Kazakhstan",
    "Kenya",
    "Kiribati",
    "Kosovo",
    "Kuwait",
    "Kyrgyzstan",
    "Laos",
    "Latvia",
    "Lebanon",
    "Lesotho",
    "Liberia",
    "Libya",
    "Liechtenstein",
    "Lithuania",
    "Luxembourg",
    "Madagascar",
    "Malawi",
    "Malaysia",
    "Maldives",
    "Mali",
    "Malta",
    "Marshall Islands",
    "Mauritania",
    "Mauritius",
    "Mexico",
    "Micronesia",
    "Moldova",
    "Monaco",
    "Mongolia",
    "Montenegro",
    "Morocco",
    "Mozambique",
    "Myanmar",
    "Namibia",
    "Nauru",
    "Nepal",
    "Netherlands",
    "New Zealand",
    "Nicaragua",
    "Niger",
    "Nigeria",
    "North Korea",
    "North Macedonia",
    "Norway",
    "Oman",
    "Pakistan",
    "Palau",
    "Palestine",
    "Panama",
    "Papua New Guinea",
    "Paraguay",
    "Peru",
    "Philippines",
    "Poland",
    "Portugal",
    "Qatar",
    "Romania",
    "Russia",
    "Rwanda",
    "Saint Kitts and Nevis",
    "Saint Lucia",
    "Saint Vincent and the Grenadines",
    "Samoa",
    "San Marino",
    "Sao Tome and Principe",
    "Saudi Arabia",
    "Senegal",
    "Serbia",
    "Seychelles",
    "Sierra Leone",
    "Singapore",
    "Slovakia",
    "Slovenia",
    "Solomon Islands",
    "Somalia",
    "South Africa",
    "South Korea",
    "South Sudan",
    "Spain",
    "Sri Lanka",
    "Sudan",
    "Suriname",
    "Sweden",
    "Switzerland",
    "Syria",
    "Taiwan",
    "Tajikistan",
    "Tanzania",
    "Thailand",
    "Togo",
    "Tonga",
    "Trinidad and Tobago",
    "Tunisia",
    "Turkey",
    "Turkmenistan",
    "Tuvalu",
    "Uganda",
    "Ukraine",
    "United Arab Emirates",
    "Uruguay",
    "Uzbekistan",
    "Vanuatu",
    "Vatican City",
    "Venezuela",
    "Vietnam",
    "Yemen",
    "Zambia",
    "Zimbabwe"
  ].freeze

  def country_options_for_select(selected = nil)
    options = COUNTRIES.map do |country|
      if country == "---"
        [ "─────────────", "", { disabled: true } ]
      else
        [ country, country ]
      end
    end
    options_for_select([ [ "Select country", "" ] ] + options, selected)
  end

  # Flight-leg times are entered manually. The picker defaults to "Auto", which
  # derives the zone from the leg's airport at save time (see
  # TravelLegDateMerging). Travellers can override with an explicit zone.
  #
  # With nothing selected the ~150 option tags are identical, and travel forms
  # render this select twice per leg, so that markup is built once per request.
  # A present `selected` value changes the markup and is never cached.
  def travel_leg_time_zone_options(selected = nil)
    if selected.present?
      options_for_select([ [ "Auto (airport timezone)", "" ] ], selected.to_s) +
        time_zone_options_for_select(selected)
    else
      @travel_leg_time_zone_options ||=
        options_for_select([ [ "Auto (airport timezone)", "" ] ], "") +
        time_zone_options_for_select(nil)
    end
  end

  # Wall-clock value (YYYY-MM-DDThh:mm) for a stored-UTC leg time, rendered in
  # the airport's local zone so a `datetime-local` input shows the booked time.
  def flight_local_input_value(time, airport_code, default_date: nil)
    if time.blank?
      return default_date.present? ? "#{default_date}T00:00" : nil
    end
    tz = FlightTrackingService.airport_timezone(airport_code)
    (tz ? time.in_time_zone(tz) : time).strftime("%Y-%m-%dT%H:%M")
  end

  def attend_deep_link(participant_id)
    "attend://checkin/#{participant_id}"
  end

  def qr_code_svg(data, size: 200)
    qr = ::RQRCode::QRCode.new(data)
    qr.as_svg(
      color: "000",
      shape_rendering: "crispEdges",
      module_size: 4,
      standalone: true,
      use_path: true,
      viewbox: true,
      svg_attributes: {
        width: size,
        height: size,
        class: "qr-code"
      }
    ).html_safe
  end

  def slack_oauth_url_for_user(user)
    return nil unless user&.participant.present?

    participant_event = user.participant.participant_events.first
    return nil unless participant_event.present?

    SlackService.new.authorization_url(
      participant_event_id: participant_event.id,
      redirect_uri: slack_oauth_callback_url
    )
  end

  def user_needs_slack_link?(user)
    return false unless user.present?
    return false unless user.participant.present?
    return false unless user.participant.participant_events.exists?
    return false if user.participant.slack_user_id.present?

    true
  end

  def unread_messages_count(user)
    return 0 unless user&.participant.present?

    MessageDelivery
      .where(participant_event: user.participant.participant_events)
      .where(status: "delivered")
      .unread
      .distinct
      .count(:message_id)
  end

  def user_avatar(user, size: :medium, classes: "")
    sizes = {
      small: { dimension: 32, text: "text-xs" },
      medium: { dimension: 40, text: "text-sm" },
      large: { dimension: 64, text: "text-lg" }
    }
    config = sizes[size] || sizes[:medium]
    dimension = config[:dimension]
    text_class = config[:text]

    base_classes = "rounded-full flex items-center justify-center #{classes}"
    dimension_classes = "h-#{dimension / 4} w-#{dimension / 4}"

    if user.avatar_displayable?
      image_tag user.avatar.variant(resize_to_fill: [ dimension, dimension ]),
                class: "#{dimension_classes} rounded-full object-cover #{classes}",
                alt: user.display_name_or_fallback
    else
      content_tag :span, user.initials,
                  class: "#{dimension_classes} #{base_classes} bg-gray-200 #{text_class} font-medium text-gray-600",
                  title: user.display_name_or_fallback
    end
  end

  # HEIC photos (iPhone default) don't render in most browsers — serve a JPEG
  # variant instead. Conversion happens lazily on first request and is cached
  # in the variant records.
  def viewable_upload_path(upload)
    if upload.content_type.in?(%w[image/heic image/heif])
      rails_representation_path(upload.variant(format: :jpeg, resize_to_limit: [ 2000, 2000 ], saver: { quality: 85 }), disposition: "inline")
    else
      rails_blob_path(upload, disposition: "inline")
    end
  end
end
