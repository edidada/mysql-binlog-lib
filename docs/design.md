# 详细设计（Detailed Design）

> 本文是 `mysql-binlog-lib` 的**实现规约**，是十语言（C / C++ / Rust / Go / Java / C# / Zig / Erlang / Python / x86-64 汇编）编码与 golden test 的唯一基准。
> 概要设计与路线图见 [overview.md](overview.md)；测试策略见 [testing.md](testing.md)；发布与故障处理见 [ops-sop.md](ops-sop.md)。

## 1. 本期范围（Phase 1：离线 Binlog 解析基线）

本期交付**离线 Binlog 解析器**：读取 `mysql-bin.000001` 这类文件，按字节解码事件，输出统一的 JSONL。
暂不实现在线 CDC（3306 复制协议）、Snapshot、Kafka Sink（属 Phase 3/4，见 overview.md）。

十种语言**各自独立**实现 Library + CLI + 单测，不通过 FFI 互相调用，共享同一份测试字节与输出规范，便于对比实现质量。

### 1.1 受控子集（Controlled Subset）

为让十种语言在没有本地编译条件、仅靠 CI 验证的情况下能可靠对齐，fixtures 使用一组**明确定义、可复现**的字节：

- MySQL Version 4 binlog 格式族；`binlog_format=ROW`；`binlog_row_image=FULL`。
- 未加密、未压缩、未启用行值压缩。
- 每个事件都带 CRC32 校验；`FORMAT_DESCRIPTION_EVENT` 声明 `checksum_alg=1`。
- 一张表：`financial_db.transactions(id LONGLONG, user_id LONG, note VARCHAR)`。
- 列值仅覆盖：有符号整数、字符串、`NULL`（DECIMAL/JSON/BLOB/时间类型留待 Phase 2，详见 §8）。

> 该子集由 `fixtures/gen_fixture.py` 确定性生成，CI 会重新生成并用 `git diff --exit-code` 校验提交物未漂移。

## 2. 文件与事件字节布局

### 2.1 文件头（Magic）

```
FE 62 69 6E        # \xfe b i n
```

4 字节，非事件。解析器首先校验，失败即报错退出。

### 2.2 公共事件头（19 字节，小端）

| 偏移 | 长度 | 字段 | 类型 |
| --- | --- | --- | --- |
| 0 | 4 | timestamp | u32 LE |
| 4 | 1 | event_type | u8 |
| 5 | 4 | server_id | u32 LE |
| 9 | 4 | event_size | u32 LE（含头 + 体 + 4 字节 CRC） |
| 13 | 4 | next_position | u32 LE（本事件结束后的文件偏移） |
| 17 | 2 | flags | u16 LE |

合计 **19 字节**。禁止用 `fread(&struct,...)` 直接读结构体（编译器填充/字节序问题），必须逐字段按小端解码。

### 2.3 事件帧（Framing）

```
+-------------+-------------------+-----------+
| header(19)  | body (N bytes)    | CRC32(4)  |
+-------------+-------------------+-----------+
             event_size = 19 + N + 4
```

- `CRC32` = 标准 CRC-32（IEEE 802.3，多项式 `0xEDB88320`，初值 `0xFFFFFFFF`，末异或 `0xFFFFFFFF`，等价 zlib `crc32` / Go `crc32.ChecksumIEEE`），覆盖 `header + body`（即 `event[0 : event_size-4]`），以 **u32 小端**存放。
- 解析流程：读 19 字节头 → 得 `event_size` → 读完整个事件 `event[0:event_size]` → 校验 `crc32(event[0:event_size-4]) == u32le(event[event_size-4:])` → 取 `body = event[19 : event_size-4]` → 按 `event_type` 分派。
- 任一步越界或 CRC 不符 → 该语言 CLI 以**非零码退出**（CI 据此判定失败）。

### 2.4 通用 ByteReader 原语

