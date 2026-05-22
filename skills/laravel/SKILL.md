---
name: laravel
tags: []
description: Laravel 13 best practices: architecture, Eloquent, security, queues, testing, tooling. PHP 8.3+. Use when writing or reviewing Laravel applications.
license: MIT
---

# Laravel

## Architecture
- Thin controllers: validate input, call service or action, return response. No business logic in controllers
- Form Requests for validation and authorisation. Never validate in controller body
- Service classes or Actions for domain logic. One responsibility each
- Repositories only when swapping data sources is a real requirement
- No logic in routes or middleware beyond stated purpose
- Strict mode in `AppServiceProvider`: `Model::shouldBeStrict()` in non-production, `Model::preventLazyLoading()` in all envs

## PHP Attributes (Laravel 13+)
- PHP Attributes are optional but preferred for co-locating config with classes
- Models: `#[Fillable]`, `#[Guarded]`, `#[Hidden]` replace `$fillable`, `$guarded`, `$hidden` properties
- Controllers: `#[Middleware]`, `#[Authorize]` replace `$this->middleware()` in constructor
- Jobs: `#[Tries]`, `#[Backoff]`, `#[Timeout]`, `#[FailOnTimeout]` replace class properties
- Adopt Attributes on new code. No need to migrate existing property-based code — not deprecated

## Eloquent
- Eager-load all relationships with `with()`. Enable `Model::preventLazyLoading()` to catch N+1 in dev
- Scope complex query logic into named scopes on the model
- `firstOrFail()` / `findOrFail()` — never manually null-check query results
- Mass assignment: `#[Fillable]` or explicit `$fillable`. Never `$guarded = []` in production
- Observers and model events for cross-cutting concerns only. No core logic inside them
- `DB::transaction(fn() => ...)` for all multi-step writes
- UUID or ULID primary keys for distributed systems: `HasUuids` / `HasUlids` traits
- Always add indexes for foreign keys, frequently filtered columns, and unique constraints in migrations

## Security
- Sanctum for SPA/mobile API auth. Passport for OAuth server. Never hand-rolled token auth
- Passkey auth available via Laravel 13 first-party support — prefer for new user-facing apps
- Authorise with Policies or Gates. Never inline ownership checks
- CSRF on by default — never disable
- Validate all input with Form Requests. Use `sometimes` and `nullable` intentionally
- Secrets in secret manager (AWS Secrets Manager, Vault). Never in `.env` committed to repo
- Encrypt sensitive data at rest via `Crypt` facade
- Rate-limit sensitive routes (`login`, `register`, password reset) with `throttle` middleware
- Never `DB::statement()` with user input. Use query builder or Eloquent
- Sanctum tokens: set expiry. Revoke on logout. Store hashed in DB (default behaviour — don't bypass)

## Queues and jobs
- All slow work (email, notifications, external API calls) in queued jobs
- Jobs idempotent — they will be retried
- Use `#[Tries]`, `#[Backoff]`, `#[Timeout]` attributes (L13+) or equivalent properties on every job
- `failed()` method on every job for cleanup and alerting
- Pass model IDs to jobs, not model instances — model may be deleted before job runs
- Separate queues by priority and type: `high`, `default`, `low`, `emails`. Never one default queue for everything
- Horizon for queue monitoring. Set `balance`, `maxProcesses`, and `timeout` per queue in `horizon.php`
- Protect Horizon dashboard with `HorizonServiceProvider` gate — never expose in production without auth

## API
- Versioned routes: `api/v1/`, `api/v2/`. Never break existing API consumers
- API Resources (`JsonResource`) for all responses. Never return raw Eloquent models
- Consistent error response structure. Use exception handler to normalise 4xx/5xx shapes
- `Cache::touch()` (L13+) to extend TTL on accessed entries without re-fetching
- Throttle all API routes. Fine-grained limits per route, not just a global middleware

## Testing
- Pest preferred for new projects. PHPUnit supported — pick one per project, don't mix
- Feature tests for HTTP endpoints with `RefreshDatabase`
- Unit tests for service/action classes
- Factories for all test data. Never raw `DB::insert` in tests
- `Http::fake()`, `Mail::fake()`, `Queue::fake()`, `Event::fake()`, `Storage::fake()` — no real services in tests
- Assert on HTTP status, JSON structure, and DB state
- `Pest::arch()` for architecture tests: enforce namespace rules, no business logic in controllers
- `@pest` datasets for parameterised cases

## Performance
- `chunk()` or `cursor()` for large dataset processing. Never `->get()` on unbounded queries
- Tagged cache for fine-grained invalidation. Invalidate on write
- `Cache::touch()` (L13+) for sliding TTL on hot cache entries
- `php artisan optimize` in production: caches config, routes, views, events
- Octane (Swoole or RoadRunner) for high-throughput APIs. Requires stateless code — no static state between requests
- OPcache enabled and warmed in production

## Monitoring and tooling
- Telescope in local/staging only. Never in production without access control and storage limits
- Pulse for production monitoring: request throughput, queue depth, cache hits, slow queries, exceptions
- Reverb for WebSockets (L13+). Database driver available — no Redis required for smaller workloads
- Laravel AI SDK (stable in L13) for LLM integration. Provider-agnostic: OpenAI, Anthropic, etc.
- Pennant for feature flags. Gate new features behind `Feature::active('feature-name')`
- Nightwatch for production error tracking and alerting (first-party)

## Code quality
- Pint for code formatting (`./vendor/bin/pint`). Enforce in CI — no style debates
- Larastan (PHPStan for Laravel) at level 6+ minimum. Raise level over time
- `php artisan about` + `php artisan model:show` for runtime introspection in debugging
- `php artisan db:monitor` and slow query logging in production