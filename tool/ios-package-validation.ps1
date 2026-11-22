# Shared by the staged .app and final IPA checks; also runs without Xcode.
function Confirm-IosMuxFrameworkEntries([string[]]$Entries) {
  foreach ($entry in $Entries) {
    if ($entry -match '^(Resources|Versions)(/|$)') {
      throw "iOS BiliMux.framework must use a flat bundle layout: $entry"
    }
  }
  foreach ($required in @('BiliMux', 'Info.plist', 'COPYING.LGPLv2.1', 'source.txt', 'configure.log')) {
    if ($required -cnotin $Entries) { throw "iOS BiliMux.framework is missing: $required" }
  }
}

function Confirm-IosMuxFrameworkLayout([string]$Framework) {
  if (!(Test-Path -LiteralPath $Framework -PathType Container)) { throw 'iOS BiliMux.framework is missing.' }
  $entries = @(Get-ChildItem -LiteralPath $Framework -Recurse -Force | ForEach-Object {
    $relative = [System.IO.Path]::GetRelativePath($Framework, $_.FullName).Replace('\', '/')
    if ($_.PSIsContainer) { "$relative/" } else { $relative }
  })
  Confirm-IosMuxFrameworkEntries $entries
}

function Confirm-IosFvpBundle([string]$App, [string]$ExpectedMdkVersion) {
  if (!(Test-Path -LiteralPath $App -PathType Container)) { throw 'iOS app bundle is missing.' }
  $assets = 'Frameworks/App.framework/flutter_assets/native/fvp'
  foreach ($required in @(
    'Frameworks/mdk.framework/mdk',
    'Frameworks/fvp.framework/fvp',
    "$assets/assets.lock.json",
    "$assets/NOTICE.md",
    "$assets/LICENSE-fvp.txt",
    "$assets/LICENSE-libass.txt",
    "$assets/mdk.podspec"
  )) {
    $path = Join-Path $App $required
    if (!(Test-Path -LiteralPath $path -PathType Leaf)) { throw "iOS fvp bundle is missing: $required" }
  }
  $lockPath = Join-Path $App "$assets/assets.lock.json"
  try {
    $lock = Get-Content -LiteralPath $lockPath -Raw | ConvertFrom-Json
  } catch {
    throw "iOS fvp assets.lock.json is invalid: $($_.Exception.Message)"
  }
  if ($lock.version -cne $ExpectedMdkVersion) {
    throw "iOS fvp bundle MDK version $($lock.version) does not match $ExpectedMdkVersion."
  }
}
