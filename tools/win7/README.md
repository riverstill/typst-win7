# 在 Windows 7 上运行 Typst 0.15.x

Typst 从 0.12.0 起无法在 Windows 7 上启动，报错形如：

```
无法定位程序输入点 SetThreadDescription 于动态链接库 KERNEL32.dll
```

原因不在 Typst 代码，而在工具链基线：Rust 自 **1.78**（2024-05-02）起把所有
`*-pc-windows-*` 目标的最低系统要求提升到 **Windows 10**，std 会直接引用
`SetThreadDescription`、`WaitOnAddress` 等 Win8/Win10 才有的 API。Typst 0.12.0 的
官方产物用 Rust 1.81 构建，0.15.1 用 1.95，因此必然无法在 Win7 加载。

本目录提供一条实验性路线：使用 Rust 官方保留的 Tier 3 目标
`x86_64-win7-windows-msvc`（以 Win7 为基线重建 std），静态链接 CRT，再用
YY-Thunks 补齐第三方 crate 的残余导入。

> 这条路未经上游测试，不保证成功；失败时可参考文末的退路。

## 环境要求

+ 构建机：Windows 10/11 x64
+ Visual Studio Build Tools，工作负载 `Microsoft.VisualStudio.Workload.VCTools`
  （含 MSVC 编译器与 Windows SDK）
+ Rust nightly + `rust-src` 组件（脚本会自动补装）
+ 需要能访问 crates.io（构建 v0.15.1 不需要 GitHub 上的 git 依赖）

安装 VS 组件（会弹 UAC）：

```powershell
& "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" modify `
    --installPath "<VS 安装目录>\BuildTools" `
    --add Microsoft.VisualStudio.Workload.VCTools --includeRecommended --quiet --norestart
```

## 快速开始

```powershell
cd tools\win7
.\build-win7.ps1
```

默认构建 **v0.15.1** 标签，产物位于：

```
<仓库同级>\typst-v0.15.1\target\x86_64-win7-windows-msvc\release\typst.exe
```

源码放在独立的 git worktree 中，**不会改动当前工作区，也不会改 `Cargo.lock`**。

### 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `-Ref` | `v0.15.1` | 标签 / 分支 / 提交 |
| `-Target` | `x86_64-win7-windows-msvc` | 也可用 `i686-win7-windows-msvc` |
| `-Toolchain` | `nightly` | 可固定为 `nightly-2026-10-18` 之类 |
| `-Worktree` | 仓库同级 `typst-<ref>` | 源码 worktree 位置 |
| `-TargetDir` | worktree 内 `target` | 产物目录（独立可避免与普通构建互相覆盖） |
| `-NoLto` | 关 | 关闭 thin LTO、提高 codegen-units，首次排查更快 |
| `-KeepSymbols` | 关 | 不 strip，便于看崩溃栈 |
| `-Clean` | 关 | 清空该目标的旧产物 |
| `-SkipAudit` | 关 | 跳过构建后的导入表审计 |
| `-KeepGitDeps` | 关 | 保留 git 依赖（需要能访问 GitHub） |

首次完整构建（含重建 std + thin LTO）大约 30–60 分钟，磁盘占用 10 GB 量级；
使用 `-NoLto` 时实测约 **11 分钟**。

### 关于 git 依赖

`typst-dev-assets` 是各 crate 的 dev-dependency（只用于集成测试），但 cargo 解析整个
workspace 时仍会 clone 它。若构建机访问不了 GitHub，脚本默认会用
`tools/win7/stubs/typst-dev-assets` 这个空包通过 `[patch]` 顶替它 —— 它不会进入
`typst-cli` 的产物，因此不影响二进制内容。若网络正常、希望用真实依赖，加
`-KeepGitDeps`。

## 实测结果（2026-10-19）

| 项 | 值 |
| --- | --- |
| 源码 | `v0.15.1`，提交 `9dfd3a08500b7896045f907433cf7b4b02434fad` |
| 工具链 | `rustc 1.101.0-nightly (b6eeb93c9 2026-10-18)` + `rust-src` |
| MSVC | VS Build Tools 18.9 / MSVC 14.51.36231 / Windows SDK 10.0.26100 |
| 目标 | `x86_64-win7-windows-msvc`（`-Z build-std=std,panic_unwind`，`+crt-static`） |
| 产物（`-NoLto`） | `target\x86_64-win7-windows-msvc\release\typst.exe`，52.3 MB |
| 产物（默认 LTO） | `target-lto\x86_64-win7-windows-msvc\release\typst.exe`，49.9 MB |
| 版本输出 | `typst 0.15.1 (9dfd3a08)` |
| 导入表 | 8 个 DLL：kernel32 / ws2_32 / shell32 / ole32 / secur32 / crypt32 / advapi32 / ntdll |
| 风险导入 | **0**（无 `api-ms-win-*`、无 `SetThreadDescription`/`WaitOnAddress`） |
| PE 基线 | `subsystem version 6.00` / `operating system version 6.00`（低于 Win7 的 6.1） |
| 冒烟测试 | 本机（Win10）编译含中文与公式的文档成功，`typst fonts` 枚举到 283 条字体记录 |
| Win7 实机 | **通过**：Windows 7 上可直接运行使用，无入口点报错 |

