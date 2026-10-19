<#
.SYNOPSIS
    为 Windows 7 (x64) 交叉编译 typst.exe。

.DESCRIPTION
    使用 nightly 工具链的 Tier 3 目标 x86_64-win7-windows-msvc，并通过
    `-Z build-std` 以 Windows 7 为基线重建 std，最后静态链接 CRT。

    源代来源是一个独立的 git worktree（默认放在仓库同级的 typst-<ref> 目录），
    因此不会改动当前工作区的任何文件，也不会动 Cargo.lock。

.EXAMPLE
    .\build-win7.ps1
    以默认的 v0.15.1 标签构建。

.EXAMPLE
    .\build-win7.ps1 -Ref main -NoLto
    首次排查用：关闭 LTO 加快链接速度。
#>
[CmdletBinding()]
param(
    # typst 源码仓库路径。默认自动探测：脚本位于 <typst>/tools/win7 时取上两级，
    # 否则依次尝试当前目录、当前目录的父目录、脚本同级的 typst 目录。
    [string] $TypstRepo = '',

    # 要构建的 git 引用（标签 / 分支 / 提交）。
    [string] $Ref = 'v0.15.1',

    # 目标三元组。
    [ValidateSet('x86_64-win7-windows-msvc', 'i686-win7-windows-msvc')]
    [string] $Target = 'x86_64-win7-windows-msvc',

    # Rust 工具链通道名。
    [string] $Toolchain = 'nightly',

    # 存放指定 Ref 源码的 worktree 路径；默认为仓库同级的 typst-<ref>。
    [string] $Worktree = '',

    # CARGO_TARGET_DIR；默认为 worktree 内的 target。
    [string] $TargetDir = '',

    # 关闭 thin LTO / 降低 codegen-units，明显加快首次构建。
    [switch] $NoLto,

    # 不 strip 符号，便于分析崩溃栈。
    [switch] $KeepSymbols,

    # 构建前清空该目标的产物目录。
    [switch] $Clean,

    # 跳过构建后的导入表审计。
    [switch] $SkipAudit,

    # 保留 git 依赖（需要能访问 GitHub）。默认用本地桩替换测试专用的
    # typst-dev-assets，避免解析阶段被 GitHub 连接问题卡住。
    [switch] $KeepGitDeps
)

$ErrorActionPreference = 'Stop'

# cargo 的输出是 UTF-8，控制台默认是本地代码页，统一一下避免日志乱码。
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false) } catch { }

