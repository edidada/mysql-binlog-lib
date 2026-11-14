# 运维 SOP（Operations Runbook）

> 面向维护者：发布、CI 故障定位、版本兼容、依赖与安全。详细规约见 [design.md](design.md)，测试分层见 [testing.md](testing.md)。

## 0. 关键约束：本地不编译

本项目约定 **本地不做任何编译/构建**（不执行 `cmake --build` / `cargo build` / `go build` / `gcc` 等）。
所有编译、运行、测试、golden 比对均由 `.github/workflows/ci.yml` 在 GitHub Actions（ubuntu-latest）完成。

- 本地仅允许：编辑源码、编写文档、**运行 `fixtures/gen_fixture.py` 生成测试数据**（数据生成，非编译）、`git` 操作、`gh` 查看 CI。
- Windows 本地 Python 命令为 `python`（`python3` 是 Store 占位 stub）；CI 统一用 `python3`。
- 好处：构建环境与产物在 CI 可复现，避免「在我机器上能过」。代价：必须靠 CI 日志定位编译错误（见 §2）。

## 1. CI 工作流速查

| 项 | 值 |
| --- | --- |
| 文件 | `.github/workflows/ci.yml` |
| 触发 | `push` / `pull_request` / `workflow_dispatch` |
| Runner | `ubuntu-latest`，矩阵 `lang ∈ {c, cpp, rust, go}` |
| 工具链 | cmake+gcc/g++（预装）、`dtolnay/rust-toolchain@stable`、`actions/setup-go@v5`（Go 1.23）、`python3` |
| 权限 | `contents: read` |

每个 job 固定 6 步：checkout → 装工具链 → 生成并校验 fixtures → 构建 → 单测 → 运行 CLI 并 `diff` golden。

常用命令：

```bash
gh run list --limit 10                 # 最近运行
gh run watch                           # 实时等待当前分支最新运行
gh run view <run-id> --log-failed      # 只看失败日志
gh run rerun <run-id> --failed         # 重跑失败 job
gh workflow run ci.yml                 # 手动触发（workflow_dispatch）
```

## 2. SOP：CI 变红（Red Build）

1. `gh run view <run-id> --log-failed` 拉取失败日志，先定位**哪个 job、哪一步**。
2. 按错误类型处理：
   - **编译错误**（`error:` / `cannot find` / `mismatch`）：按日志行号改对应语言源码；注意四语言是独立实现，勿只修一处。
   - **单测失败**：核对 CRC32 / 事件头 / 行解码断言；`crc32("123456789")==0xCBF43926` 是标准向量。
   - **golden diff 失败**：对比 `expected.jsonl` 与实际输出；**不得**改 `expected.jsonl` 去迁就实现，先确认解码逻辑。canonical 键序/无空格规则见 design.md §5。
   - **`git diff --exit-code` fixtures 失败**：说明提交的 `demo.bin`/`expected.jsonl` 与 `gen_fixture.py` 不一致；重新生成并提交两个文件。
   - **工具链/网络**：setup-go / rust-toolchain 版本异常 → 检查 action 版本与 Go/Rust 版本声明。
3. 本地**只改代码**，不编译；`git add -A && git commit -m "fix(ci): ..." && git push` → CI 重跑。
4. 迭代直到四个 job 全绿，确认「所有语言编译运行成功」。

> 排错纪律：一次只改一个根因；提交信息带 `fix(ci):` / `fix(<lang>):` 前缀，便于回溯。

## 3. SOP：发布一个版本

1. 确认 `main` 上 CI 全绿（`gh run list`）。
2. 汇总变更，更新 `README.md` 的 Phase 状态与 `docs/design.md` §8 边界表。
3. 打注解标签：`git tag -a v0.1.0 -m "Phase 1 offline parser baseline" && git push origin v0.1.0`。
4. 如需产物，后续可在 CI 增加 `release` job 上传四语言二进制（本期仅源码发布，不含产物）。
5. 在 Release Notes 写明：受控子集范围、支持的 MySQL 版本、已知限制、golden 覆盖的事件类型。

## 4. SOP：新增 / 升级 MySQL 版本兼容

1. 参考 overview.md「MySQL 版本兼容设计」，先确认目标版本的事件类型、认证、binlog 默认配置差异。
2. 在 `fixtures/` 增加对应目录（如 `fixtures/mysql84/`）与 `gen_fixture.py` 中的版本化事件变体。
3. 更新 `docs/design.md` 的兼容性矩阵与 `docs/testing.md` 的集成测试矩阵。
4. 四语言分别补齐新事件 / 新类型解码，保持 canonical JSONL 不变。
5. CI matrix 增加对应集成 job（Phase 3 后接入真实 MySQL 容器）。

## 5. SOP：依赖与安全

- **零第三方依赖原则**：新增依赖需评审；能标准库/手写实现的（如 CRC32）不引外部 crate / 模块，降低 CI 网络失败面。
- 工具链版本在 `ci.yml` 显式钉住（Go 1.23、Rust stable、cmake 用 runner 预装）。升级前先开 PR 验证四语言全绿。
- 解析器必须防御不可信字节：所有读取做边界检查、限制单事件/内存分配上限、校验 CRC32、未知事件安全跳过。Fuzz 接入后把崩溃样本固化为回归测试。
- `permissions: contents: read` 最小权限；不在 workflow 中打印密钥；CI 不需要任何 secret 即可跑通。

## 6. SOP：回滚

- 代码回滚：`git revert <commit> && git push`（优于 force-push，保留历史）；随后 `gh run watch` 确认回绿。
- 标签误发：删除远端标签 `git push origin :refs/tags/vX.Y.Z` 并重新打；属共享状态操作，执行前先与维护者确认。
- fixtures 漂移：以 `gen_fixture.py` 为准重新生成 `demo.bin` + `expected.jsonl`，不要手改二进制。

## 7. 值班检查清单（On-call）

- [ ] `main` 最新一次 CI 是否四 job 全绿？
- [ ] 最近提交是否同时改了 `gen_fixture.py` 与两个 fixture 文件？
- [ ] canonical JSONL 是否被某语言「就地放宽」（多空格 / 键序变化）？
- [ ] 是否有 PR 引入第三方依赖或放宽 `permissions`？
- [ ] 失败日志是否已归档到 issue / PR 评论，避免重复排查？
