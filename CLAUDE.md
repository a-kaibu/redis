# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build Commands

```bash
# Build core Redis (basic data structures only)
make

# Build with all data structures and modules (JSON, TimeSeries, Search, Bloom, etc.)
make BUILD_WITH_MODULES=yes

# Build with TLS support
make BUILD_TLS=yes

# Build with both modules and TLS (full build)
make BUILD_WITH_MODULES=yes BUILD_TLS=yes

# Clean build artifacts
make clean

# Full clean including dependencies (use when switching build options)
make distclean

# Verbose build output
make V=1
```

## Running Tests

```bash
# Run main test suite (requires Tcl 8.5+)
./runtest

# Run a single test file
./runtest --single unit/bitops

# Run specific test by name pattern
./runtest --only "test name pattern"

# Run tests with verbose output
./runtest --verbose

# Run cluster tests
./runtest-cluster

# Run sentinel tests
./runtest-sentinel

# Run module API tests
./runtest-moduleapi

# Run tests with TLS (requires tcl-tls)
./utils/gen-test-certs.sh
./runtest --tls

# Run tests against external server
./runtest --host <host> --port <port>
```

## Code Architecture

### Source Code (`src/`)
- `server.c` - Main server entry point and event loop
- `networking.c` - Client connections and protocol handling
- `db.c` - Key-value database operations
- `t_*.c` - Data type implementations (t_string.c, t_list.c, t_set.c, t_zset.c, t_hash.c, t_stream.c)
- `cluster.c`, `cluster_legacy.c` - Redis Cluster implementation
- `replication.c` - Master-replica replication
- `aof.c`, `rdb.c` - Persistence (AOF and RDB)
- `ae.c`, `ae_*.c` - Event loop abstraction (epoll/kqueue/select)
- `commands/` - JSON command definitions (used to generate commands.c)

### Modules (`modules/`)
Built when `BUILD_WITH_MODULES=yes`:
- `redisearch/` - Full-text search and query engine
- `redisjson/` - JSON document support
- `redistimeseries/` - Time series data
- `redisbloom/` - Probabilistic data structures
- `vector-sets/` - Vector similarity search

### Dependencies (`deps/`)
- `jemalloc` - Memory allocator (default on Linux)
- `lua` - Scripting engine
- `hiredis` - C client library
- `linenoise` - CLI line editing

### Tests (`tests/`)
- `unit/` - Unit tests for individual features
- `integration/` - Integration tests
- `cluster/` - Cluster-specific tests
- `sentinel/` - Sentinel tests
- `modules/` - Module test binaries (C)

Test framework uses Tcl. Tests are tagged for filtering (e.g., `external:skip`, `cluster:skip`, `needs:debug`).

## Key Configuration Files

- `redis.conf` - Default configuration
- `redis-full.conf` - Full configuration with all modules
- `sentinel.conf` - Sentinel configuration

## Development Notes

- Command metadata is defined in JSON files under `src/commands/` and code-generated via `utils/generate-command-code.py`
- On Linux, jemalloc is the default allocator; use `MALLOC=libc` to override
- Debug builds: `make noopt` (no optimization) or `make OPTIMIZATION="-O0"`
- Sanitizers: `make SANITIZER=address` or `make SANITIZER=thread`
