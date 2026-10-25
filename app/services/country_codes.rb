# Maps between the country names Attend stores (ApplicationHelper::COUNTRIES,
# what the onboarding country picker saves to country_of_residence) and ISO
# 3166-1 alpha-2 codes, which integrations and Hack Club Auth use. TZInfo's
# country data supplies most pairs; OVERRIDES covers names where Attend's
# wording differs from TZInfo's.
module CountryCodes
  OVERRIDES = {
    "United Kingdom" => "GB",
    "Antigua and Barbuda" => "AG",
    "Bosnia and Herzegovina" => "BA",
    "Central African Republic" => "CF",
    "Congo" => "CG",
    "Eswatini" => "SZ",
    "Ivory Coast" => "CI",
    "Kosovo" => "XK",
    "Myanmar" => "MM",
    "North Korea" => "KP",
    "Saint Kitts and Nevis" => "KN",
    "Saint Lucia" => "LC",
    "Saint Vincent and the Grenadines" => "VC",
    "Samoa" => "WS",
    "Sao Tome and Principe" => "ST",
    "South Korea" => "KR",
    "Trinidad and Tobago" => "TT"
  }.freeze

  def self.code_for(name)
    name_to_code[name.to_s.strip.downcase]
  end

  def self.name_for(code)
    code_to_name[code.to_s.strip.upcase]
  end

  # Accepts a country name in any case or an alpha-2 code, and returns the
  # name as Attend stores it, or nil when Attend doesn't list that country.
  def self.normalize(value)
    value = value.to_s.strip
    return nil if value.empty?

    name_for(value) || code_to_name[code_for(value)]
  end

  def self.name_to_code
    @name_to_code ||= begin
      tzinfo = TZInfo::Country.all.to_h { |country| [ country.name, country.code ] }
      (ApplicationHelper::COUNTRIES - [ "---" ]).filter_map do |name|
        code = OVERRIDES[name] || tzinfo[name]
        [ name.downcase, code ] if code
      end.to_h
    end
  end

  def self.code_to_name
    @code_to_name ||= (ApplicationHelper::COUNTRIES - [ "---" ]).filter_map do |name|
      code = name_to_code[name.downcase]
      [ code, name ] if code
    end.to_h
  end
  private_class_method :name_to_code, :code_to_name
end
