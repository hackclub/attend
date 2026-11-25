module Identity
  # Decides whether hand-typed legal names describe one person.
  #
  # Names are entered by hand everywhere: imports, OIDC claims and admins all
  # disagree about spacing, case and which name is the "first" one. Agreement
  # on the normalised full name, or on the first name alone, is enough to call
  # it one person; anything else is for a human to look at.
  module NameMatch
    PLACEHOLDER = Participant::NAME_PLACEHOLDER

    module_function

    # +names+ is a list of [ first_name, last_name ] pairs.
    def agree?(names)
      full = names.map { |first, last| normalise([ first, last ].join(" ")) }
      return true if full.uniq.size <= 1

      firsts = names.map { |first, _last| normalise(first) }
        .reject { |name| name.empty? || name == normalise(PLACEHOLDER) }
      firsts.any? && firsts.uniq.size == 1
    end

    def normalise(value)
      value.to_s.downcase.gsub(/[^a-z0-9]/, " ").squish
    end
  end
end