| 原语 | 说明 |
| --- | --- |
| `u8/u16/u24/u32/u48/u64` | 小端无符号 |
| `i32/i64` | 小端有符号（本子集取正值） |
| `lenenc_int` | MySQL 长度编码整数：`<0xFB` 单字节；`0xFC` 后接 u16；`0xFD` 后接 u24；`0xFE` 后接 u64；`0xFB` 表示 NULL |
| `str_n(n)` | 定长 n 字节 |
| `str_lenenc` | lenenc 长度 + 对应字节 |
| `cstr` | 以 `0x00` 结尾 |
| `hex(n)` | n 字节转小写十六进制字符串 |

所有读取必须做边界检查；越界返回错误而非崩溃。

## 3. 支持的事件类型

| 名称 | type_id | 处理 |
| --- | --- | --- |
| `FORMAT_DESCRIPTION_EVENT` | 15 | 解析版本、server_version、checksum_alg |
| `QUERY_EVENT` | 2 | 解析 db / query（含 BEGIN / DDL） |
| `ROTATE_EVENT` | 4 | 解析 position / next_file |
| `XID_EVENT` | 16 | 事务提交标记 |
| `TABLE_MAP_EVENT` | 19 | 注册 SchemaRegistry |
| `WRITE_ROWS_EVENT_V2` | 30 | 行解码（INSERT） |
| `UPDATE_ROWS_EVENT_V2` | 31 | 行解码（before + after） |
| `DELETE_ROWS_EVENT_V2` | 32 | 行解码（DELETE） |
| `GTID_LOG_EVENT` | 33 | GTID 事务标识 |
| `ROWS_QUERY_LOG_EVENT` | 29 | 原始 SQL |
| 其它 | * | 安全跳过，输出 `UNKNOWN` |

### 3.1 FORMAT_DESCRIPTION_EVENT（15）

body（受控布局，共 96 字节）：

```
0   2   binlog_version   u16 LE (=4)
2   50  server_version   定长，遇 NUL 截断 (= "8.0.36")
52  4   create_timestamp u32 LE
56  1   common_header_len u8 (=19)
57  38  post_header_len[]（本子集忽略，仅占位）
95  1   checksum_alg     u8 (=1，body 最后一字节)
```

解析器读取 `binlog_version`、`body[2:52]` 的 server_version、`body[-1]` 的 checksum_alg；中间字段按协议跳过。

### 3.2 GTID_LOG_EVENT（33）

```
0   1   flags     u8 (=0)
1   16  sid       UUID 字节
17  8   gno       u64 LE (=42)
```

### 3.3 QUERY_EVENT（2）

```
0   4  thread_id       u32
4   4  exec_time       u32
8   1  db_len          u8
9   2  error_code      u16
11  2  status_vars_len u16
13  status_vars_len    status_vars[]（跳过）
..  db_len             db[]
..  1                  0x00
..  剩余                 query[]（到 body 末尾）
```

解析出 `db` 与 `query`。本子集 fixtures 中 `status_vars_len=0`、`db="financial_db"`、`query="BEGIN"`。

### 3.4 ROWS_QUERY_LOG_EVENT（29）

```
lenenc 长度 + query 字节串
```

### 3.5 TABLE_MAP_EVENT（19）

```
0   6  table_id        u48 LE (=108)
6   2  flags           u16
8   1  db_len          u8
9   db_len             db[]
..  1                  0x00
..  1  table_len       u8
..  table_len          table[]
..  1                  0x00
..  lenenc             column_count (=3)
..  column_count       column_types[] (=[8,3,15])
..  lenenc             metadata_len (=2)
..  metadata_len       metadata[]（VARCHAR 占 2 字节 = maxlen=64）
..  ceil(column_count/8)  null_bitmap（标记可空列，本子集 =0x07，3 列均可空）
```

解析器据此在 **SchemaRegistry** 中以 `table_id` 为键注册：`db`、`table`、`column_types[]`、每个 VARCHAR 列的长度前缀字节数（`maxlen>255→2` 否则 `1`）、`nullable_count`（null_bitmap 置位数）。

> 注意：Table Map 不含列名，故输出的行值用**数组**而非具名对象，避免臆造列名（见 §5）。

### 3.6 ROWS_EVENT_V2（30 / 31 / 32）

