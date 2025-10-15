# DLS

(Currently) A single-node, persistent log store built in Zig, using an LSM-Tree with a Write-Ahead Log (WAL) for durability. It exposes a TCP/JSON protocol for writing and reading log entries, suitable for prototyping a logging system. This project implements the Week 5 goals of a distributed log store plan, with a focus on correctness, durability, and extensibility.

## Features
- **LogEntry Model**: Stores timestamp (u64, milliseconds), message (string), optional metadata (JSON object), and version (u8).
- **LSM-Tree Storage**: In-memory memtable with sorted entries, flushed to immutable SSTables when reaching a threshold (default: 100 entries).
- **WAL Durability**: Entries are appended to a WAL before memtable insertion, with recovery on startup.
- **TCP/JSON Protocol**: Write and read logs over a network interface (default: 127.0.0.1:5260).
- **Error Handling**: Robust handling for disk full, oversized entries, and invalid JSON.
- **Tests**: Comprehensive unit and end-to-end tests for model, memtable, WAL, and server.

## Setup
1. **Install Zig**: Use Zig 0.15.1. Download from [ziglang.org](https://ziglang.org/download/).
2. **Clone Repository**:
```bash
git clone <repo-url>
cd dls
```

3. **Build and Run**:

```bash
zig build
zig run src/main.zig
```

The server runs on `127.0.0.1:5260` and uses `log.wal` for persistence.

## Usage

The server accepts TCP connections with JSON requests. Each request must end with a newline (`\n`).

### Protocol

#### Write Request

```json
{"action":"write","message":"log message","metadata":{"level":"INFO"}}
```

- `action`: Must be `"write"`.
- `message`: String, max 1MB (configurable).
- `metadata`: Optional JSON object (e.g., `{"level":"INFO"}`).
- Response: `{"status":"ok"}` or `{"status":"error","errcode":"message_too_large","detail":{"max_size":1048576,"unit":"byte"}}`.

#### Read Request

```json
{"action":"read","start_ts":0,"end_ts":18446744073709551615}
```

- `action`: Must be `"read"`.
- `start_ts`, `end_ts`: u64 timestamps (milliseconds) for range query.
- Response: `{"status":"ok","data":[{"timestamp":123456789,"message":"log message","metadata":{"level":"INFO"},"version":1}]}` or `{"status":"error","errcode":"invalid_start_ts","detail":{"message":"InvalidU64"}}`.

#### Example Client (Python)

```python
import socket
import json

def send_request(host='127.0.0.1', port=5260, request=None):
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.connect((host, port))
        s.sendall((json.dumps(request) + '\n').encode('utf-8'))
        data = s.recv(4096).decode('utf-8')
        return json.loads(data)

# Write a log
write_req = {"action": "write", "message": "test log", "metadata": {"level": "INFO"}}
print(send_request(request=write_req))  # {"status": "ok"}

# Read logs
read_req = {"action": "read", "start_ts": 0, "end_ts": 18446744073709551615}
print(send_request(request=read_req))  # {"status": "ok", "data": [...]}
```

## Memory Model

- **Arena Allocation**: `LogEntry` and `MemTable` use arena allocators for efficient memory management. Entries are owned by the memtable’s arena, reset on flush, freeing all memory.
- **Lifetime Rules**:
  - `LogEntry.init`: `message` and `metadata_json` must outlive the entry, ideally allocated by the memtable’s arena.
  - `LogEntry.deser`: Input JSON must remain valid until `MemTable.flush`.
  - `MemTable.writeLog`: Entries must use `self.entries.allocator()` to align with flush-time reset.
- **WAL**: Persists entries durably; not truncated post-flush to ensure crash recovery (to be addressed in Week 6).

## Future Improvements

- **Week 6**: Support client-provided timestamps with validation and metadata preservation.
- **Week 7**: Add locking for multi-threaded replication.
- **Week 8**: Implement sparse indexing for SSTables to improve read performance.
- **Week 10**: Extend protocol for distributed routing.

## Testing

Run tests with:

```bash
zig test src/model.zig
zig test src/memtable.zig
zig test src/server.zig
```

For performance benchmarks, the `writeManyLogs` test measures write and read latencies for up to 100k entries, demonstrating the efficiency of arena-based memory management. See detailed results in [docs/performance_test_writeManyLogs.md](docs/performance_test_writeManyLogs.md).

## Notes

- The server is single-threaded; concurrency support is planned for Week 7.
- WAL grows until compaction (Week 6) to avoid duplicate entries on recovery.
- Client timestamps are not yet supported; server-generated timestamps are used.

## License
This Distributed Logging System is licensed under the MIT License, allowing flexible use in both open-source and commercial projects while preserving attribution to the original author. See the [LICENSE](LICENSE) file for details.
