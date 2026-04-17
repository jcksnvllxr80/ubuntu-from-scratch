# build.ps1 -- Windows-native equivalent of build.sh.
# Builds build/cidata.iso from autoinstall/user-data + meta-data, substituting
# a SHA-512 crypt hash of the password into the user-data template.
#
# Usage:
#   .\build.ps1
#   $env:PASSWORD='mypass'; .\build.ps1
#
# Requires:
#   - openssl.exe OR python.exe on PATH (for the password hash)
#   - PowerShell 5.1+ (Windows 10/11 default)
#   - Uses IMAPI2 (built into Windows) to create the ISO -- no extra tools.

[CmdletBinding()]
param(
  [string]$Password = $(if ($env:PASSWORD) { $env:PASSWORD } else { 'ubuntu' })
)

$ErrorActionPreference = 'Stop'

$Here  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Src   = Join-Path $Here 'autoinstall'
$Out   = Join-Path $Here 'build'
$Stage = Join-Path $Out 'cidata-stage'
$Iso   = Join-Path $Out 'cidata.iso'

New-Item -ItemType Directory -Force -Path $Out   | Out-Null
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force -Path $Stage | Out-Null

# ---- Hash the password (SHA-512 crypt) -----------------------------------
function Get-CryptHash {
  param([string]$Plain)

  $openssl = Get-Command openssl.exe -ErrorAction SilentlyContinue
  if ($openssl) {
    return (& $openssl.Path passwd -6 $Plain).Trim()
  }

  $python = Get-Command python.exe  -ErrorAction SilentlyContinue
  if (-not $python) { $python = Get-Command python3.exe -ErrorAction SilentlyContinue }
  if ($python) {
    $code = 'import crypt,sys; print(crypt.crypt(sys.argv[1], crypt.mksalt(crypt.METHOD_SHA512)))'
    return (& $python.Path -c $code $Plain).Trim()
  }

  throw @"
Need openssl.exe or python.exe on PATH to hash the password.
  Git for Windows ships openssl:  winget install Git.Git
  Or install OpenSSL directly:    winget install ShiningLight.OpenSSL
  Or install Python:              winget install Python.Python.3
"@
}

$PasswordHash = Get-CryptHash -Plain $Password

# ---- Render user-data ----------------------------------------------------
Copy-Item (Join-Path $Src 'meta-data') (Join-Path $Stage 'meta-data') -Force
$template = Get-Content -Raw -Path (Join-Path $Src 'user-data')
$rendered = $template.Replace('__PASSWORD_HASH__', $PasswordHash)

if ($rendered -match '__PASSWORD_HASH__') {
  throw 'password hash substitution failed -- placeholder still present'
}

# WriteAllText without a BOM so cloud-init's YAML parser stays happy
[System.IO.File]::WriteAllText((Join-Path $Stage 'user-data'), $rendered, [System.Text.UTF8Encoding]::new($false))

# ---- Build cidata.iso via IMAPI2 -----------------------------------------
# No external tools needed; IMAPI2 ships with Windows.
$isoFileType = @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;

public static class IsoFile {
  public static void WriteStream(string path, object comStream, int blockSize, int totalBlocks) {
    IntPtr readCountPtr = Marshal.AllocHGlobal(4);
    try {
      var buf = new byte[blockSize];
      var stream = (IStream)comStream;
      using (var outFile = File.OpenWrite(path)) {
        while (totalBlocks-- > 0) {
          stream.Read(buf, blockSize, readCountPtr);
          int bytesRead = Marshal.ReadInt32(readCountPtr);
          outFile.Write(buf, 0, bytesRead);
        }
        outFile.Flush();
      }
    } finally {
      Marshal.FreeHGlobal(readCountPtr);
    }
  }
}
'@
if (-not ('IsoFile' -as [type])) {
  Add-Type -TypeDefinition $isoFileType -Language CSharp | Out-Null
}

$fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
$fsi.FileSystemsToCreate = 3            # ISO9660 (1) + Joliet (2)
$fsi.VolumeName = 'cidata'

# Add staged files to the image root
$fsi.Root.AddTree($Stage, $false)

$result = $fsi.CreateResultImage()
if (Test-Path $Iso) { Remove-Item $Iso -Force }
[IsoFile]::WriteStream($Iso, $result.ImageStream, $result.BlockSize, $result.TotalBlocks)

Write-Host ""
Write-Host ("built:    {0}" -f $Iso)
Write-Host  "user:     ubuntu"
Write-Host ("password: {0}   (override with `$env:PASSWORD='xxx'; .\build.ps1)" -f $Password)
