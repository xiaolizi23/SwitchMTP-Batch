# Patched hactool (third_party/hactool)

上游：[hactool](https://github.com/SciresM/hactool)（SciresM），随包内 `LICENSE` 一同分发。
这里放的是**我们打过补丁的源码**，用来重新生成 `tools/hactool/hactool`（app 内的
`Contents/Resources/bin/hactool`）。重新编译：

```
./scripts/build-hactool.sh          # 或 --clean 全量重来
```

`mbedtls/` 只保留了 `include/` 与 `library/`（去掉 tests/ programs/ doxygen/ 等），
因为 Makefile 只需要这两处。

## 我们的改动

| 文件 | 改动 | 为什么 |
|---|---|---|
| `settings.h`, `nca.h`, `nca.c` | NCA 分区上下文增加 `base_offset`，CTR 分支 seek 时补上 | 某个 15.5 GB 的重打包 NSP 里 NCA 不在文件 0 偏移，原版把分区偏移当成绝对偏移，导致解密错位、哈希全 FAIL |
| `nsp.c`（新增） | `-t nsp`：遍历 PFS0 → 逐个 NCA 原地验签名/哈希，并从包内 `.tik` 自动登记标题密钥 | 原版 `-t pfs0` 只会列文件，深检永远拿不到结论（这就是“44 项全部无法验证”的根因） |
| `nsp.c` | 打印 `NSP_NCA_BEGIN:` / `NSP_NCA_END:` / `NSP_TICKET_PERSONALIZED` / `NSP_KEYSTATE` / `NSP_NCA_RETRY` / `NSP_RESULT` 标记 | Swift 侧靠这些标记做逐 NCA 结论，不再“某行说 fail 就整包红” |
| `nsp.c` | ticket 密钥代回退：哈希 FAIL 且 NCA 头 `crypto_type` ≠ ticket 代次时，按 NCA 头的代次重新解密钥再验一次；**不设 NCA 尺寸上限**（重试只在内存内重解密校验，不写大文件） | 重打包工具常把内容用某一代 titlekek 包出来却在 ticket 里写另一代（某 DLC：ticket 13、内容实际 12）。早先的 8GB 上限会把 某个 11 GB 的本体跳过重试、误判红；去掉后大包也能换代次纠正 |
| `xci.c` | 新增 `xci_walk_partition_ncas()`：遍历 secure 分区 HFS0 条目，逐个构造 `nca_ctx_t`（带完整 `tool_ctx`、`base_offset`、`file_size`）走 `nca_process`，并打印 `NSP_NCA_BEGIN/END` 标记 | 原版 `-t xci` 只验卡片头，深检拿不到 NCA 级结论；XCI 内 NCA 是 Standard crypto、不需要 titlekey，与 NSP 复用同一条 NCA 验签/哈希通路后，无 ticket XCI 也能逐 NCA 出签名/哈希结论 |
| `extkeys.c`, `extkeys.h` | 新增 `settings_replace_decrypted_titlekey()` | 上面那次重试需要覆盖已登记的密钥（原 `settings_add_decrypted_titlekey` 遇到已存在会直接返回） |
| `main.c`, `Makefile` | 注册新 `-t nsp` 处理器 | 同上 |

## 谁在用这个二进制

- 标准构建的 postBuild 脚本把 `tools/hactool/hactool` 拷进 app 的 `Resources/bin/`。
- `scripts/test-inspector.sh` 用它跑回归。
- app 的「深度检查」通过 `DeepVerifier` 调它（`--verify`）。

改这里的源码后务必跑一次 `./scripts/build-hactool.sh` 并 `./scripts/test-inspector.sh`，
否则 app 里躺的还是旧二进制。
