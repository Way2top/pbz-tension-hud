# 构建覆盖层 exe
# 用法: powershell -ExecutionPolicy Bypass -File src/build.ps1

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$csc = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if (-not (Test-Path $csc)) { throw "找不到 .NET Framework 4.x 编译器: $csc" }

$out = Join-Path $here "PBZTensionHUD.exe"
& $csc /nologo /target:winexe /out:$out `
    /reference:System.dll /reference:System.Drawing.dll /reference:System.Windows.Forms.dll `
    (Join-Path $here "TensionOverlay.cs")

if ($LASTEXITCODE -ne 0) { throw "编译失败 (exit $LASTEXITCODE)" }
Write-Host "已生成: $out"
Write-Host "部署: 复制到 <游戏根目录>\platform\steam\ue4ss\Mods\PBZTensionHUD\bin\PBZTensionHUD.exe"
