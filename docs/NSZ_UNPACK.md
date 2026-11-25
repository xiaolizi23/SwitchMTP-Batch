# NSZ 解包（NCZ → NCA）与校验

本目录里的「深度检查」现在能解开 NSZ：内置的 `tools/nszunpack` 会把包里的
NCZ 还原成真正的 NCA，写回一个可直接安装的 NSP，然后逐个 NCA 验签名、对哈希。
这份文档记录格式结论、实现方式和真文件测试结果，方便以后复查。

## 1. 为什么以前不行，现在怎么做的

NSZ 不是「另一种加密」，它就是标准 PFS0 容器，只是把 `xxx.nca` 换成了
`xxx.ncz`：前 `0x4000` 字节仍是加密的 NCA 头，后面是 zstd 压缩过的正文。
要装进主机，必须把正文解压出来，再按 NCZ 里记录的 section 重新做 AES-CTR
加密——密钥和初始向量都来自 NCZ 头，而不是主机侧的 titlekey。

旧的实现只看容器表，遇到 `.ncz` 就报「无法验证」，因为签名/哈希都在解压后的
NCA 里。现在由 `nszunpack` 完成解压 + 重加密，再交给 hactool 验。

## 2. NCZ 头结构（按真实文件逐字节确认）

```
0x0000 .. 0x4000   NCA 头（原样保留，仍是 XTS 加密的数据）
0x4000             "NCZSECTN" + u64 sectionCount
随后 sectionCount 条记录，每条 64 字节：
    u64 offset         NCA 内绝对偏移
    u64 size           该 section 的字节数
    u8  cryptType      1 = 明文，3 = AES-CTR
    u8  pad[7]
    u8  pad2[8]
    u8  key[16]
    u8  counter[16]
可选块压缩头 "NCZBLOCK"：
    u8  version        （实测 2）
    u8  type           （实测 1 = zstd）
    u8  reserved
    u8  blockExponent  （实测 0x14 = 1 MiB 一块）
    u32 blockCount
    u64 decompressedSize  解压后的正文总字节数
    u32 compressedSize[blockCount]
之后才是压缩数据。
```

两个容易踩的坑：

* 官方 `docs/formats.md` 里写的「每条 section 前有 magic、cryptType 是 int64」
  和真实文件不符。按文档写会整体错位。实际是上面这份 64 字节布局。
* 更新包（以及部分本体）会带 `NCZBLOCK`，正文按 1 MiB 分块、**每块一条独立的
  zstd frame**，且压缩后不划算的块会被**原样存下来**（此时
  `compressedSize == blockSize`，块内没有 zstd 帧头）。解压时必须逐块判断，
  不能把整段当成一条流。

## 3. 重加密规则（唯一正确的那条）

解压出的明文从 NCA 的 `0x4000` 起连续铺满整个躯干。对 `cryptType == 3` 的
section：

```
IV = counter[0..7] || big-endian(offset >> 4)
```

`cryptType == 1` 的 section 保持明文。`offset` 是该 section 在 NCA 内的起始偏移。

这条规则是拿真实文件反推出来的：按它重建的 NCA，SHA-256 与包内 CNMT 声明的
哈希逐字符相同。换成「counter 原样」「LE 偏移」「整体加密」三种假设，哈希都对
不上。

## 4. 校验的两条证据链

1. **CNMT 哈希（最强）**：`nszunpack unpack` 在写完每个 NCA 后计算 SHA-256，
   和包内 `.cnmt.xml` 的 `<Content><Id>/<Hash>` 对照，输出
   `NSZ_HASH: <nca> sha256=… expected=… match=yes|no|unknown`。
   一致 = 解包结果与发行方签过名的清单逐字节相同。
2. **hactool 验签**：把重建出的 NSP 交给内置 hactool，逐 NCA 验 RSA 签名；
   哈希在这里再验一遍（对密钥代与票据不一致的包会自动按 NCA 头的密钥代重试）。

没有 `.cnmt.xml` 的包（部分第三方重打包）只能用第 2 条，这时结论会比有清单的
弱一档：签名通过 + 引擎哈希通过，但仍注明「包内没有 CNMT XML 可对照」。

## 5. 命令行用法

```bash
# 只看结构（不写盘）
tools/nszunpack/nszunpack info "/path/to/game.nsz"

# 解包成 NSP，并逐个 NCA 自检
tools/nszunpack/nszunpack unpack "/path/to/game.nsz" /tmp/game.nsp
```

