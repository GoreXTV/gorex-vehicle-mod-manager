$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if ([Environment]::Is64BitProcess) {
    & "$env:WINDIR\SysWOW64\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -File $PSCommandPath
    exit $LASTEXITCODE
}
$taskRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$taskDll = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..\..\lua5.1.dll')).Path
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class VmmLuaCheck {
 [DllImport(@"$taskDll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr luaL_newstate();
 [DllImport(@"$taskDll", CallingConvention=CallingConvention.Cdecl)] public static extern void luaL_openlibs(IntPtr state);
 [DllImport(@"$taskDll", CallingConvention=CallingConvention.Cdecl)] public static extern int luaL_loadbuffer(IntPtr state, byte[] source, UIntPtr size, string name);
 [DllImport(@"$taskDll", CallingConvention=CallingConvention.Cdecl)] public static extern int lua_pcall(IntPtr state, int nargs, int nresults, int errfunc);
 [DllImport(@"$taskDll", CallingConvention=CallingConvention.Cdecl)] public static extern IntPtr lua_tolstring(IntPtr state, int index, IntPtr len);
 [DllImport(@"$taskDll", CallingConvention=CallingConvention.Cdecl)] public static extern void lua_close(IntPtr state);
}
"@
function Invoke-LuaCheck($taskFile, [bool]$taskRun) {
    $taskState = [VmmLuaCheck]::luaL_newstate()
    try {
        if ($taskRun) { [VmmLuaCheck]::luaL_openlibs($taskState) }
        $taskBytes = [IO.File]::ReadAllBytes($taskFile)
        $taskStatus = [VmmLuaCheck]::luaL_loadbuffer($taskState, $taskBytes, [UIntPtr]::new($taskBytes.Length), $taskFile)
        if ($taskStatus -eq 0 -and $taskRun) { $taskStatus = [VmmLuaCheck]::lua_pcall($taskState, 0, 0, 0) }
        if ($taskStatus -ne 0) {
            throw [Runtime.InteropServices.Marshal]::PtrToStringAnsi([VmmLuaCheck]::lua_tolstring($taskState, -1, [IntPtr]::Zero))
        }
        Write-Output ('PASS: ' + [IO.Path]::GetFileName($taskFile))
    } finally { [VmmLuaCheck]::lua_close($taskState) }
}
foreach ($taskFile in Get-ChildItem -LiteralPath $taskRoot -Filter '*.lua') {
    Invoke-LuaCheck $taskFile.FullName $false
}
$taskPreviousDirectory = [Environment]::CurrentDirectory
try {
    [Environment]::CurrentDirectory = $taskRoot
    Invoke-LuaCheck (Join-Path $taskRoot 'tools\loader_spec.lua') $true
    Invoke-LuaCheck (Join-Path $taskRoot 'tools\permission_spec.lua') $true
    Invoke-LuaCheck (Join-Path $taskRoot 'tools\snapshot_spec.lua') $true
} finally { [Environment]::CurrentDirectory = $taskPreviousDirectory }
