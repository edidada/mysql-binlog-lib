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
asm/     XIRASM 0.3.5 (x86-64 ELF64)    -> mysqlbinlog-asm   (xirasm)
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
| x86-64 汇编 | XIRASM 0.3.5（`format.inc` 直出 ELF64 + libc PLT 导入，零链接器） | `--self-test` | `mysqlbinlog-asm` |

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

# **mysql-binlog-lib：如何从零实现 MySQL Binlog 解析？**

建议把 `mysql-binlog-lib` 设计为一个**独立的二进制协议解析库**，先支持 MySQL 5.7、8.0、8.4 的常用 ROW Binlog，再增加实时 CDC 订阅能力。

核心原理是：

**读取二进制字节 → 解析 Event Header → 识别 Event Type → 解析 Table Map → 解码行数据 → 输出 INSERT / UPDATE / DELETE 事件。**

## **一、Binlog 文件内部结构**

```
mysql-bin.000001
│
├── Magic Number（4 字节）
│   FE 62 69 6E
│
├── FORMAT_DESCRIPTION_EVENT
│   ├── Event Header（19 字节）
│   └── Event Body
│
├── PREVIOUS_GTIDS_EVENT
│
├── GTID_EVENT
│
├── QUERY_EVENT（BEGIN）
│
├── TABLE_MAP_EVENT
│   ├── Table ID
│   ├── Database Name
│   ├── Table Name
│   └── Column Metadata
│
├── WRITE_ROWS_EVENT
│   └── INSERT 行数据
│
├── UPDATE_ROWS_EVENT
│   └── UPDATE 前后行数据
│
└── XID_EVENT（COMMIT）
```

MySQL Binlog 不是文本 SQL 日志，而是按照二进制协议编码的事件流。

例如：

```
INSERT INTO users(id, name, age)
VALUES (1, 'Alice', 25);
```

在 ROW 模式下，Binlog 主要记录表映射和插入后的行值，而不是简单保存这条 SQL 字符串。

## **二、解析器的核心模块**

```
mysql-binlog-lib/
├── include/mysqlbinlog/
│   ├── binlog.h          # 对外统一 API
│   ├── event.h           # 事件模型
│   ├── parser.h          # 解析器 API
│   └── reader.h          # 文件读取 API
│
├── internal/
│   ├── byte_reader.h     # 字节读取工具
│   ├── event_parser.h    # 事件解析内部接口
│   └── table_map.h       # Table ID 映射
│
├── src/
│   ├── byte_reader.c
│   ├── event_parser.c
│   ├── table_map.c
│   ├── row_decoder.c
│   ├── binlog_reader.c
│   └── binlog.c
│
├── examples/
│   └── main.c
│
├── tests/
└── CMakeLists.txt
```

每个模块的职责：

| 模块           | 作用                    |
| ------------ | --------------------- |
| ByteReader   | 按小端序读取整数、字符串、长度编码     |
| EventParser  | 解析公共事件头和事件体           |
| TableMap     | 保存 Table ID 与表结构的对应关系 |
| RowDecoder   | 根据列类型解码每行数据           |
| BinlogReader | 顺序读取 Binlog 文件        |
| CDC Event    | 将原始事件转换为统一业务变更对象      |

**最难的部分不是读取文件，而是根据&#x20;**`TABLE_MAP_EVENT`**&#x20;正确解码&#x20;**`ROWS_EVENT`**。**

## **三、先实现一个真正可运行的 C 语言版本**

第一阶段先实现：

- 校验 Binlog Magic Number。
- 按小端字节序解析 19 字节 Event Header。
- 读取完整 Event。
- 识别常见事件类型。
- 输出 Event 起始偏移、类型、长度和下一个位置。

这部分可以直接在 Windows 11、Linux、macOS 上编译运行，不依赖 MySQL 客户端库。

### **1. 对外头文件：**`include/mysqlbinlog/parser.h`

```

#ifndef MYSQLBINLOG_PARSER_H
#define MYSQLBINLOG_PARSER_H

#include <stdint.h>
#include <stdio.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint32_t timestamp;
    uint8_t  type;
    uint32_t server_id;
    uint32_t event_size;
    uint32_t next_position;
    uint16_t flags;
} mb_event_header_t;

typedef enum {
    MB_OK = 0,
    MB_EOF = 1,
    MB_ERROR = -1
} mb_status_t;

typedef struct {
    FILE *fp;
    uint64_t offset;
} mb_reader_t;

int mb_reader_open(mb_reader_t *reader, const char *filename);

int mb_reader_next(
    mb_reader_t *reader,
    mb_event_header_t *header
);

void mb_reader_close(mb_reader_t *reader);

const char *mb_event_type_name(uint8_t type);

#ifdef __cplusplus
}
#endif

#endif

```

