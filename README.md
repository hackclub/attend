# Attend

[![CI](https://github.com/hackclub/attend/actions/workflows/ci.yml/badge.svg)](https://github.com/hackclub/attend/actions/workflows/ci.yml)

A web application for onboarding under-18 participants for in-person Hack Club events. Attend collects all information needed for safeguarding, travel, accommodation, and operational workflows—with a focus on security and data protection.

## Features

- **Multi-event support** — Manage multiple events with separate configurations
- **Participant onboarding** — Multi-step wizard for profile, travel, accommodation, health, and guardian info
- **Guardian portal** — Secure magic-link access for parents/guardians to complete consent forms
- **Role-based access control** — Global Admin, Event Admin, Ops Staff, Safeguarding Lead roles
- **Sensitive data encryption** — Medical and safeguarding information encrypted at rest
- **Mobile wallet passes** — Apple Wallet and Google Wallet support for event check-in
- **Audit logging** — Full trail of admin actions with PaperTrail and console1984
- **QR code check-in** — Scan participants at event venues

## Tech Stack

| Category | Technology |
|----------|------------|
| Framework | Ruby 3.4 / Rails 8.1 |
| Database | PostgreSQL with UUID primary keys |
| Frontend | Hotwire (Turbo + Stimulus), Tailwind CSS |
| Authentication | Devise + OmniAuth (Hack Club Auth) |
| Authorization | Pundit |
| Background Jobs | Solid Queue + Mission Control |
| Caching | Solid Cache |
| Real-time | Solid Cable (Action Cable) |
| Asset Pipeline | Propshaft + Importmap |
| Deployment | Docker |
| Storage | Active Storage with S3 (Cloudflare R2) |

---

## Getting Started

### Prerequisites

- Ruby 3.4+
- PostgreSQL 15+
- Node.js 18+ (for Tailwind CSS watcher)

### Installation

```bash
# Clone the repository
git clone https://github.com/hackclub/attend.git
cd attend

# Install Ruby dependencies
bundle install

# Setup database
rails db:create db:migrate db:seed

# Start development server (Rails + Tailwind watcher)
bin/dev
```

The app will be available at `https://localhost:3000`.

### Test Users (Development)

After running seeds, these accounts are available:

| Email | Password | Role |
|-------|----------|------|
| admin@hackclub.com | password123 | Global Admin |
| eventadmin@hackclub.com | password123 | Event Admin |
| ops@hackclub.com | password123 | Ops Staff |
| safeguarding@hackclub.com | password123 | Safeguarding Lead |
| participant@example.com | password123 | Participant |

---

## Configuration

### Environment Variables

Copy `.env.example` to `.env` for development:

```bash
cp .env.example .env
```

Key variables:

| Variable | Description |
|----------|-------------|
| `DATABASE_URL` | PostgreSQL connection string |
| `HACK_CLUB_CLIENT_ID` / `HACK_CLUB_CLIENT_SECRET` | OAuth credentials |
| `DOCUSEAL_API_KEY` / `DOCUSEAL_WEBHOOK_SECRET` | E-signature integration |
| `SENTRY_DSN` | Error monitoring |

### Rails Credentials

For production secrets, use Rails encrypted credentials:

```bash
EDITOR="code --wait" rails credentials:edit
```

Required credentials structure:

```yaml
app_host: attend.hackclub.com
database_url: postgres://user:pass@host:5432/dbname

hack_club:
  client_id: your_client_id
  client_secret: your_client_secret

docuseal:
  api_key: your_api_key
  webhook_secret: your_secret

sentry:
  dsn: https://your-sentry-dsn

# Encryption keys (generate with: bin/rails db:encryption:init)
active_record_encryption:
  primary_key: generated_key
  deterministic_key: generated_key
  key_derivation_salt: generated_salt
```

### Optional: Wallet Passes

For Apple Wallet passes, add PassKit configuration:

```yaml
passkit:
  web_service_host: https://attend.hackclub.com
  apple_team_identifier: YOUR_TEAM_ID
  pass_type_identifier: pass.com.hackclub.attend
  certificate_key: your_p12_password
  private_p12_certificate: /path/to/certificate.p12
  apple_intermediate_certificate: /path/to/WWDR.cer
```

For Google Wallet, see [Google Wallet Prerequisites](https://developers.google.com/wallet/tickets/events/web/prerequisites).

---

## Architecture

### User Roles

| Role | Access |
|------|--------|
| **Participant** | Complete onboarding for events, view their status |
| **Guardian** | Complete consent forms via magic link |
| **Global Admin** | Full access to all events and data |
| **Event Admin** | Full access for assigned events |
| **Ops Staff** | View/edit operational data (travel, accommodation) |
| **Safeguarding Lead** | Access to medical and safeguarding information |

### Data Model

```
Event
├── ParticipantEvent (join table with status)
│   ├── Participant
│   ├── GuardianParticipantEvent
│   │   ├── Guardian
│   │   └── EmergencyContact
│   ├── Travel (inbound/outbound)
│   │   └── TravelLeg
│   ├── Accommodation
│   ├── Medical (encrypted)
│   ├── Dietary
│   ├── Accessibility (encrypted)
│   ├── SafeguardingInfo (encrypted)
│   └── Consent (DocuSeal tracking)
├── Incident (encrypted)
├── Note (encrypted)
├── Scan (check-in records)
└── EventRoleAssignment (staff roles)
```

### External Integrations

| Service | Purpose |
|---------|---------|
| **DocuSeal** | Embedded consent forms with webhook status updates |

---

## Development

### Quick Commands

```bash
# Start development server with Tailwind watcher
bin/dev

# Rails server only
rails server

# Rails console
rails console

# Database operations
rails db:migrate          # Run pending migrations
rails db:seed             # Seed development data
rails db:reset            # Drop, create, migrate, seed

# Show all routes
rails routes

# Generate encryption keys
bin/rails db:encryption:init
```

### Testing

```bash
# Run all tests
bundle exec rspec

# Run specific test files
bundle exec rspec spec/models/
bundle exec rspec spec/features/

# Run a single test file
bundle exec rspec spec/models/participant_spec.rb
```

### Linting

```bash
# Run RuboCop
bin/rubocop

# Auto-fix safe violations
bin/rubocop -a

# Security audit
bundle exec brakeman
bundle exec bundler-audit check
```

### Background Jobs

Jobs are processed by Solid Queue. In development, they run inline. View the job dashboard at `/admin/jobs` (requires Global Admin).

---

## Deployment

### Docker

Build and run with Docker:

```bash
docker build -t attend .
docker run -d -p 80:80 \
  -e RAILS_MASTER_KEY=<value from config/master.key> \
  --name attend attend
```

Set `RAILS_MASTER_KEY` as an environment variable on your production server. Hack Club's production instance builds this Dockerfile and deploys it on every merge to `main`.

### Staging

`RAILS_ENV=staging` loads `config/environments/production.rb` verbatim and then overrides
only the host, the Active Storage bucket, and the outbound-email guard, so staging
exercises the same code paths as production.

What keeps staging from touching production's data:

- **Credentials.** Staging reads `config/credentials/staging.yml.enc`, unlocked by its own
  `RAILS_MASTER_KEY`. Those credentials must name staging Postmark/Twilio/Airtable/Slack
  accounts. The app refuses to boot if that file is missing, because Rails would otherwise
  silently fall back to production's `config/credentials.yml.enc`. Open it with
  `bin/rails credentials:edit --environment staging` — it ships as an annotated template
  with every integration the app reads, so filling in the `REPLACE_ME`s is the whole job.
  `secret_key_base` and the `active_record_encryption` keys are already generated and
  deliberately differ from production's, so a staging session cookie is not valid on
  attend.hackclub.com.
- **Email.** Every outbound message is rewritten to `STAGING_MAIL_RECIPIENT`, or dropped
  if that variable is unset. See `app/mailers/staging_mail_interceptor.rb`.
- **SMS and voice.** Off until someone flips the `twilio_enabled` setting, which defaults
  to false on a fresh database.
- **Airtable.** `config/recurring.yml` deliberately omits `airtable_sync` in staging —
  it writes back to the base it reads, so a second box running it every five minutes
  would fight production over the same records. Run it by hand when you need it.
- **Uploads.** A separate `hackclub-attend-staging` R2 bucket (`config/storage.yml`).

Required environment variables on the staging deployment:

| Variable | Value |
| --- | --- |
| `RAILS_ENV` | `staging` |
| `RAILS_MASTER_KEY` | contents of `config/credentials/staging.key` |
| `DATABASE_URL` | the staging Postgres URL (no credentials fallback — a wrong value fails to boot) |
| `APP_HOST` | the staging hostname, e.g. `staging.attend.hackclub.com` |
| `STAGING_MAIL_RECIPIENT` | where redirected email should go; unset means email is dropped |
| `SOLID_QUEUE_IN_PUMA` | `true` |

Also needs doing outside the app: a Hack Club Auth redirect URI for the staging host, a
Turnstile widget scoped to it, and the `hackclub-attend-staging` R2 bucket. Webhooks (Postmark,
HelpScout, DocuSeal, Twilio) stay pointed at production, so staging never receives them.

---

## Contributing

### Getting Started

1. Fork the repository
2. Create a feature branch: `git checkout -b feature/your-feature`
3. Make your changes
4. Run tests: `bundle exec rspec`
5. Run linter: `bin/rubocop`
6. Commit with clear messages
7. Push and open a Pull Request

### Code Style

- Follow the [Rails Omakase](https://github.com/rails/rubocop-rails-omakase) style guide
- Use UUID primary keys for all models
- Encrypt sensitive data with Active Record Encryption
- Add Pundit policies for new resources
- Write specs for new features

### Commit Messages

Use clear, descriptive commit messages:

```
Add flight tracking integration with FlightAware

- Implement FlightTrackingService with provider fallback
- Add TravelLeg model for multi-leg journeys
- Schedule background job for status updates
```

### Security

- Never commit secrets or credentials
- Use Rails credentials for sensitive configuration
- Report security issues via [security.hackclub.com](security.hackclub.com)

---

## License

GNU General Public License v3.0

---

## Support

For questions or issues, open a GitHub issue or contact the Events team through the 'chat feature' on Attend, or through [#attend](https://hackclub.enterprise.slack.com/archives/C0A3J4Q6RN1)
