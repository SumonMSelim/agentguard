---
name: go
tags: []
description: Idiomatic Go 1.25 practices: errors, interfaces, concurrency, generics, testing, security, tooling. Use when writing or reviewing Go code.
license: MIT
---

# Go

## Project structure
- `go.mod` at repo root. Module path matches repo URL: `module github.com/org/repo`
- Pin Go version in `go.mod`: `go 1.25`. Toolchain auto-selects via `toolchain` directive
- Tool dependencies via `go.mod` `tool` directives (1.24+). `go get -tool golang.org/x/tools/cmd/stringer`
- Standard layout: `cmd/` for binaries, `internal/` for private packages, `pkg/` only if genuinely public
- No circular imports. `internal/` enforces package boundaries
- `go.sum` committed. Never manually edited

## Errors
- Errors are values. Return `error` as last return value
- Wrap with context: `fmt.Errorf("op failed: %w", err)`. Always `%w`, not `%v`, when caller may inspect
- Sentinel errors: `var ErrNotFound = errors.New("not found")`. Use `errors.Is` to check, not `==`
- Custom error types: implement `Error() string`. Use `errors.As` to extract
- Never ignore errors. `_ = f()` only with explicit justification in comment
- No `panic` in library code. Reserve for truly unrecoverable states in `main`
- Check errors immediately after call. No deferred error checks buried in logic

## Interfaces
- Define interfaces at point of use (consumer), not point of implementation
- Small interfaces. Prefer single-method interfaces: `io.Reader`, `io.Writer`
- Accept interfaces, return concrete types
- No interface for a single implementation unless testing or future extensibility is clear
- `interface{}` → `any` (Go 1.18+). Use `any` everywhere
- Embed interfaces to compose: `type ReadWriter interface { Reader; Writer }`

## Generics
- Use generics to eliminate identical logic across types. Not for premature abstraction
- Constrain tightly: `[T int | int64]` over `[T any]` when type matters
- `comparable` constraint for map keys and equality checks
- `golang.org/x/exp/slices` and `maps` patterns now in stdlib (`slices`, `maps` packages, 1.21+)
- Range over func iterators (1.22+): use `iter.Seq` and `iter.Seq2` for custom iterables
- Generic type aliases fully supported (1.24+): `type Set[T comparable] = map[T]struct{}`

## Concurrency
- Share memory by communicating. Channels for ownership transfer, `sync` for shared state
- Always specify goroutine lifecycle: who starts it, who stops it, how caller knows it's done
- `context.Context` as first arg to every blocking or long-running function. Respect cancellation
- `select` with `ctx.Done()` in every goroutine that blocks on channel or I/O
- `sync.WaitGroup` to wait for goroutine group. `errgroup.Group` when any error should cancel all
- `sync.Mutex` over channels for protecting shared state. Embed mutex with the data it protects
- Race detector always on in tests and CI: `go test -race ./...`
- No goroutine leaks. Profile with `goleak` in tests for long-running services
- Buffered channels: document capacity rationale. Default to unbuffered
- GOMAXPROCS defaults to cgroup CPU limit on Linux (1.25+) — container deployments no longer need manual tuning

## Context
- `context.Background()` at program entry only (`main`, top-level server handler, test root)
- Never store context in struct. Pass explicitly
- Cancel functions always deferred: `ctx, cancel := context.WithTimeout(...); defer cancel()`
- Propagate deadlines from inbound requests to all outbound calls (HTTP, DB, gRPC)
- `context.WithValue` only for request-scoped metadata (trace ID, auth token). Not for optional function params. Key type must be unexported to avoid collisions

## HTTP and networking
- `net/http`: always set `ReadTimeout`, `WriteTimeout`, `IdleTimeout` on `http.Server`. No default server
- Close response bodies: `defer resp.Body.Close()` immediately after nil error check
- Use `http.NewRequestWithContext` — never `http.NewRequest` in production code
- Validate and sanitize all inbound data. Use `net/url` for URL construction, not string concat
- TLS: `tls.Config` with `MinVersion: tls.VersionTLS12`. Prefer TLS 1.3

## Security
- Never construct SQL with string concat. Use parameterized queries or an ORM that does
- `crypto/rand` for all random tokens, IDs, secrets. Never `math/rand`
- Hash passwords with `bcrypt` or `argon2`. Never `sha256` or `md5` for passwords
- Avoid `html/template` bypass (`template.HTML`, `template.JS`). Auto-escaping is the point
- `os/exec`: never pass user input directly to shell. Use arg list form, not string form
- `filepath.Clean` and `filepath.Join` for all path construction. Validate result stays within allowed root
- `govulncheck ./...` in CI. Scans modules and call graph for known CVEs
- Secrets from env or secret manager at startup. Never hardcoded or in config files committed to git

## Testing
- Table-driven tests as default pattern. `t.Run` per case
- `t.Parallel()` in all unit tests that don't share mutable state
- `testify/assert` or stdlib `cmp` for assertions. Avoid rolling custom diff logic
- Use `t.TempDir()` for temp files — auto-cleaned. Never `os.TempDir()` directly in tests
- Fuzz tests (`func FuzzX(f *testing.F)`) for parsers, decoders, untrusted input handlers
- Benchmarks (`func BenchmarkX(b *testing.B)`) for hot paths. Run with `-benchmem`
- `httptest.NewRecorder` and `httptest.NewServer` for HTTP handler tests. No real network in unit tests
- Coverage: `go test -cover ./...`. Track but don't cargo-cult 100%
- Integration and unit tests separated via build tags: `//go:build integration`

## Tooling
- Format: `gofmt` or `goimports` on save. No style debates
- Lint: `golangci-lint` with at minimum `errcheck`, `govet`, `staticcheck`, `gosec` enabled
- `go vet ./...` in CI. Catches real bugs, not style
- `govulncheck ./...` in CI for supply chain security
- `go mod tidy` before every commit. Keeps `go.sum` clean
- `go build -trimpath` for reproducible builds. Removes local paths from binaries
- Multi-platform: `GOOS=linux GOARCH=amd64 go build`. Test on target arch in CI
- `go tool pprof` for CPU/memory profiling. `net/http/pprof` endpoint in long-running services (behind auth)

## Performance
- Preallocate slices and maps when length known: `make([]T, 0, n)`, `make(map[K]V, n)`
- Avoid allocations in hot paths. Benchmark before optimizing. `go test -benchmem`
- `sync.Pool` for frequently allocated short-lived objects (e.g. buffers)
- String builder: `strings.Builder` for loops. Never `+=` string concat in loops
- `io.Reader`/`io.Writer` chains over loading full content into memory
- Profile first. `pprof` before any micro-optimization