# **MySQL Binlog CDC 多语言解析引擎——概要设计**

建议建立一个 GitHub 项目：

`mysql-binlog-lib`

使用 **C、C++、Rust、Go** 四种语言，分别实现独立的 MySQL Binlog 解析库和命令行程序（CLI），参考 Debezium 的架构设计，支持 MySQL 5.7、8.0、8.4 LTS，并逐步适配 MySQL 9.x。

这里要区分两项能力：

1. **Binlog 文件解析（Offline Parser）**：直接读取 `mysql-bin.000001` 等文件，解析事件。
2. **Binlog 实时订阅（Online CDC）**：通过 MySQL 3306 端口连接数据库，使用复制协议持续接收 Binlog。

推荐先完成离线解析，再实现在线 CDC，最后增加 Kafka Producer，使四种语言的实现能够独立运行、独立测试、独立压测。

## **一、总体架构**

四种语言采用相同的协议设计、事件模型和测试数据，但**分别编译成自己的库和可执行程序**，不通过 FFI 相互调用，便于比较实现质量和性能。

## **二、参考 Debezium 的哪些源码？**

Debezium 的源码可作为架构参考，但不建议逐行翻译成 C/C++/Rust/Go。

| Debezium 类或模块                      | 我们要实现的功能               |
| ---------------------------------- | ---------------------- |
| `MySqlConnector`                   | CDC 连接器生命周期            |
| `MySqlConnectorTask`               | 任务初始化、运行、停止            |
| `MySqlSnapshotChangeEventSource`   | 初始全量快照                 |
| `BinlogStreamingChangeEventSource` | Binlog 流式读取            |
| `MySqlDatabaseSchema`              | 表结构元数据管理               |
| `MySqlOffsetContext`               | Binlog Position / GTID |
| `BinaryLogClient`                  | MySQL 网络复制协议           |

Debezium 的 MySQL Connector 确实使用 `mysql-binlog-connector-java` 处理底层 Binlog 连接，并将任务生命周期、快照、流式读取、事件分发等能力分层实现。