# 定位 typst 源码仓库（见 -TypstRepo 说明）。
if (-not $TypstRepo) {
    $candidates = @(
        (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
        (Get-Location).Path,
        (Split-Path (Get-Location).Path -Parent),
        (Join-Path (Split-Path $PSScriptRoot -Parent) 'typst')
    )
    foreach ($candidate in $candidates) {
        if (-not $candidate) { continue }
        if ((Test-Path (Join-Path $candidate 'Cargo.toml')) -and
            (Test-Path (Join-Path $candidate 'crates\typst-cli'))) {
            $TypstRepo = $candidate
            break
        }
    }
}
if (-not $TypstRepo -or -not (Test-Path (Join-Path $TypstRepo 'Cargo.toml'))) {
    throw '未找到 typst 源码仓库。请用 -TypstRepo 指定，例如：-TypstRepo D:\Repos\typst'
}
$script:RepoRoot = (Resolve-Path $TypstRepo).Path
$script:LogPath = Join-Path $PSScriptRoot 'build.log'

function Write-Step {
    param([string] $Message)
    $line = '[' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '] ' + $Message
    Write-Host $line -ForegroundColor Cyan
    Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
}

function Find-Executable {
    param([string] $Name, [string] $Hint)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if ($Hint -and (Test-Path $Hint)) { return $Hint }
    return $null
}

# ---------------------------------------------------------------------------
# 1. 工具链检查
# ---------------------------------------------------------------------------

$cargoHome = if ($env:CARGO_HOME) { $env:CARGO_HOME } else { Join-Path $env:USERPROFILE '.cargo' }
$binDir = Join-Path $cargoHome 'bin'

$cargo = Find-Executable 'cargo' (Join-Path $binDir 'cargo.exe')
$rustup = Find-Executable 'rustup' (Join-Path $binDir 'rustup.exe')
$rustc = Find-Executable 'rustc' (Join-Path $binDir 'rustc.exe')

if (-not $cargo -or -not $rustup -or -not $rustc) {
    throw "未找到 cargo/rustup/rustc。请先安装 Rust（https://rustup.rs）。"
}

Write-Step "cargo: $cargo"

$toolchains = & $rustup toolchain list 2>&1
if (-not ($toolchains -match [regex]::Escape($Toolchain))) {
    Write-Step "未安装工具链 $Toolchain，正在安装…"
    & $rustup toolchain install $Toolchain --profile minimal -c rust-src
    if ($LASTEXITCODE -ne 0) { throw "安装工具链 $Toolchain 失败。" }
}

$components = & $rustup component list --toolchain $Toolchain --installed 2>&1
if (-not ($components -match 'rust-src')) {
    Write-Step "为 $Toolchain 安装 rust-src…"
    & $rustup component add rust-src --toolchain $Toolchain
    if ($LASTEXITCODE -ne 0) { throw "安装 rust-src 失败。" }
}

$targets = & $rustup run $Toolchain cargo --version 2>&1
Write-Step "工具链: $($targets -join ' ')"

$allTargets = & $rustup run $Toolchain rustc --print target-list 2>&1
if (-not ($allTargets -contains $Target)) {
    throw "当前 rustc 不支持目标 $Target（Tier 3 目标可能已被移除）。可退回到 tools/win7/README.md 中的方案 D。"
}
Write-Step "目标 $Target 可用"

# ---------------------------------------------------------------------------
# 2. MSVC 与 Windows SDK 检查
# ---------------------------------------------------------------------------

function Find-MsvcLinker {
    $roots = @(
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem $root -Recurse -Filter 'link.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Hostx64\\x64' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

$linker = Find-MsvcLinker
if (-not $linker) {
    throw @'
未找到 MSVC 链接器 (link.exe)。
请用 Visual Studio Installer 为 Build Tools 添加工作负载：
  Microsoft.VisualStudio.Workload.VCTools（含 Windows SDK）
'@
}
Write-Step "链接器: $linker"

$sdkLibRoot = Join-Path ${env:ProgramFiles(x86)} 'Windows Kits\10\Lib'
if (-not (Test-Path $sdkLibRoot)) {
    throw "未找到 Windows SDK 库目录：$sdkLibRoot。请通过 Visual Studio Installer 安装 Windows SDK。"
}
$kernel32 = Get-ChildItem $sdkLibRoot -Recurse -Filter 'kernel32.lib' -ErrorAction SilentlyContinue |
    Select-Object -First 1
if (-not $kernel32) {
    throw "Windows SDK 中找不到 kernel32.lib，SDK 安装可能不完整。"
}
Write-Step "Windows SDK: $($kernel32.Directory.Parent.Parent.Parent.Parent.FullName)"

# ---------------------------------------------------------------------------
# 3. 准备指定 Ref 的源码（独立 worktree，不动当前工作区）
# ---------------------------------------------------------------------------

if (-not $Worktree) {
    $safeRef = ($Ref -replace '[^\w\.\-]', '_')
    $Worktree = Join-Path (Split-Path $script:RepoRoot -Parent) ('typst-' + $safeRef)
}

$git = Find-Executable 'git' $null
if (-not $git) { throw "未找到 git。" }

# 重定向 stderr 时 PowerShell 5.1 会把 git 的报错包装成 NativeCommandError，
# 这里临时放宽再自行判断退出码。
$previousErrorAction2 = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$wantCommit = (& $git -C $script:RepoRoot rev-parse "$Ref^{commit}" 2>&1)
$gitExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction2
if ($gitExit -ne 0) {
    throw "无法解析 git 引用 '$Ref'：$wantCommit"
}
$wantCommit = ($wantCommit | Out-String).Trim()
Write-Step "目标提交: $Ref -> $wantCommit"

if (-not (Test-Path $Worktree)) {
    Write-Step "创建 worktree: $Worktree"
    & $git -C $script:RepoRoot worktree add --detach $Worktree $wantCommit
    if ($LASTEXITCODE -ne 0) { throw "创建 worktree 失败。" }
}
else {
    $head = (& $git -C $Worktree rev-parse HEAD 2>&1 | Out-String).Trim()
    if ($head -ne $wantCommit) {
        # 忽略本脚本自己写入的 Cargo.toml / Cargo.lock 变更
        $dirty = & $git -C $Worktree status --porcelain 2>&1 |
            Where-Object { $_ -notmatch 'Cargo\.(toml|lock)$' }
        if ($dirty) {
            throw "worktree $Worktree 有未提交修改，拒绝切换提交。请先处理这些修改。"
        }
        Write-Step "切换 worktree 到 $wantCommit"
        & $git -C $Worktree checkout --detach $wantCommit
        if ($LASTEXITCODE -ne 0) { throw "切换提交失败。" }
    }
    else {
        Write-Step "worktree 已在目标提交上"
    }
}

# GitHub 不可达时，cargo 仍会尝试 clone 仅用于测试的 typst-dev-assets。
# 这里把该 git 依赖换成同名的本地空桩；它只出现在 dev-dependencies，
# 不会进入 typst-cli 的产物，也不影响编译结果。
if (-not $KeepGitDeps) {
    $manifest = Join-Path $Worktree 'Cargo.toml'
    $stubPath = (Join-Path $PSScriptRoot 'stubs\typst-dev-assets') -replace '\\', '/'
    $manifestText = Get-Content -Raw -Encoding UTF8 $manifest
    $marker = '[patch."https://github.com/typst/typst-dev-assets"]'
    if ($manifestText.IndexOf($marker) -lt 0) {
        $addition = "`r`n$marker`r`ntypst-dev-assets = { path = `"$stubPath`" }`r`n"
        Add-Content -Path $manifest -Value $addition -Encoding UTF8
        Write-Step "已用本地桩替换 git 依赖 typst-dev-assets（-KeepGitDeps 可关闭）"
    }
}

# ---------------------------------------------------------------------------
# 4. 构建
# ---------------------------------------------------------------------------

if (-not $TargetDir) { $TargetDir = Join-Path $Worktree 'target' }
if ($Clean) {
    $cleanPath = Join-Path $TargetDir $Target
    if (Test-Path $cleanPath) {
        Write-Step "清理 $cleanPath"
        Remove-Item $cleanPath -Recurse -Force
    }
}

$envName = 'CARGO_TARGET_' + ($Target -replace '[^A-Za-z0-9]', '_').ToUpperInvariant() + '_RUSTFLAGS'
Set-Item -Path "Env:$envName" -Value '-C target-feature=+crt-static'
Write-Step "已设置 $envName = -C target-feature=+crt-static"

$buildArgs = @(
    "+$Toolchain", 'build',
    '-p', 'typst-cli',
    '--release',
    '--target', $Target,
    '-Z', 'build-std=std,panic_unwind'
)

if ($NoLto) {
    $buildArgs += @('--config', 'profile.release.lto=false',
                    '--config', 'profile.release.codegen-units=16')
    Write-Step '已关闭 LTO（-NoLto）'
}
if ($KeepSymbols) {
    $buildArgs += @('--config', 'profile.release.package."typst-cli".strip=false')
    Write-Step '已保留符号（-KeepSymbols）'
}

Write-Step ("执行: cargo " + ($buildArgs -join ' '))
Add-Content -Path $script:LogPath -Value ('-' * 70) -Encoding UTF8

$stopwatch = [Diagnostics.Stopwatch]::StartNew()
$previousTargetDir = $env:CARGO_TARGET_DIR
$env:CARGO_TARGET_DIR = $TargetDir

# 必须在目标 worktree 内执行，否则 cargo 会构建当前工作区（可能是另一个提交）。
$previousLocation = (Get-Location).Path
Set-Location $Worktree

# cargo 会把进度与警告写到 stderr；在 ErrorActionPreference=Stop 下，
# PowerShell 5.1 会把它包装成 NativeCommandError 并中断脚本，因此临时放宽。
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'

# 用 git CLI 抓取 git 依赖：libgit2 在部分代理/网络环境下会失败。
$env:CARGO_NET_GIT_FETCH_WITH_CLI = 'true'

try {
    & $cargo @buildArgs 2>&1 | ForEach-Object {
        $line = [string]$_
        Write-Host $line
        Add-Content -Path $script:LogPath -Value $line -Encoding UTF8
    }
    $exitCode = $LASTEXITCODE
}
finally {
    $stopwatch.Stop()
    Set-Location $previousLocation
    $ErrorActionPreference = $previousErrorAction
    if ($null -eq $previousTargetDir) {
        Remove-Item Env:\CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:CARGO_TARGET_DIR = $previousTargetDir
    }
}

if ($exitCode -ne 0) {
    Write-Host ''
    Write-Host '构建失败。日志末尾：' -ForegroundColor Red
    Get-Content $script:LogPath -Tail 40 -Encoding UTF8 | Write-Host
    throw "cargo 构建失败，退出码 $exitCode。完整日志：$script:LogPath"
}

# ---------------------------------------------------------------------------
# 5. 产物信息
# ---------------------------------------------------------------------------

$exe = Join-Path $TargetDir (Join-Path $Target 'release\typst.exe')
if (-not (Test-Path $exe)) { throw "构建成功但找不到产物：$exe" }

$file = Get-Item $exe
$hash = (Get-FileHash $exe -Algorithm SHA256).Hash
$elapsed = '{0:hh\:mm\:ss}' -f $stopwatch.Elapsed

Write-Step "构建完成，用时 $elapsed"
Write-Host ''
Write-Host '产物信息' -ForegroundColor Green
Write-Host ("  路径:   {0}" -f $file.FullName)
Write-Host ("  大小:   {0:N1} MB" -f ($file.Length / 1MB))
Write-Host ("  SHA256: {0}" -f $hash)
Write-Host ("  提交:   {0} ({1})" -f $Ref, $wantCommit)

if (-not $SkipAudit) {
    $audit = Join-Path $PSScriptRoot 'audit-imports.ps1'
    if (Test-Path $audit) {
        Write-Step '运行导入表审计…'
        & $audit -Exe $exe
        $auditExit = $LASTEXITCODE
        if ($auditExit -ne 0) {
            Write-Host ''
            Write-Host '审计发现 Win8/Win10 专有 API 导入，请用 patch-thunks.ps1 处理后再上 Win7 测试。' -ForegroundColor Yellow
        }
    }
}