### **2. 实现文件：**`src/parser.c`

```

#include "mysqlbinlog/parser.h"

#include <stdlib.h>
#include <string.h>

#define MB_HEADER_SIZE 19
#define MB_MAX_EVENT_SIZE (256U * 1024U * 1024U)

static uint16_t read_le16(const unsigned char *p)
{
    return (uint16_t)p[0]
         | ((uint16_t)p[1] << 8);
}

static uint32_t read_le32(const unsigned char *p)
{
    return (uint32_t)p[0]
         | ((uint32_t)p[1] << 8)
         | ((uint32_t)p[2] << 16)
         | ((uint32_t)p[3] << 24);
}

int mb_reader_open(mb_reader_t *reader, const char *filename)
{
    unsigned char magic[4];

    if (!reader || !filename) {
        return MB_ERROR;
    }

    memset(reader, 0, sizeof(*reader));

    reader->fp = fopen(filename, "rb");
    if (!reader->fp) {
        return MB_ERROR;
    }

    if (fread(magic, 1, 4, reader->fp) != 4 ||
        memcmp(magic, "\xFE\x62\x69\x6E", 4) != 0) {
        mb_reader_close(reader);
        return MB_ERROR;
    }

    reader->offset = 4;
    return MB_OK;
}

int mb_reader_next(
    mb_reader_t *reader,
    mb_event_header_t *header)
{
    unsigned char raw[MB_HEADER_SIZE];

    if (!reader || !reader->fp || !header) {
        return MB_ERROR;
    }

    size_t n = fread(raw, 1, sizeof(raw), reader->fp);

    if (n == 0 && feof(reader->fp)) {
        return MB_EOF;
    }

    if (n != sizeof(raw)) {
        return MB_ERROR;
    }

    header->timestamp     = read_le32(raw);
    header->type          = raw[4];
    header->server_id     = read_le32(raw + 5);
    header->event_size    = read_le32(raw + 9);
    header->next_position = read_le32(raw + 13);
    header->flags         = read_le16(raw + 17);

    if (header->event_size < MB_HEADER_SIZE ||
        header->event_size > MB_MAX_EVENT_SIZE) {
        return MB_ERROR;
    }

    size_t remaining = header->event_size - MB_HEADER_SIZE;
    unsigned char buffer[8192];

    while (remaining > 0) {
        size_t chunk = remaining < sizeof(buffer)
                     ? remaining
                     : sizeof(buffer);

        if (fread(buffer, 1, chunk, reader->fp) != chunk) {
            return MB_ERROR;
        }

        remaining -= chunk;
    }

    reader->offset += header->event_size;
    return MB_OK;
}

void mb_reader_close(mb_reader_t *reader)
{
    if (!reader) {
        return;
    }

    if (reader->fp) {
        fclose(reader->fp);
        reader->fp = NULL;
    }
}

const char *mb_event_type_name(uint8_t type)
{
    switch (type) {
        case 2:  return "QUERY_EVENT";
        case 4:  return "ROTATE_EVENT";
        case 15: return "FORMAT_DESCRIPTION_EVENT";
        case 16: return "XID_EVENT";
        case 19: return "TABLE_MAP_EVENT";
        case 30: return "WRITE_ROWS_EVENT_V2";
        case 31: return "UPDATE_ROWS_EVENT_V2";
        case 32: return "DELETE_ROWS_EVENT_V2";
        case 33: return "GTID_EVENT";
        case 35: return "PREVIOUS_GTIDS_EVENT";
        case 40: return "TRANSACTION_PAYLOAD_EVENT";
        default: return "OTHER_EVENT";
    }
}

```

这段代码读取完整事件，但只解码公共头，事件体目前被读取并丢弃。它还没有实现 Checksum 校验、Table Map 和行值解析。

### **3. CLI：**`examples/main.c`

```

#include <inttypes.h>
#include <stdio.h>

#include "mysqlbinlog/parser.h"

int main(int argc, char **argv)
{
    if (argc != 2) {
        fprintf(stderr, "Usage: %s <binlog-file>\n", argv[0]);
        return 1;
    }

    mb_reader_t reader;

    if (mb_reader_open(&reader, argv[1]) != MB_OK) {
        fprintf(stderr, "Cannot open binlog: %s\n", argv[1]);
        return 1;
    }

    mb_event_header_t event;
    int result;

    while ((result = mb_reader_next(&reader, &event)) == MB_OK) {
        uint64_t start = reader.offset - event.event_size;

        printf(
            "offset=%" PRIu64
            " type=%s"
            " size=%" PRIu32
            " next=%" PRIu32
            " server_id=%" PRIu32 "\n",
            start,
            mb_event_type_name(event.type),
            event.event_size,
            event.next_position,
            event.server_id
        );
    }

    mb_reader_close(&reader);

    if (result != MB_EOF) {
        fprintf(stderr, "Binlog parse error\n");
        return 1;
    }

    return 0;
}

```

