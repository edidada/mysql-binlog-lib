# mysql-binlog-lib

[![CI](https://github.com/edidada/mysql-binlog-lib/actions/workflows/ci.yml/badge.svg)](https://github.com/edidada/mysql-binlog-lib/actions/workflows/ci.yml)

**MySQL Binlog 离线解析引擎 —— 十语言独立实现。**

C / C++ / Rust / Go / Java / C# / Zig / Erlang / Python / x86-64 汇编各自实现独立的解析库 + CLI + 单测，不通过 FFI 互相调用，共享同一份 binlog 测试字节与统一 JSONL 输出，便于对比实现质量与性能。参考 Debezium 的分层架构，目标逐步适配 MySQL 5.7 / 8.0 / 8.4 LTS / 9.x。

> 当前阶段：**Phase 1 —— 离线 Binlog 解析基线**（Header、FDE、Table Map、RowsV2、GTID、XID、Query、Rotate、CRC32、SchemaRegistry、统一 JSONL）。在线 CDC、Snapshot、Kafka Sink 属后续阶段。

## 文档

| 文档 | 内容 |
| --- | --- |
| [docs/design.md](docs/design.md) | **详细设计**：字节布局、事件规约、JSONL 规范、CLI 契约、模块划分 |
| [docs/testing.md](docs/testing.md) | **测试**：Golden 跨语言一致性、单测、覆盖矩阵、Fuzz/集成规划 |
| [docs/ops-sop.md](docs/ops-sop.md) | **运维 SOP**：本地不编译约定、CI 排错、发布、版本兼容、回滚 |
| [docs/overview.md](docs/overview.md) | 概要设计与分阶段路线图 |

## 目录结构

```
.github/workflows/ci.yml      十语言构建 / 运行 / golden 比对（唯一编译入口）
docs/                         详细设计 · 测试 · 运维 SOP · 概要设计
fixtures/
  gen_fixture.py              确定性生成器（唯一基准）
  demo.bin                    共享 binlog 测试字节（含 CRC32）
  expected.jsonl              统一 canonical JSONL 期望输出
c/       C11        + CMake + CTest      -> mysqlbinlog-c
cpp/     C++17      + CMake + CTest      -> mysqlbinlog-cpp
rust/    Rust stable (零依赖)             -> mysqlbinlog-rust
go/      Go 1.23    (标准库)             -> mysqlbinlog-go
java/    JDK 21     (javac, 零依赖)      -> mysqlbinlog-java
csharp/  .NET 8     (无 NuGet 包)        -> mysqlbinlog-cs
zig/     Zig 0.13   (零依赖)             -> mysqlbinlog-zig
erlang/  OTP        (erlc + EUnit)       -> mysqlbinlog-erl
python/  Python 3   (标准库)             -> mysqlbinlog-py
asm/     x86-64 NASM + gcc -no-pie       -> mysqlbinlog-asm   (xirasm)
```

## 语言与工具链（均在 CI 安装/使用，零第三方库依赖）

| 语言 | 构建 | 单测 | CLI |
| --- | --- | --- | --- |
| C | cmake + gcc | CTest (`assert`) | `mysqlbinlog-c` |
| C++ | cmake + g++ | CTest (`assert`) | `mysqlbinlog-cpp` |
| Rust | `cargo build` | `cargo test` | `mysqlbinlog-rust` |
| Go | `go build` | `go test ./...` | `mysqlbinlog-go` |
| Java | `javac` | 自建断言 `ParserTest` | `java -cp ... mysqlbinlog.Cli` |
| C# | `dotnet build` | 自建断言 Tests 项目 | `mysqlbinlog-cs.dll` |
| Zig | `zig build` | `zig build test` | `mysqlbinlog-zig` |
| Erlang | `erlc` | EUnit | `escript mysqlbinlog-erl` |
| Python | `py_compile` | `unittest` | `mysqlbinlog_cli.py` |
| x86-64 汇编 | `nasm -felf64` + `gcc -no-pie` | `--self-test` | `mysqlbinlog-asm` |

## 统一输出

CLI 读取 binlog 文件，逐事件输出一行 JSONL（键序固定、无空格）：

```bash
mysqlbinlog-go --file fixtures/demo.bin --format jsonl
```

```
{"type":"WRITE_ROWS_EVENT_V2","timestamp":1700000006,"table_id":108,"db":"financial_db","table":"transactions","rows":[[1001,7,"insert"]]}
{"type":"UPDATE_ROWS_EVENT_V2","timestamp":1700000007,"table_id":108,"db":"financial_db","table":"transactions","rows":[[1002,8,"before"],[1002,8,null]]}
```

十种语言的 stdout 都必须与 `fixtures/expected.jsonl` **逐字节一致**。

## 构建与验证

**本地不编译**。所有编译、运行、单测、golden 比对都在 GitHub Actions 完成：

```bash
# 查看 CI
gh run watch
gh run view <run-id> --log-failed
```

十种语言全部 `build + unit test + CLI 输出 diff golden` 通过，即达成「所有语言编译运行成功」。
CI 失败排查流程见 [docs/ops-sop.md](docs/ops-sop.md) §2。

如需本地重新生成测试数据（非编译）：

```bash
python3 fixtures/gen_fixture.py     # Linux/macOS/CI
python  fixtures/gen_fixture.py     # Windows（python3 是 Store stub）
```

## 受控子集与限制

本期 fixtures 使用明确定义的可复现字节（ROW / FULL / CRC32 / 未加密未压缩 / 单表三列），仅覆盖整数、字符串、NULL；DECIMAL / JSON / BLOB / 时间类型及在线复制协议留待后续阶段。汇编版字符串输出依赖该子集「纯 ASCII 无特殊字符」的约束（用 `printf("%.*s")`）。详见 [docs/design.md](docs/design.md) §1、§8。

## License

[MIT](LICENSE)
