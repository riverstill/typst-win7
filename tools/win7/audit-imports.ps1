<#
.SYNOPSIS
    审计 PE 导入表，找出 Windows 7 上不存在的 DLL / API。

.DESCRIPTION
    使用 dumpbin /imports（或 link /dump /imports）解析导入表，标记：
      * 所有 api-ms-win-* API-Set 依赖（Win7 上大多不存在）
      * Win8 / Win8.1 / Win10 才引入的函数（黑名单）

    报告写入 tools/win7/imports-report.txt。

.EXAMPLE
    .\audit-imports.ps1 -Exe ..\..\target\x86_64-win7-windows-msvc\release\typst.exe
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [string] $Exe,

    [string] $Report = (Join-Path $PSScriptRoot 'imports-report.txt')
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) { throw "找不到文件：$Exe" }
$Exe = (Resolve-Path $Exe).Path

# 仅在 Win8 及以上（含 Win10/11）出现的函数
$riskyFunctions = @{
    'SetThreadDescription'            = 'Win10 1607'
    'GetThreadDescription'            = 'Win10 1607'
    'GetSystemTimePreciseAsFileTime'  = 'Win8'
    'WaitOnAddress'                   = 'Win8'
    'WakeByAddressSingle'             = 'Win8'
    'WakeByAddressAll'                = 'Win8'
    'GetDpiForWindow'                 = 'Win10 1607'
    'GetDpiForMonitor'                = 'Win8.1'
    'GetSystemMetricsForDpi'          = 'Win10 1607'
    'AdjustWindowRectExForDpi'        = 'Win10 1607'
    'SetProcessDpiAwarenessContext'   = 'Win10 1703'
    'PathCchCanonicalizeEx'           = 'Win8'
    'PathCchCombineEx'                = 'Win8'
    'PathCchAppendEx'                 = 'Win8'
    'PathAllocCanonicalize'           = 'Win8'
    'CreateFile2'                     = 'Win8'
    'CopyFile2'                       = 'Win8'
    'GetOverlappedResultEx'           = 'Win8'
    'GetPackageFamilyName'            = 'Win8'
    'GetCurrentPackageFullName'       = 'Win8'
    'RoInitialize'                    = 'Win8'
    'DiscardVirtualMemory'            = 'Win8.1'
    'SetThreadStackGuarantee2'        = 'Win11'
    'GetMachineTypeAttributes'        = 'Win11'
    'SetDefaultDllDirectories'        = 'Win7 KB2533623'
    'AddDllDirectory'                 = 'Win7 KB2533623'
    'RemoveDllDirectory'              = 'Win7 KB2533623'
}

