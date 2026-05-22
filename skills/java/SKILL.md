---
name: java
tags: []
description: Modern Java practices: design, errors, concurrency, security, testing, tooling. Targets Java 21 LTS baseline; Java 25 LTS features called out explicitly. Use when writing or reviewing Java code.
license: MIT
---

# Java

## Design
- Composition over inheritance. Extend only for true is-a relationships
- Immutability by default. `final` fields, no setters unless mutation required
- Records for data carriers (16+). No boilerplate POJOs
- Sealed classes for closed type hierarchies (17+). Use exhaustive `switch` expressions over them
- Pattern matching `instanceof` (16+): `if (obj instanceof String s)` — no explicit cast
- Small interfaces. One concern per interface
- Factory methods or builders over telescoping constructors
- No `null` in public APIs. `Optional<T>` for absent values. Never `Optional` as field type
- `Objects.requireNonNull(param, "param")` at method entry for non-null enforcement

## Errors
- Checked exceptions for recoverable conditions callers must handle. Unchecked for programming errors
- Never catch `Exception` or `Throwable` except at boundaries (HTTP handler, queue consumer)
- Log full stack trace. Never swallow exceptions silently
- try-with-resources for all `Closeable`. No manual `finally` close blocks
- Catch specific exceptions. Never use exceptions for flow control

## Modern Java
- `var` where type is obvious from right-hand side. Not to obscure types
- Streams for transformation pipelines. `Stream.toList()` (16+) over `Collectors.toList()`
- `List.of()`, `Map.of()`, `Set.of()` for immutable collections. `List.copyOf()` for defensive copy
- Sequenced collections (21+): `SequencedCollection`, `getFirst()`, `getLast()` over index hacks
- `switch` expressions over statements. Pattern matching in `switch` (21+) with exhaustive coverage
- Unnamed patterns and variables (22+, stable 25): `catch (IOException _)`, `case Point(int x, _)`
- Record patterns (21+): `if (obj instanceof Point(int x, int y))`
- Text blocks for multiline strings (SQL, JSON, HTML). No string concat across lines
- Stream gatherers (22+, stable 25): `stream.gather(...)` for custom intermediate operations
- `instanceof` checks before casts eliminated — use pattern matching everywhere

## Concurrency
- Virtual threads (21+): `Thread.ofVirtual().start(...)` or `Executors.newVirtualThreadPerTaskExecutor()`. Use for I/O-bound work
- Never `synchronized` or `Object.wait/notify` with virtual threads — use `java.util.concurrent` primitives or structured concurrency
- Structured concurrency (21+ preview, stable 25): `StructuredTaskScope` for fan-out with automatic cancellation and error propagation
- Scoped values (21+ preview, stable 25): `ScopedValue` over `ThreadLocal` for virtual thread-safe immutable context
- `CompletableFuture` for async pipelines without virtual threads. Avoid `get()` without timeout
- `ExecutorService` always in try-with-resources (19+) or explicitly shut down
- Immutable shared state by default. `volatile` only when you understand happens-before
- No `Thread.sleep()` in production logic. No busy-wait loops

## Security
- Parameterized queries only. Never string-concatenated SQL
- Validate and sanitize all external input. Bean Validation (`@NotNull`, `@Size`, etc.) at API boundaries
- Never log sensitive data: passwords, tokens, PII, session IDs
- `SecureRandom` for tokens and secrets. Never `java.util.Random`
- No Java serialization for untrusted data. Use JSON or Protobuf with schema validation
- TLS: never disable certificate validation. Never catch `SSLException` and continue
- `govulncheck` equivalent: OWASP Dependency-Check or Snyk in CI. Fail on critical CVEs
- Cryptography: use JCA standard algorithms. No homebrew crypto. Prefer `AES/GCM` over `AES/CBC`
- Quantum-resistant algorithms available in Java 25 (`ML-KEM`, `ML-DSA`) — evaluate for long-lived key material

## Logging
- SLF4J API + Logback or Log4j2 implementation. Never `System.out.println` in production
- Structured logging (JSON) for machine-parseable output in production
- MDC (Mapped Diagnostic Context) for request-scoped fields (trace ID, user ID, tenant)
- Log levels: `ERROR` for actionable failures, `WARN` for degraded state, `INFO` for lifecycle events, `DEBUG` for dev only
- Parameterized log messages: `log.debug("user={}", userId)` — never string concat in log args
- Never log full stack traces at `WARN` or `INFO`. Stack traces at `ERROR` only

## Testing
- JUnit 5 + AssertJ. Arrange-Act-Assert. One concept per test
- `@ParameterizedTest` for data-driven cases
- Mockito for unit doubles. Never mock value objects or records
- Testcontainers for database and external service integration tests
- No `Thread.sleep()` in tests. Awaitility for async assertions
- Mutation testing with PIT for critical business logic
- `@Nested` for grouping related test cases within one class
- Build tag separation: unit tests in `src/test`, integration tests in `src/integrationTest` (Gradle) or profiles (Maven)

## Tooling
- Build: Maven or Gradle. Maven BOM for dependency version management. Gradle version catalogs (`libs.versions.toml`)
- Formatter: `google-java-format` or `palantir-java-format` enforced in CI. No style debates
- Static analysis: `SpotBugs` + `Find Security Bugs` plugin. `Checkstyle` for style enforcement
- `ErrorProne` compiler plugin for correctness checks at compile time
- `ArchUnit` for architectural rules: enforce layer boundaries, naming conventions in tests
- JDK selection: `sdkman` or `.sdkmanrc` for team-consistent JDK version. Pin distribution (Temurin preferred)
- GraalVM native image: profile startup vs throughput tradeoff before adopting. Reflection config required

## Performance
- Profile before optimizing. JMC (JDK Mission Control) or async-profiler
- Virtual threads remove the need to pool threads for I/O — size thread pools for CPU-bound work only
- Connection pooling (HikariCP) for DB. Never create connections per request
- Avoid excessive allocation in hot paths. Measure GC pressure with JFR (Java Flight Recorder)
- `StringBuilder` for string concat in loops. `String.join()` for fixed lists
- `ArrayList` over `LinkedList` for most cases. `ArrayDeque` over `Stack` or `LinkedList` as queue
- `List.copyOf()` / `Map.copyOf()` create truly immutable snapshots. Use over `Collections.unmodifiableList`