[image](https://www.google.com/s2/favicons?domain=https://github.com\&sz=32)

GitHub+1



源码入口：

- [Debezium MySQL Connector](https://github.com/debezium/debezium/tree/main/debezium-connector-mysql?utm_source=chatgpt.com)
- [Debezium Binlog 公共模块](https://github.com/debezium/debezium/tree/main/debezium-connector-binlog?utm_source=chatgpt.com)
- [MySQL Binlog Java 协议库](https://github.com/debezium/mysql-binlog-connector-java?utm_source=chatgpt.com)
- [MySQL Replication Protocol 官方说明](https://dev.mysql.com/doc/dev/mysql-server/8.4.10/page_protocol_replication.html?utm_source=chatgpt.com)

## **三、MySQL 版本兼容设计**

MySQL 5.7、8.0、8.4 使用的主流 Binlog 格式属于 Version 4 格式族，但这并不意味着它们的事件类型、字段编码和网络认证协议完全相同。

[image](https://www.google.com/s2/favicons?domain=https://dev.mysql.com\&sz=32)

MySQL开发者专区



| 版本            | 设计目标         | 特别注意             |
| ------------- | ------------ | ---------------- |
| MySQL 5.7     | 完整支持 ROW CDC | 传统复制协议、GTID、JSON |
| MySQL 8.0     | 完整支持 ROW CDC | 认证方式、扩展元数据       |
| MySQL 8.4 LTS | 完整支持 ROW CDC | 复制协议兼容、默认配置变化    |
| MySQL 9.x     | 兼容适配目标       | 新事件与行为需逐版本测试     |
| MariaDB       | 暂不纳入首期       | GTID 和事件格式存在差异   |

建议 Phase 1 仅支持：

- `binlog_format=ROW`
- `binlog_row_image=FULL`
- 未加密的本地 Binlog 文件
- 未启用特殊行值压缩选项的普通 Row Event

MySQL 8.4 官方已经将 `binlog_format` 参数标记为弃用，并推荐新的复制系统只使用 ROW 模式。

[image](https://www.google.com/s2/favicons?domain=https://dev.mysql.com\&sz=32)

MySQL开发者专区



## **四、GitHub 项目目录设计**

```
mysql-binlog-lib/
├── README.md
├── LICENSE
├── .github/
│   └── workflows/
│
├── docs/
│   ├── architecture.md
│   ├── protocol.md
│   ├── event-format.md
│   ├── schema-registry.md
│   ├── compatibility.md
│   ├── error-handling.md
│   ├── performance.md
│   └── adr/
│
├── c/
│   ├── CMakeLists.txt
│   ├── include/mysqlbinlog/
│   │   ├── parser.h
│   │   ├── event.h
│   │   ├── reader.h
│   │   └── client.h
│   ├── internal/
│   │   ├── byte_reader.h
│   │   └── protocol_internal.h
│   ├── src/
│   │   ├── parser.c
│   │   ├── event.c
│   │   ├── reader.c
│   │   └── client.c
│   ├── examples/
│   │   └── main.c
│   └── tests/
│
├── cpp/
│   ├── CMakeLists.txt
│   ├── include/mysqlbinlog/
│   │   ├── parser.hpp
│   │   ├── event.hpp
│   │   └── client.hpp
│   ├── src/
│   ├── examples/main.cpp
│   └── tests/
│
├── rust/
│   ├── Cargo.toml
│   ├── src/
│   │   ├── lib.rs
│   │   ├── event.rs
│   │   ├── parser.rs
│   │   ├── reader.rs
│   │   └── bin/
│   │       └── mysqlbinlog.rs
│   └── tests/
│
├── go/
│   ├── go.mod
│   ├── binlog/
│   │   ├── parser.go
│   │   ├── event.go
│   │   └── reader.go
│   ├── cmd/mysqlbinlog/
│   │   └── main.go
│   └── tests/
│
├── fixtures/
│   ├── mysql57/
│   ├── mysql80/
│   ├── mysql84/
│   └── expected/
│
├── docker/
│   ├── mysql57/
│   ├── mysql80/
│   └── mysql84/
│
└── benchmarks/
    ├── workload.sql
    └── compare.py
```

每个语言版本包含独立的 Library、CLI、单元测试和集成测试。共享测试数据和输出规范，避免四种语言实现出来的行为不一致。

## **五、Binlog 解析器的模块划分**

| 模块                      | 职责                         | 优先级 |
| ----------------------- | -------------------------- | --- |
| FileReader              | 读取文件、偏移定位                  | P0  |
| ByteReader              | 小端整数、长度编码、字符串解析            | P0  |
| EventHeaderParser       | 解析 19 字节公共事件头              | P0  |
| FormatDescriptionParser | 解析版本、事件头长度、Checksum 配置     | P0  |
| TableMapParser          | 解析表 ID、列类型和元数据             | P0  |
| RowsEventParser         | 解析 INSERT、UPDATE、DELETE    | P0  |
| SchemaRegistry          | 缓存 Table ID 与表结构映射         | P0  |
| TransactionAssembler    | 识别事务边界、GTID、XID            | P1  |
| ReplicationClient       | TCP 连接、认证、Binlog Dump      | P1  |
| CheckpointStore         | 持久化 Binlog Position / GTID | P1  |
| SnapshotReader          | 初始全量数据读取                   | P2  |
| KafkaSink               | 输出到 Kafka Topic            | P2  |

### **5.1 Binlog 公共事件头**

MySQL Binlog 文件开头有四字节 Magic Number：

```
FE 62 69 6E
```

之后是一系列 Event。常见 Version 4 事件具有 19 字节公共头。

19 字节 Event Header 结构

timestamp

4 B

type

1 B

server_id

4 B

event_size

4 B

next_position

4 B

flags

2 B

合计

**19 bytes**

C 语言的数据结构：

```
typedef struct {
    uint32_t timestamp;
    uint8_t  event_type;
    uint32_t server_id;
    uint32_t event_size;
    uint32_t next_position;
    uint16_t flags;
} binlog_event_header_t;
```

注意：这个结构只是解析后的字段容器。不能直接通过 `fread(&header, sizeof(header), 1, file)` 读取磁盘数据，因为编译器可能添加结构体填充字节。

应该通过 ByteReader 按协议规定的小端字节序逐字段解码。

### **5.2 必须支持的 Event 类型**

| Event                      | 类型 ID | 用途              |
| -------------------------- | ----- | --------------- |
| `QUERY_EVENT`              | 2     | DDL / SQL 事件    |
| `ROTATE_EVENT`             | 4     | 切换 Binlog 文件    |
| `FORMAT_DESCRIPTION_EVENT` | 15    | Binlog 格式说明     |
| `XID_EVENT`                | 16    | 事务提交标记          |
| `TABLE_MAP_EVENT`          | 19    | Table ID 与表结构映射 |
| `WRITE_ROWS_EVENT_V2`      | 30    | INSERT          |
| `UPDATE_ROWS_EVENT_V2`     | 31    | UPDATE          |
| `DELETE_ROWS_EVENT_V2`     | 32    | DELETE          |
| `GTID_LOG_EVENT`           | 33    | GTID 事务标识       |

此外还要处理 `PREVIOUS_GTIDS_LOG_EVENT`、`HEARTBEAT_LOG_EVENT`、`ROWS_QUERY_LOG_EVENT`、Checksum，以及 MySQL 8.x 可能出现的扩展事件。

不能只实现上述 9 种事件就宣称完整兼容 MySQL 8.x。

## **六、四种语言的 Library API 设计**

统一采用 **Parser + Reader + Client + EventHandler** 模型。

### **6.1 C 语言 API**

```
/* include/mysqlbinlog/parser.h */

#ifndef MYSQL_BINLOG_PARSER_H
#define MYSQL_BINLOG_PARSER_H

#include <stddef.h>
#include <stdint.h>

typedef struct mb_parser mb_parser_t;

typedef struct {
    uint32_t timestamp;
    uint8_t event_type;
    uint32_t server_id;
    uint32_t event_size;
    uint32_t next_position;
    uint16_t flags;
} mb_event_header_t;

typedef struct {
    mb_event_header_t header;
    const uint8_t *payload;
    size_t payload_size;
} mb_event_t;

typedef enum {
    MB_OK = 0,
    MB_ERR_INVALID = -1,
    MB_ERR_TRUNCATED = -2,
    MB_ERR_UNSUPPORTED = -3,
    MB_ERR_CHECKSUM = -4
} mb_status_t;

mb_parser_t *mb_parser_create(void);

mb_status_t mb_parser_parse(
    mb_parser_t *parser,
    const uint8_t *data,
    size_t size,
    mb_event_t *event
);

void mb_parser_destroy(mb_parser_t *parser);

#endif
```

此接口属于底层 Event Parser，负责把一个完整事件缓冲区解析成 Header 和 Payload 视图。完整的 Row Decoder 再根据 Table Map 元数据解码列值。

使用示例：

```
#include <stdio.h>
#include "mysqlbinlog/parser.h"

int main(void)
{
    mb_parser_t *parser = mb_parser_create();

    if (parser == NULL) {
        return 1;
    }

    /* 后续由 FileReader 读取完整事件并调用解析器 */

    printf("MySQL Binlog Parser initialized\n");

    mb_parser_destroy(parser);
    return 0;
}
```

### **6.2 C++ API**

推荐 C++17，使用 RAII、`std::variant` 和 `std::unique_ptr`。

```
namespace mysqlbinlog {

struct EventHeader {
    uint32_t timestamp;
    uint8_t type;
    uint32_t server_id;
    uint32_t event_size;
    uint32_t next_position;
    uint16_t flags;
};

struct Event {
    EventHeader header;
    std::vector<uint8_t> payload;
};

class Parser {
public:
    Event parse(const std::vector<uint8_t>& bytes);
};

class FileReader {
public:
    explicit FileReader(const std::string& filename);

    bool next(Event& event);
};

}
```

CLI：

```
int main(int argc, char** argv)
{
    if (argc < 2) {
        return 1;
    }

    mysqlbinlog::FileReader reader(argv[1]);
    mysqlbinlog::Event event;

    while (reader.next(event)) {
        std::cout << "Event type: "
                  << static_cast<int>(event.header.type)
                  << '\n';
    }

    return 0;
}
```

### **6.3 Rust API**

推荐采用 `Result`、`enum`、`Read` Trait 等机制。

```
pub struct EventHeader {
    pub timestamp: u32,
    pub event_type: u8,
    pub server_id: u32,
    pub event_size: u32,
    pub next_position: u32,
    pub flags: u16,
}

pub struct Event {
    pub header: EventHeader,
    pub payload: Vec<u8>,
}

pub trait BinlogReader {
    fn next_event(&mut self)
        -> Result<Option<Event>, BinlogError>;
}

pub struct BinlogParser;

impl BinlogParser {
    pub fn parse(&self, data: &[u8])
        -> Result<Event, BinlogError>
    {
        todo!()
    }
}
```

Rust CLI：

```
fn main() -> Result<(), Box<dyn std::error::Error>> {
    println!("MySQL Binlog Parser");
    Ok(())
}
```

在线 CDC 可以采用 Tokio 异步 TCP 客户端，但离线解析器核心尽量保持同步、无网络依赖，方便 Fuzz Testing。

### **6.4 Go API**

推荐 Go 1.23+，使用 `io.Reader`、`context.Context` 和 Channel。

```
package binlog

import "io"

type EventHeader struct {
    Timestamp    uint32
    EventType    uint8
    ServerID     uint32
    EventSize    uint32
    NextPosition uint32
    Flags        uint16
}

type Event struct {
    Header  EventHeader
    Payload []byte
}

type Parser struct{}

func (p *Parser) Parse(data []byte) (*Event, error) {
    // TODO: implement binary event decoding
    return nil, nil
}

type Reader struct {
    source io.Reader
}

func NewReader(source io.Reader) *Reader {
    return &Reader{source: source}
}
```

CLI：

```
package main

import "fmt"

func main() {
    fmt.Println("MySQL Binlog Parser")
}
```

以上四种代码是 **API 骨架，不是已经实现完整解析的可运行产品**。后续需要逐模块完成协议解码、错误处理和测试。

## **七、统一 CDC 输出格式**

四种语言都输出相同 JSONL 事件，以便比较结果。

```
{
  "source": {
    "database": "financial_db",
    "table": "transactions",
    "binlog_file": "mysql-bin.000003",
    "binlog_position": 1280,
    "server_id": 1
  },
  "operation": "UPDATE",
  "before": {
    "id": 1001,
    "amount": "600.00"
  },
  "after": {
    "id": 1001,
    "amount": "800.00"
  }
}
```

这里的 `binlog_position` 定义为事件起始位置，另需在正式模型中保存事件结束位置及 GTID。

设计约束：

- `DECIMAL` 使用字符串，避免浮点精度损失。
- `BIGINT UNSIGNED` 不能随意转成有符号整数。
- `BLOB` 使用 Base64。
- `NULL` 与未出现在行镜像中的列必须区分。
- 时间类型保留精度、时区语义。
- JSON 字段需保留结构或原始表示。

## **八、CLI 功能设计**

四种语言提供一致的命令参数。

CLI 目标命令

```
# C
./mysqlbinlog-c parse --file mysql-bin.000001

# C++
./mysqlbinlog-cpp parse --file mysql-bin.000001

# Rust
./mysqlbinlog-rust parse --file mysql-bin.000001

# Go
./mysqlbinlog-go parse --file mysql-bin.000001
```

后续统一支持：

```
# 持续订阅 MySQL Binlog
mysqlbinlog-go stream \
  --host 127.0.0.1 \
  --port 3306 \
  --user cdc \
  --database financial_db \
  --table transactions

# JSONL 输出
mysqlbinlog-go parse \
  --file mysql-bin.000001 \
  --format jsonl

# Kafka 输出
mysqlbinlog-go stream \
  --host 127.0.0.1 \
  --port 3306 \
  --kafka-bootstrap localhost:9092 \
  --topic mysql.cdc.transactions
```

其中 `stream` 和 Kafka 输出属于后续阶段的目标接口。

## **九、关键技术难点**

### **9.1 Table Map 与 Row Event 解析**

Row Event 通常只包含 Table ID 和编码后的列值。

因此必须维护：

```
TABLE_MAP_EVENT
    table_id = 108
    database = financial_db
    table = transactions
    columns = [BIGINT, BIGINT, DECIMAL, VARCHAR]
                │
                ▼
UPDATE_ROWS_EVENT
    table_id = 108
    before = ...
    after  = ...
```

只解析 Row Event 而不处理 Table Map，无法可靠还原业务字段。

而且 Table Map 不一定包含完整列名信息，需要处理可选元数据或从数据库获取 Schema。

### **9.2 事务和 Checkpoint**

不能在收到单个 Row Event 后就无条件推进持久化消费进度。

需要考虑：

```
GTID
  ↓
BEGIN
  ↓
TABLE_MAP
  ↓
WRITE_ROWS
  ↓
UPDATE_ROWS
  ↓
XID / COMMIT
  ↓
确认下游写入
  ↓
保存 Checkpoint
```

在崩溃恢复时，应该从已安全提交的事务位置继续读取。

如果 Kafka 输出成功但 Checkpoint 尚未持久化，恢复后可能重复发送。因此需要明确至少一次投递与幂等处理；Exactly-Once 需要进一步设计 Kafka 事务与 Offset 的原子一致性。

### **9.3 安全与健壮性**

解析器必须防御不可信或损坏的二进制输入：

- 检查 Event 长度、列数量和所有缓冲区边界。
- 限制单个事件和内存分配大小。
- 校验 CRC32 Checksum。
- 未知事件按协议规则安全跳过或明确报错。
- 使用 AFL++、libFuzzer、cargo-fuzz、Go Fuzzing。
- 网络连接支持 TLS 和认证插件。
- 不支持的压缩、加密或部分 JSON 更新格式不得静默错误解析。

## **十、测试与性能基准**

建议使用官方 `mysqlbinlog` 输出作为重要的差异测试参考，同时验证真实 CDC 行数据、事务顺序与 Schema。

| 测试类型             | 测试内容                     |
| ---------------- | ------------------------ |
| Unit Test        | Header、整数、字符串、长度编码       |
| Golden Test      | 四种语言解析相同文件得到相同事件         |
| Integration Test | MySQL 5.7 / 8.0 / 8.4    |
| DML Test         | INSERT / UPDATE / DELETE |
| Schema Test      | ALTER TABLE、字段增删         |
| Recovery Test    | 断网、重启、Binlog Rotate      |
| Fuzz Test        | 损坏长度、截断数据、随机字节           |
| Benchmark        | 吞吐量、CPU、内存、延迟            |

性能指标建议

| 指标        | 统计单位            |
| --------- | --------------- |
| 解码吞吐      | Events/s        |
| 数据吞吐      | MB/s            |
| 单事件解析耗时   | μs/event        |
| 内存峰值      | MB              |
| CDC 端到端延迟 | P50 / P95 / P99 |
| 断线恢复时间    | 秒               |
| 数据正确性     | 丢失、重复、乱序事件数     |

基准测试应区分纯解析性能与网络 CDC 性能，避免把 Kafka、磁盘和 MySQL 的瓶颈误认为语言本身的差异。

## **十一、分阶段实施计划**

Phase 1

**离线 Binlog Parser**

实现 FileReader、Event Header、Format Description、Table Map 和 Rows Event；支持基本数值与字符串类型。

交付：四个独立库 + 四个 CLI + Golden Test

Phase 2

**完整行解码与事务解析**

支持 DECIMAL、JSON、BLOB、时间类型、GTID、XID、Checksum、Schema 变更。

交付：统一 CDC JSONL 输出

Phase 3

**在线 MySQL Replication Client**

实现 TCP、认证、COM_BINLOG_DUMP / GTID、Rotate、重连和 Offset 持久化。

交付：四语言实时 CDC 客户端

Phase 4

**Snapshot + Kafka**

实现初始快照、增量切换、Kafka Producer、故障恢复和幂等设计。

交付：MySQL → CDC → Kafka

Phase 5

**性能与工业化**

跨平台 CI、Fuzz、内存检测、版本兼容矩阵、性能基准、可观测性。

交付：完整测试报告与发布包

## **十二、工程验收标准**

项目达到以下条件，才可以称为一个具备实用价值的 MySQL Binlog CDC 实现：

1. 四种语言都能正确解析相同的 MySQL Binlog 测试文件。
2. 支持指定版本的常用 ROW 事件、数据类型和事务边界。
3. 可以通过 3306 端口实时订阅 MySQL Binlog。
4. 支持 Binlog Rotate、断线重连、Position / GTID 恢复。
5. 能正确处理 DDL 后的表结构变化。
6. Kafka Sink 能正确传递新增、更新、删除事件。
7. 通过 Windows 11、Linux 的构建和集成测试。
8. 有明确的兼容性限制、性能报告和异常处理策略。

**建议开发顺序：先完成 C 语言版的离线 Parser 作为协议学习基线，再并行实现 C++、Rust、Go，最后统一接入 MySQL Replication Protocol。**

这样能够深入研究 MySQL 二进制协议、跨语言内存模型、网络 I/O 和 CDC 一致性，而不只是对现有库进行简单包装。
