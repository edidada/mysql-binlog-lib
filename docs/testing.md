# 测试设计（Testing）

> 详细字节规约见 [design.md](design.md)；CI 执行与故障定位见 [ops-sop.md](ops-sop.md)。

## 1. 测试目标

1. 四种语言都能**编译**通过。
2. 四种语言都能**运行**（CLI 正常退出、单测通过）。
3. 四种语言对**同一份 binlog 字节**输出**完全一致**的 JSONL（Golden Test）。
4. 解析器对损坏 / 截断输入具备边界防御（Fuzz 规划）。

## 2. 测试分层

| 层次 | 位置 | 覆盖内容 | 由谁跑 |
| --- | --- | --- | --- |
| 单元测试 | 各语言 `tests/` / `#[cfg(test)]` / `_test.go` | ByteReader、事件头、CRC32、lenenc、行值解码 | CI 各语言 job |
| Golden 测试 | `fixtures/demo.bin` + `fixtures/expected.jsonl` | 全事件序列端到端解析、跨语言一致性 | CI 各语言 job（diff） |
| 一致性测试 | 同上 | 四语言输出两两比对（等价于各自 == golden） | CI 隐含 |
| 完整性校验 | `fixtures/gen_fixture.py` | 提交的 demo.bin/expected.jsonl 可复现、无漂移 | CI `git diff --exit-code` |
| Fuzz / 集成 / 基准 | 规划中 | 损坏字节、真实 MySQL 5.7/8.0/8.4、吞吐 | Phase 5（见 §6） |

## 3. Golden Test（核心）

### 3.1 基准来源

- `fixtures/gen_fixture.py` 是**唯一基准**：确定性生成
  - `fixtures/demo.bin`：623 字节、11 个事件（含 1 个 `UNKNOWN` 用于验证安全跳过）。
  - `fixtures/expected.jsonl`：11 行 canonical JSONL。
- 事件序列：`FDE → UNKNOWN → GTID → QUERY(BEGIN) → ROWS_QUERY → TABLE_MAP → WRITE → UPDATE → DELETE → XID → ROTATE`。
- 覆盖点：小端多字节整数、u48、lenenc、C 字符串、CRC32、SchemaRegistry、列存在位图、NULL 位图、VARCHAR 长度前缀、before/after 双行、未知事件跳过。

### 3.2 CI 断言

每个语言 job 执行：

```bash
python3 fixtures/gen_fixture.py                 # 重生成 fixtures
git diff --exit-code -- fixtures/demo.bin fixtures/expected.jsonl   # 无漂移
<build>
<unit tests>
./<bin> --file fixtures/demo.bin --format jsonl > out.jsonl
diff -u fixtures/expected.jsonl out.jsonl        # 与基准逐字节一致
```

四份 `out.jsonl` 都等于同一 `expected.jsonl`，即天然满足两两一致。

### 3.3 事件覆盖矩阵

| 事件 | type_id | 期望输出关键字段 |
| --- | --- | --- |
| FORMAT_DESCRIPTION_EVENT | 15 | binlog_version=4, server_version="8.0.36", checksum_alg=1 |
| UNKNOWN | 99 | type_id=99, event_size=26 |
| GTID_LOG_EVENT | 33 | gno=42, sid=000102...0f |
| QUERY_EVENT | 2 | db="financial_db", query="BEGIN" |
| ROWS_QUERY_LOG_EVENT | 29 | query="INSERT INTO transactions" |
| TABLE_MAP_EVENT | 19 | table_id=108, column_count=3, column_types=[8,3,15] |
| WRITE_ROWS_EVENT_V2 | 30 | rows=[[1001,7,"insert"]] |
| UPDATE_ROWS_EVENT_V2 | 31 | rows=[[1002,8,"before"],[1002,8,null]]（`null` 验证 NULL 解码） |
| DELETE_ROWS_EVENT_V2 | 32 | rows=[[1003,9,"delete"]] |
| XID_EVENT | 16 | xid=12345 |
| ROTATE_EVENT | 4 | position=4, next_file="mysql-bin.000002" |

## 4. 单元测试清单（各语言对等）

- `read_u16/u32/u48/u64` 小端解码的已知字节。
- 19 字节事件头逐字段解析（禁止结构体直读）。
- CRC32 标准向量：`crc32(b"123456789") == 0xCBF43926`。
- `lenenc_int` 各分支（1/2/3/8 字节、NULL）。
- Row 解码：整数、VARCHAR、NULL 位图、before/after。
- 截断输入 / 非法 magic / CRC 错误 → 返回错误码而非崩溃。

C/C++ 用 `assert` + CTest；Rust 用 `#[cfg(test)]` + `cargo test`；Go 用标准库 `testing` + `go test ./...`。

## 5. 如何新增测试用例

1. 在 `fixtures/gen_fixture.py` 中追加事件（同时产出字节与期望行）。
2. 本地（仅数据生成，不编译）：`python fixtures/gen_fixture.py`（Windows 用 `python`；CI 用 `python3`）。
3. 提交 `demo.bin` 与 `expected.jsonl`。
4. 在四语言解码器补齐对应分支，**不要**修改 canonical JSON 序列化规则之外的输出。
5. Push → CI 自动验证四语言是否同时通过。

> 严禁只改某一个语言的输出去「迁就」实现差异；canonical JSONL 以 `gen_fixture.py` 为准。

## 6. 后续（Phase 5）规划

- **Fuzz**：AFL++ / libFuzzer (C/C++)、cargo-fuzz (Rust)、Go native fuzzing，输入随机损坏字节，断言「不崩溃、不越界、返回错误」。
- **Golden 差异测试**：用官方 `mysqlbinlog` 输出作为参考，比对真实 CDC 行数据、事务顺序、Schema 变更。
- **集成测试矩阵**：MySQL 5.7 / 8.0 / 8.4 / 9.x × DML(INSERT/UPDATE/DELETE) × DDL(ALTER) × 断网/重启/Rotate。
- **性能指标**：Events/s、MB/s、μs/event、内存峰值、P50/P95/P99 延迟；区分纯解析与含网络的 CDC 基准。
- **验收**：见 overview.md「工程验收标准」。
