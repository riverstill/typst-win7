<#
.SYNOPSIS
    用 thunk-cli / YY-Thunks 为 typst.exe 打补丁，补齐 Windows 7 缺失的 API。

.DESCRIPTION
    先用 audit-imports.ps1 确认是否存在风险导入，再用 thunk-cli 重写导入表，
    把 Win8/Win10 专有函数重定向到 YY-Thunks 提供的桩实现。

    原始文件会备份为 <name>.orig.exe，可反复对备份重打补丁。

.NOTES
    thunk-cli 安装：cargo install thunk-cli
    项目地址：https://github.com/felixmaker/thunk
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Exe,

    # thunk-cli 可执行文件路径；默认从 PATH 查找。
    [string] $ThunkCli = 'thunk-cli',

    # 即使审计未发现风险也强制打补丁。
    [switch] $Force
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) { throw "找不到文件：$Exe" }
$Exe = (Resolve-Path $Exe).Path

$auditScript = Join-Path $PSScriptRoot 'audit-imports.ps1'

# ---------------------------------------------------------------------------
# 1. 前置审计
# ---------------------------------------------------------------------------

if (-not $Force) {
    Write-Host '先审计当前导入表…' -ForegroundColor Cyan
    & $auditScript -Exe $Exe
    if ($LASTEXITCODE -eq 0) {
        Write-Host '未发现风险导入，无需打补丁。' -ForegroundColor Green
        return
    }
}

# ---------------------------------------------------------------------------
# 2. 定位 thunk-cli
# ---------------------------------------------------------------------------

$resolved = $null
if (Test-Path $ThunkCli) {
    $resolved = (Resolve-Path $ThunkCli).Path
}
else {
    $cmd = Get-Command $ThunkCli -ErrorAction SilentlyContinue
    if ($cmd) { $resolved = $cmd.Source }
}
if (-not $resolved) {
    throw @'
未找到 thunk-cli。安装方式：
    cargo install thunk-cli
如果 crates.io 不可用，也可以手动下载 YY-Thunks 并在链接期加入：
    -C link-arg=/LIBPATH:<YY-Thunks>\lib\6.1.7600.0\x64
    -C link-arg=YY_Thunks_for_Win7.lib
'@
}
Write-Host ('thunk-cli: ' + $resolved) -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 3. 备份并打补丁
# ---------------------------------------------------------------------------

$item = Get-Item $Exe
$dir = $item.DirectoryName
$name = $item.BaseName
$ext = $item.Extension
$backup = Join-Path $dir ($name + '.orig' + $ext)

if (Test-Path $backup) {
    Write-Host ('使用已有备份: ' + $backup) -ForegroundColor DarkGray
    Copy-Item $backup $Exe -Force
}
else {
    Copy-Item $Exe $backup -Force
    Write-Host ('已备份原文件: ' + $backup) -ForegroundColor DarkGray
}

Write-Host '正在打补丁…' -ForegroundColor Cyan
$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
& $resolved $Exe
$thunkExit = $LASTEXITCODE
$ErrorActionPreference = $previousErrorAction
if ($thunkExit -ne 0) { throw "thunk-cli 执行失败，退出码 $thunkExit。" }

# ---------------------------------------------------------------------------
# 4. 复核
# ---------------------------------------------------------------------------

Write-Host ''
Write-Host '复核导入表…' -ForegroundColor Cyan
& $auditScript -Exe $Exe
if ($LASTEXITCODE -ne 0) {
    Write-Host ''
    Write-Host '仍有风险导入：thunk-cli 未覆盖这些 API，需要改走 README 中的备选方案。' -ForegroundColor Yellow
    exit 1
}
Write-Host ''
Write-Host '补丁完成，可以拷到 Windows 7 SP1 上测试。' -ForegroundColor Green