```
0   6  table_id           u48 LE
6   2  flags              u16
8   2  extra_data_len     u16（含自身 2 字节；本子集 =2，故 extra_data 长度 0）
10  extra_data_len-2      extra_data[]（跳过）
..  lenenc                column_count
..  ceil(column_count/8)  columns_present_bitmap1（本子集 =0x07）
..  ceil(column_count/8)  columns_present_bitmap2（仅 UPDATE=31，=0x07）
..  rows[]                行序列，直到 body 结束
```

每行：

```
ceil(nullable_count/8)  null_bitmap（本子集 =1 字节）
对每个 present 的列 i（按列序）：
    null_bitmap 第 i 位置位  -> 值 NULL，无字节
    否则按 column_types[i] 解码：
        8  LONGLONG  -> 8 字节 i64 LE
        3  LONG      -> 4 字节 i32 LE
        15 VARCHAR   -> (1|2) 字节长度 + 字节串（长度前缀字节数由 Table Map metadata 决定）
```

`WRITE/DELETE` 为 1 行，`UPDATE` 为 2 行（before、after，连续存放）。解析器循环读取直到 body 耗尽。

### 3.7 XID_EVENT（16） / ROTATE_EVENT（4）

```
XID:    8 字节 u64 LE xid
ROTATE: 8 字节 u64 LE position + 剩余字节 next_file（字符串）
```

## 4. 模块划分与状态机

十语言统一采用 `Parser + Reader + SchemaRegistry + Serializer` 模型：

```
read_file
  └─ verify magic
      └─ loop events:
           read header(19) -> event_size
           read full event -> verify CRC32
           body = event[19 : size-4]
           dispatch(type):
             FDE        -> record checksum_alg
             TABLE_MAP  -> schema.register(table_id, ...)
             ROWS_V2    -> schema.lookup(table_id) -> decode rows
             others     -> decode fields / skip
           emit one canonical JSONL line
```

- **SchemaRegistry**：`table_id → TableSchema`，生命周期覆盖整个文件；RowsEvent 解码前必须查到对应 Table Map，否则报错。
- **错误码**：`OK / INVALID / TRUNCATED / UNSUPPORTED / CHECKSUM / NO_SCHEMA`。越界即 `TRUNCATED`，CRC 不符即 `CHECKSUM`。

## 5. 统一 JSONL 输出规范（Canonical JSONL）

- 每行一个 JSON 对象；**键顺序固定、无空格**；字符串用最小转义（`"` `\` `\n` `\r` `\t` 及 `<0x20`）；整数十进制；`null` 表示 SQL NULL。
- 所有整数值在受控子集中均为非负且小于 2^63，序列化统一按十进制输出。
- 事件名使用上表名称；未识别类型输出 `UNKNOWN`。

各事件的精确键顺序（`T` = header timestamp）：

```
FORMAT_DESCRIPTION_EVENT : type,timestamp,binlog_version,server_version,checksum_alg
GTID_LOG_EVENT           : type,timestamp,gno,sid
QUERY_EVENT              : type,timestamp,db,query
ROWS_QUERY_LOG_EVENT     : type,timestamp,query
TABLE_MAP_EVENT          : type,timestamp,table_id,db,table,column_count,column_types
WRITE/UPDATE/DELETE_V2   : type,timestamp,table_id,db,table,rows
XID_EVENT                : type,timestamp,xid
ROTATE_EVENT             : type,timestamp,position,next_file
UNKNOWN                  : type,timestamp,type_id,event_size
```

`rows` 为二维数组，元素为 `int | string | null`，例如：
`[[1002,8,"before"],[1002,8,null]]`。

完整期望输出见 `fixtures/expected.jsonl`（由 `gen_fixture.py` 生成）。

## 6. CLI 契约

```
<bin> --file <path> [--format jsonl] [--help]
```

- 默认 `--format jsonl`；读取 `<path>` 的原始 binlog 字节，成功时逐行输出 JSONL 到 stdout 并返回 0。
- `--help` 打印用法返回 0；参数错误 / 文件不存在 / 解析失败 → 非零码，错误写 stderr。
- 除 JSONL 外的调试信息一律走 stderr，保证 stdout 可直接 `diff`。

各语言二进制名：`mysqlbinlog-c` / `mysqlbinlog-cpp` / `mysqlbinlog-rust` / `mysqlbinlog-go`。

## 7. 各语言工程结构

十语言互不使用 FFI，各自独立实现同一套 `Parser + Reader + SchemaRegistry + Serializer` 模型。

```
c/       CMakeLists.txt, include/mysqlbinlog.h, src/mysqlbinlog.c,
         examples/main.c, tests/test_parser.c          (C11, -Wall -Wextra, CTest)
