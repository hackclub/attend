# visas.hackclub.com, where Envoy lived. Every letter Envoy or Attend printed
# tells embassies to check it at hack.club/visa-verify, which forwards to
# /verify there, and Envoy's emails link to letters there, so that host keeps
# answering those. Everything else on it goes to Attend's own visa pages (see
# config/routes.rb and VisasHostController).
module VisaLetter
  def self.visas_host = ENV.fetch("VISAS_HOST", "visas.hackclub.com")

  def self.visas_host?(host) = host.to_s.casecmp?(visas_host)
end