构建：`scripts/build-nszunpack.sh`（依赖 vendored mbedtls 与 Homebrew 的静态
`libzstd`，产物为 arm64）。`scripts/build-batch-app.sh` 会把它拷进
`Contents/Resources/bin/`。

应用内：详情面板新增「解包为 NSP…」按钮，选好保存位置即可；深度检查会对
NSZ 自动解包到临时目录、校验完再删除。

## 6. 真文件测试矩阵（2026-11-25，本机 14 个 NSZ）

| 包 | 结构 | 解包 | CNMT 哈希 |
|---|---|---|---|
| Sample Game 本体 | 3 sections | 408 MiB | 4/4 一致 |
| Sample Game 更新 | 417 sections + NCZBLOCK | 289 MiB | 4/4 一致 |
| 某本体 v1.1.0（升级档） | 4 sections | 38 MiB | 4/4 一致 |
| 某本体 本体 | 3 sections | 6.0 GiB | 无 cnmt.xml |
| 某个更新包 本体 | 3 sections | 5.4 GiB | 无 cnmt.xml |
| 某个更新包 v1.1.0 | 692 sections + NCZBLOCK | 190 MiB | 4/4 一致 |
| 某更新包 本体 | 3 sections | 18 MiB | 无 cnmt.xml |
| 某更新包 v1.0.7 | 4 sections + NCZBLOCK | 83 MiB | 4/4 一致 |
| 某更新包 本体 | 3 sections | 180 MiB | 无 cnmt.xml |
| 某更新包 v1.1.6 | 131 sections + NCZBLOCK | 92 MiB | 4/4 一致 |
| Another Game 本体 | 3 sections | 2.7 GiB | 4/4 一致 |
| Another Game v1.1.0 | 3 sections | 118 MiB | 无 cnmt.xml |
| Sample Game B 本体 | 3 sections | 2.1 GiB | 无 cnmt.xml |
| Sample Game B v1.2.2 | 5 sections + NCZBLOCK | 86 MiB | 4/4 一致 |

全部 14 个都成功解包（rc=0），无 zstd 错误、无 section 越界。

### 6.1 应用内深度检查的最终结论（14/14 跑完）

| 结果 | 数量 | 包 |
|---|---|---|
| 绿（签名 + 哈希通过） | 13 | 上述 14 个里除某个更新包本体以外的全部 |
| 无法确认 | 1 | 某个更新包本体（5.4 GiB，包内无 CNMT 清单；引擎在 RomFS 层级表上报不一致） |

另外三个曾经卡在「无法验证」的升级档（某本体 v1.1.0、某个更新包 v1.1.0、某更新包 v1.1.6、
Sample Game B v1.2.2）在修掉两处会导致引擎中途 `exit` 的地方后，全部变成绿。

反例测试：把 某更新包 本体解包出的 NSP 中间 16 字节翻转，深度检查从绿变成
「内容无法确认」（不会误判成绿，也不会冤枉成红）。

## 7. 已知限制

* **通用二进制**：`nszunpack` 同时含 arm64 与 x86_64；Intel 上解包结果与
  arm64 逐字节相同，但内置 `hactool` 的 x86 构建会误报签名 FAIL，所以 Intel
  进程只输出“与 CNMT 清单一致 / 不一致”，不判绿黄。
* **XCZ 还没做**。XCZ 是卡带镜像（HFS0 分区 + sparse 压缩），和 NSZ 的
  NCZ 不是一套东西，目前仍按「只验容器头」处理。
* 解包需要和 NSZ 体积相当的临时磁盘空间（解压后通常更大 10–30%）；
  深度检查结束后自动删除临时 NSP。
* 若 `prod.keys` 缺少包所需的密钥代，签名仍可验，内容哈希会缺结论，
  此时应用显示「无法深度验证」，不会假装通过。
* **BKTR 补丁分区**（升级档常见）的内容分区遍历引擎不支持，以前会直接
  `exit` 把整包其余 NCA 的结论一起丢掉；现在跳过该分区、保留头部签名结论。
* **超大 RomFS（>5 GiB 的单 NCA）**的 IVFC 层级表引擎偶发不一致；包内有
  CNMT 清单时以清单哈希为准，没有清单时显示「内容无法确认」而不是绿。