### **4. CMake 编译**

```

cmake_minimum_required(VERSION 3.16)

project(mysql_binlog_lib LANGUAGES C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)

add_library(mysqlbinlog STATIC
    src/parser.c
)

target_include_directories(mysqlbinlog PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

add_executable(mysqlbinlog_cli
    examples/main.c
)

target_link_libraries(mysqlbinlog_cli PRIVATE
    mysqlbinlog
)

```

Windows 11（VS2022）：

```
cmake -S . -B build -G "Visual Studio 17 2022"
cmake --build build --config Release

.\build\Release\mysqlbinlog_cli.exe mysql-bin.000001
```

Linux：

```
cmake -S . -B build
cmake --build build

./build/mysqlbinlog_cli mysql-bin.000001
```

示例输出格式：

```
offset=4 type=FORMAT_DESCRIPTION_EVENT size=125 next=129 server_id=1
offset=129 type=PREVIOUS_GTIDS_EVENT size=31 next=160 server_id=1
offset=160 type=GTID_EVENT size=42 next=202 server_id=1
offset=202 type=QUERY_EVENT size=71 next=273 server_id=1
offset=273 type=TABLE_MAP_EVENT size=55 next=328 server_id=1
offset=328 type=WRITE_ROWS_EVENT_V2 size=48 next=376 server_id=1
offset=376 type=XID_EVENT size=31 next=407 server_id=1
```

这些数字只是演示输出格式，实际取决于你的 Binlog 文件。

## **四、第二阶段：真正解析 INSERT / UPDATE / DELETE**

接下来必须实现两个核心函数：

```
int mb_parse_table_map(
    mb_parser_t *parser,
    const uint8_t *payload,
    size_t payload_size
);

int mb_parse_rows_event(
    mb_parser_t *parser,
    uint8_t event_type,
    const uint8_t *payload,
    size_t payload_size,
    mb_row_callback callback,
    void *user_data
);
```

处理过程：

关键步骤：

1. 解析 `FORMAT_DESCRIPTION_EVENT`，确定格式参数及 Checksum 算法。
2. 解析 `TABLE_MAP_EVENT`，读取 6 字节 Table ID、表名、列类型、列元数据和 NULL 位图。
3. 将 Table ID 映射缓存起来。
4. 解析 `ROWS_EVENT`，读取列数量、列存在位图、NULL 位图。
5. 根据列类型逐列解码，并区分 `before` 和 `after`。
6. 结合 GTID、XID 和事务状态，输出已提交的 CDC 事件。

MySQL 官方 `rows_event.h` 给出了 Table Map 和 Rows Event 的二进制布局，可直接作为协议实现的依据。

[image](https://www.google.com/s2/favicons?domain=https://dev.mysql.com\&sz=32)

MySQL开发者专区+1



还有几个容易遗漏的问题：单个 Rows Event 可以包含多行；`UPDATE` 有两组列位图；`binlog_row_image=MINIMAL` 时可能缺少未修改字段；列名、字符集等信息不一定完整存在于 Binlog 中，需要额外的 Schema 管理。

## **五、如何验证解析结果？**

先使用 MySQL 官方工具产生参考结果：

```
mysqlbinlog \
  --base64-output=DECODE-ROWS \
  -vv \
  mysql-bin.000001
```

MySQL 官方文档确认，`-vv` 能显示行事件的详细信息，适合与自研解析器进行差异比较。

[image](https://www.google.com/s2/favicons?domain=https://dev.mysql.com\&sz=32)

Utility for Processing Binary Log Files



推荐以这三个官方资料为准：

- [MySQL Event Header 定义](https://dev.mysql.com/doc/dev/mysql-server/8.4.10/binlog__event_8h.html?utm_source=chatgpt.com)
- [MySQL Table Map / Rows Event 源码](https://dev.mysql.com/doc/dev/mysql-server/8.4.11/rows__event_8h_source.html?utm_source=chatgpt.com)
- [mysqlbinlog 官方使用文档](https://dev.mysql.com/doc/refman/8.4/en/mysqlbinlog.html?utm_source=chatgpt.com)

**开发建议：** 第一阶段的代码已经能验证 Binlog 文件结构和 Event 边界。下一阶段应优先实现 `FORMAT_DESCRIPTION_EVENT + TABLE_MAP_EVENT + WRITE_ROWS_EVENT_V2`，让程序真正解析出 `INSERT users(1, 'Alice', 25)`，再扩展 UPDATE、DELETE、事务、GTID 和实时复制协议。