function Find-Dumpbin {
    $roots = @(
        (Join-Path $env:ProgramFiles 'Microsoft Visual Studio'),
        (Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio')
    )
    foreach ($root in $roots) {
        if (-not (Test-Path $root)) { continue }
        $found = Get-ChildItem $root -Recurse -Filter 'dumpbin.exe' -ErrorAction SilentlyContinue |
            Where-Object { $_.FullName -match 'Hostx64\\x64' } |
            Sort-Object FullName -Descending |
            Select-Object -First 1
        if ($found) { return $found.FullName }
    }
    return $null
}

function Find-Linker {
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

$dumpbin = Find-Dumpbin
# dumpbin 会往 stderr 写非致命提示；Stop 模式下 PowerShell 5.1 会把它当作
# NativeCommandError 中断脚本，这里临时放宽。
$ErrorActionPreference = 'Continue'
if ($dumpbin) {
    $raw = & $dumpbin /nologo /imports $Exe 2>&1
    $toolExit = $LASTEXITCODE
}
else {
    $linker = Find-Linker
    if (-not $linker) {
        throw '既找不到 dumpbin.exe 也找不到 link.exe，无法解析导入表。请安装 VS C++ 生成工具。'
    }
    $raw = & $linker /dump /nologo /imports $Exe 2>&1
    $toolExit = $LASTEXITCODE
}
$ErrorActionPreference = 'Stop'

if ($toolExit -ne 0) { throw "解析导入表失败：`n$($raw -join [Environment]::NewLine)" }

# ---------------------------------------------------------------------------
# 解析
# ---------------------------------------------------------------------------

$imports = [ordered]@{}
$currentDll = $null

foreach ($line in $raw) {
    if ($line -match '^\s{2,}(\S+\.(?:dll|DLL|drv|DRV))\s*$') {
        $currentDll = $Matches[1]
        if (-not $imports.Contains($currentDll)) {
            $imports[$currentDll] = New-Object System.Collections.Generic.List[string]
        }
        continue
    }
    if ($currentDll -and $line -match '^\s+[0-9A-Fa-f]+\s+([A-Za-z_][A-Za-z0-9_@?$]*)\s*$') {
        $imports[$currentDll].Add($Matches[1])
    }
}

if ($imports.Count -eq 0) { throw '未能从 dumpbin 输出中解析出任何导入项，请检查输出格式。' }

# ---------------------------------------------------------------------------
# 判定
# ---------------------------------------------------------------------------

$findings = New-Object System.Collections.Generic.List[string]
$riskyDlls = New-Object System.Collections.Generic.List[string]
$riskyApis = New-Object System.Collections.Generic.List[string]

foreach ($dll in $imports.Keys) {
    if ($dll -match '^api-ms-win-') {
        $riskyDlls.Add($dll)
        $findings.Add(("[高风险] API-Set 依赖 {0}：Windows 7 默认不提供该 API-Set" -f $dll))
    }
}

foreach ($dll in $imports.Keys) {
    foreach ($fn in $imports[$dll]) {
        if ($riskyFunctions.ContainsKey($fn)) {
            $win = $riskyFunctions[$fn]
            $entry = "{0}!{1}" -f $dll, $fn
            $riskyApis.Add($entry)
            $findings.Add(("[高风险] {0} 需要 {1}" -f $entry, $win))
        }
    }
}

# ---------------------------------------------------------------------------
# 输出
# ---------------------------------------------------------------------------

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('Typst for Windows 7 - 导入表审计报告')
[void]$sb.AppendLine('生成时间: ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
[void]$sb.AppendLine('文件:     ' + $Exe)
$fileInfo = Get-Item $Exe
[void]$sb.AppendLine(('大小:     {0:N1} MB' -f ($fileInfo.Length / 1MB)))
[void]$sb.AppendLine(('SHA256:   {0}' -f (Get-FileHash $Exe -Algorithm SHA256).Hash))
[void]$sb.AppendLine()
[void]$sb.AppendLine('== 导入的 DLL ==')
foreach ($dll in $imports.Keys) {
    [void]$sb.AppendLine(('  {0} ({1} 个函数)' -f $dll, $imports[$dll].Count))
}
[void]$sb.AppendLine()
if ($findings.Count -eq 0) {
    [void]$sb.AppendLine('== 结论 ==')
    [void]$sb.AppendLine('  未发现已知的 Win8/Win10 专有依赖，可直接在 Win7 SP1 上测试。')
}
else {
    [void]$sb.AppendLine('== 结论 ==')
    [void]$sb.AppendLine(('  发现 {0} 处风险导入，Windows 7 上可能报“找不到入口点”。' -f $findings.Count))
    [void]$sb.AppendLine()
    foreach ($f in $findings) { [void]$sb.AppendLine('  ' + $f) }
    [void]$sb.AppendLine()
    [void]$sb.AppendLine('  处理方式：tools/win7/patch-thunks.ps1 -Exe <文件>')
}
[void]$sb.AppendLine()
[void]$sb.AppendLine('== 完整导入表 ==')
foreach ($dll in $imports.Keys) {
    [void]$sb.AppendLine('  ' + $dll)
    foreach ($fn in $imports[$dll]) { [void]$sb.AppendLine('    ' + $fn) }
}

Set-Content -Path $Report -Value $sb.ToString() -Encoding UTF8

Write-Host ''
Write-Host ('审计文件: {0}' -f $Report) -ForegroundColor Cyan
Write-Host ('DLL 数量: {0}，风险项: {1}' -f $imports.Count, $findings.Count)
if ($findings.Count -gt 0) {
    Write-Host ''
    foreach ($f in $findings) { Write-Host $f -ForegroundColor Yellow }
    exit 1
}
Write-Host '未发现 Win8/Win10 专有导入。' -ForegroundColor Green
exit 0
