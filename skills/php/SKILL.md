---
name: php
tags: []
description: Modern PHP 8.5 practices: type system, OOP, security, architecture, async, testing, tooling. Use when writing or reviewing PHP code.
license: MIT
---

# PHP

## Runtime and versioning
- Run PHP 8.4 (active support) or 8.5 (latest stable). Never run EOL versions — no security patches
- `declare(strict_types=1)` at top of every file
- OPcache enabled in production. `opcache.preload` for warm startup on 8.0+
- JIT enabled for CPU-bound workloads: `opcache.jit=tracing`, `opcache.jit_buffer_size=128M`. Not beneficial for typical I/O-bound web apps — benchmark before enabling

## Type system
- Type-hint all parameters, return types, and properties. No `mixed` — use union types (`int|string`) or generics via PHPDoc
- `never` return type for functions that always throw or exit
- `readonly` properties for value objects and DTOs (8.1+). `readonly` classes (8.2+) for fully immutable objects
- Asymmetric visibility (8.4+): `public private(set)` for properties readable everywhere but writable only within class
- Property hooks (8.4+): `get`/`set` hooks on properties — eliminates getter/setter boilerplate. Incompatible with `readonly`
- Intersection types (8.1+): `Countable&Iterator`. DNF types (8.2+): `(A&B)|null`
- Typed class constants (8.3+): `const string VERSION = '1.0'`
- `#[Override]` attribute (8.3+) on overriding methods — compiler-checked safety net
- Enums over constants for closed value sets (8.1+). Backed enums (`string`/`int`) for serialisation
- Named arguments for multi-param functions with non-obvious order. Not for all calls
- `match` over `switch` — exhaustive, no fall-through, returns value
- First-class callable syntax (8.1+): `strlen(...)` over `Closure::fromCallable('strlen')`

## Modern syntax (8.4–8.5)
- `new` without parentheses for chaining (8.4+): `new Collection()->filter()->map()`
- Pipe operator (8.5+): `$result = $value |> trim(...) |> strtolower(...) |> htmlspecialchars(...)`. Prefer over nested calls
- `clone with` (8.5+): `$new = clone $obj with {name: 'updated'}`. Preferred over manual clone + property set
- Static property asymmetric visibility (8.5+): same syntax as instance properties
- Lazy objects (8.4+): built-in lazy initialisation via `ReflectionClass::newLazyProxy()`. Use for expensive dependencies in DI containers
- Driver-specific PDO classes (8.4+): `Pdo\Mysql`, `Pdo\Pgsql`, `Pdo\Sqlite` — type-safe, IDE-friendly alternatives to generic `PDO`

## Error handling
- Throw exceptions, never return error codes or `false`
- Catch specific exception types. Never catch `\Throwable` at the business layer
- Custom exception classes for domain errors callers need to handle
- Log full exception context. Never swallow silently
- Fatal error backtraces (8.5+): enable via `zend.exception_ignore_args=0` — `error_get_last()` now includes trace key

## Security
- Never trust user input. Validate and sanitise at every entry point
- Parameterised queries only — PDO driver classes (8.4+) or `PDO` with prepared statements. Never string interpolation in SQL
- `password_hash()` / `password_verify()` with `PASSWORD_BCRYPT` or `PASSWORD_ARGON2ID`. Never MD5/SHA1
- Escape all output for context: HTML → `htmlspecialchars()`, shell → `escapeshellarg()` or `proc_open()` with arg array (never shell string)
- Never `eval()`, `exec()`, `system()`, `shell_exec()` with user-controlled input
- Secrets in env or secret manager. Never in code or committed config
- Session cookies: `HttpOnly`, `Secure`, `SameSite=Strict`. Partitioned cookie support (8.5+) via `setcookie()` `partitioned` option
- CSP, CSRF protection, rate limiting on all forms and auth endpoints
- `composer audit` in CI. Fail on known vulnerabilities
- Keep dependencies updated. `composer outdated` as part of regular maintenance

## Architecture
- PSR-12 coding standard. Enforce with PHP-CS-Fixer or Pint in CI
- PSR-4 autoloading. No manual `require`/`include` in application code
- Depend on abstractions (interfaces), not concretions. Inject dependencies
- Service classes do one thing. No business logic in controllers or views
- Value objects for domain concepts (Money, Email, UserId) — primitives leak
- Repositories only when data source swapping is a real requirement

## Async and concurrency
- Fibers (8.1+): cooperative multitasking within a single thread. Foundation for async runtimes
- ReactPHP or AMPHP for event-loop-based async I/O. Swoole/OpenSwoole for coroutine-based high-concurrency servers
- Shared-nothing model is default PHP. Fibers do not add multi-threading — I/O concurrency only
- Avoid blocking calls (`file_get_contents`, `sleep`) inside fiber/event-loop context

## Composer and dependencies
- Pin major versions in `composer.json`. `composer.lock` committed to git
- `composer audit` and `composer outdated` in CI
- `composer install --no-dev --optimize-autoloader` in production. Never `--no-scripts` unless you understand what you're skipping
- Separate `require` from `require-dev`. Testing and analysis tools in dev only
- Evaluate package maintenance health before adopting. Abandoned packages are a security risk

## Testing
- Pest preferred for new projects. PHPUnit for existing codebases — don't mix
- Test behaviour, not implementation. No exposing private methods for testing
- Mock external services (HTTP, queues, storage). Never mock your own domain classes
- PHPStan at level 8+ or Psalm with strict mode. Run in CI, fail on errors
- Mutation testing with Infection for critical business logic
- `phpbench` for performance-sensitive code. Benchmark before and after optimisation

## Performance
- Profile first: Xdebug (development), Never optimise blind
- Generators for large dataset iteration. Never load unbounded results into memory
- Avoid N+1 queries. Eager-load relationships
- `SplFixedArray` for large homogeneous datasets. Lower memory overhead than plain arrays
- Fibers/async for I/O concurrency. JIT for CPU-bound computation