cpp/     CMakeLists.txt, include/mysqlbinlog.hpp, src/mysqlbinlog.cpp,
         examples/main.cpp, tests/test_parser.cpp      (C++17, CTest)
rust/    Cargo.toml, src/lib.rs (#[cfg(test)] 单测), src/main.rs  (零外部依赖)
go/      go.mod, binlog/parser.go, binlog/parser_test.go,
         cmd/mysqlbinlog/main.go                       (标准库)
java/    src/mysqlbinlog/{Parser,Cli}.java,
         test/mysqlbinlog/ParserTest.java             (JDK 21 javac, 零依赖)
csharp/  src/{Parser.cs, Program.cs, MysqlBinlog.csproj},
         tests/{Program.cs, MysqlBinlog.Tests.csproj} (.NET 8, 无 NuGet 包)
zig/     build.zig, src/{parser.zig,main.zig}         (Zig 0.13.0, zig build test)
erlang/  src/{mysqlbinlog.erl,mysqlbinlog_cli.erl}, test/mysqlbinlog_tests.erl,
         mysqlbinlog-erl (escript)                    (OTP erlc + EUnit)
python/  mysqlbinlog.py, mysqlbinlog_cli.py, test_parser.py (标准库 unittest)
asm/     main.asm                                    (x86-64 NASM + gcc -no-pie)
```

| 语言 | CRC32 实现 | 单测载体 | 备注 |
| --- | --- | --- | --- |
| C / C++ / Java / C# / Zig / Erlang / asm / Python | 手写位运算（IEEE） | 各自 runner | 与 zlib 标准向量一致 |
| Go | 标准库 `hash/crc32.ChecksumIEEE` | `go test` | 与 zlib 一致 |
| Rust | 手写位运算 | `#[cfg(test)]` | 零外部 crate |

- 依赖策略：**全部零第三方库依赖**，避免 CI 拉取网络依赖导致不稳定。工具链本身由 CI 的 setup action / apt 安装（见 ops-sop.md §1），不算库依赖。
- Python 用 `json.dumps(..., separators=(',',':'))` + 保序 dict 生成 canonical JSONL；其余语言手写 serializer，保证键序一致。
- 汇编版 (xirasm) 用 libc `printf` 输出，字符串依赖受控子集「纯 ASCII 无特殊字符」的约束（`%.*s` 不做 JSON 转义）；其余九语言实现完整转义。
- 构建与验证统一由 `.github/workflows/ci.yml` 完成；**本地不编译**（见 ops-sop.md §2）。

## 8. 与后续阶段的边界

| 能力 | 本期 | 后续 |
| --- | --- | --- |
| 离线解析 Header / FDE / TableMap / RowsV2 / GTID / XID / Query / Rotate | ✅ | — |
| CRC32 校验、SchemaRegistry、统一 JSONL | ✅ | — |
| DECIMAL / JSON / BLOB / 时间类型 / 列元数据 | ❌ | Phase 2 |
| 在线 Replication Client、GTID 续传、断线重连 | ❌ | Phase 3 |
| Snapshot、Kafka Sink、Exactly-Once | ❌ | Phase 4 |
| Fuzz、跨平台矩阵、性能基准 | 基础 | Phase 5 |

DECIMAL 建议以字符串输出避免精度损失；BIGINT UNSIGNED 不得转有符号；BLOB 用 Base64；`NULL` 与「未出现在行镜像中的列」必须区分 —— 这些在 Phase 2 落地时须写入统一输出模型。