LTO 产物的 SHA256：`2B17992E5CF74CE46E1FD02780545A0010E22E9B6A9D7CBB058F1659BBB26CAA`。

## 部署到 Windows 7

1. 把 `typst.exe` 拷到 Win7 机器即可，**单文件、无需安装、无需 VC++ Redist**。
2. 确认系统是 **SP1 x64**；32 位系统需改用 `-Target i686-win7-windows-msvc`。
3. 首次在 Win7 上跑 `typst --version`，能输出版本号即说明入口点问题已解决。
4. 若要用 `@preview` 包，先补 TLS 1.2（KB3140245 + 注册表启用），否则下载会失败。

## 导入表审计

```powershell
.\audit-imports.ps1 -Exe <typst.exe 路径>
```

输出 `imports-report.txt`，会标记：

+ 所有 `api-ms-win-*` API-Set 依赖（Win7 默认不提供）
+ Win8/Win8.1/Win10 才引入的函数（`SetThreadDescription`、`WaitOnAddress`、
  `GetDpiForWindow`、`PathCchCanonicalizeEx` 等）

退出码 `0` 表示未发现风险，`1` 表示存在风险导入。

## 补齐缺失 API

```powershell
cargo install thunk-cli
.\patch-thunks.ps1 -Exe <typst.exe 路径>
```

脚本会备份 `typst.orig.exe`，用 thunk-cli 重写导入表指向 YY-Thunks 桩，然后自动复核。
若复核仍有风险项，说明 thunk-cli 未覆盖对应 API，需要走文末的备选方案。

## Windows 7 侧前置条件

+ Windows 7 **SP1** x64
+ 建议安装 [KB2533623](https://www.microsoft.com/en-us/download/details.aspx?id=27222)
  （`SetDefaultDllDirectories` / `AddDllDirectory`，部分依赖会用到）
+ 若要在 Win7 上 `typst init @preview/...` 下载包，需要 TLS 1.2 支持：
  KB3140245 + 注册表启用 `TLS 1.2` 的 `Schannel` 协议
+ 静态 CRT 产物**不需要**安装 VC++ Redistributable

## 验收清单（Win7 SP1 x64 实机）

| 项 | 命令 | 期望 |
| --- | --- | --- |
| 启动 | `typst --version` | 输出 `typst 0.15.1`，无入口点弹窗 |
| 基础编译 | `typst compile hello.typ` | 生成 PDF，退出码 0 |
| 中文排版 | 含中日韩文本的文档 | 正常排版（默认已内嵌字体） |
| 字体枚举 | `typst fonts` | 能列出系统字体 |
| 其它导出 | `typst compile --format png/svg/html` | 均成功 |
| 热重载 | `typst watch hello.typ` | 修改文件后自动重编译 |
| 包管理 | `typst init @preview/...` | 能下载并编译（依赖 TLS 1.2） |
| 稳定性 | 连续编译 20 次 + 大文档 | 无崩溃、无异常内存增长 |

## 失败时的退路

1. **常规 msvc 构建 + thunk 补丁**：不重建 std，直接用默认目标编译，再跑
   `patch-thunks.ps1` 修补导入表。省时间，但依赖 thunk-cli 覆盖足够多的 API。
2. **链接期注入 YY-Thunks**：在 `RUSTFLAGS` 中加入
   `/LIBPATH:<YY-Thunks>\lib\6.1.7600.0\x64` 与 `YY_Thunks_for_Win7.lib`，
   并配合 VC-LTL5 替换 CRT。
3. **降级到 v0.11.1**：最后一个用 Rust 1.77 构建的官方版本，可在 Win7 直接运行，
   但没有 0.12+ 的新特性。
4. **远程/在线方案**：在 Win10+ 机器或 CI 上编译，Win7 端只用 PDF 阅读器。

## 已知限制

+ Tier 3 目标无官方测试，不同 nightly 可能行为不一致；建议固定 `-Toolchain`。
+ VS 2022/2026 的静态 CRT 若引入 Win8+ 依赖，审计会报出来，此时改用 VC-LTL5。
+ 该产物不是上游发布物，不要用于生产分发。
