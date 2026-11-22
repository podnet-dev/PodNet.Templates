param(
  [Parameter(Mandatory = $true)][string] $SdkFeed,
  [string] $OutputFeed
)
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$feed = (Resolve-Path $SdkFeed).Path
if (-not (Test-Path (Join-Path $feed 'PodNet.Sdk.0.1.0-preview.1.nupkg'))) { throw 'SDK candidate not found in feed' }
$temp = Join-Path ([IO.Path]::GetTempPath()) ("podnet-template-gate-" + [guid]::NewGuid())
$old = @{}
foreach ($key in 'DOTNET_CLI_HOME','NUGET_PACKAGES','DOTNET_SKIP_FIRST_TIME_EXPERIENCE','DOTNET_NOLOGO','DOTNET_CLI_USE_MSBUILD_SERVER','MSBUILDDISABLENODEREUSE') { $old[$key] = [Environment]::GetEnvironmentVariable($key) }
function Invoke-Dotnet([string[]] $Arguments, [bool] $ExpectFailure = $false) {
  Write-Host "dotnet $($Arguments -join ' ')"
  if ($ExpectFailure) {
    $result = & dotnet @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    $result | ForEach-Object { Write-Host $_ }
    if ($exitCode -eq 0 -or ($result -join "`n") -notmatch 'deliberate acceptance failure') { throw 'Expected assertion failure was not observed' }
  } else {
    & dotnet @Arguments
    if ($LASTEXITCODE -ne 0) { throw "dotnet failed: $LASTEXITCODE" }
  }
}
function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
try {
  New-Item -ItemType Directory -Force $temp | Out-Null
  $env:DOTNET_CLI_HOME = Join-Path $temp 'home'
  $env:NUGET_PACKAGES = Join-Path $temp 'packages'
  $env:DOTNET_SKIP_FIRST_TIME_EXPERIENCE = '1'
  $env:DOTNET_NOLOGO = '1'
  $env:DOTNET_CLI_USE_MSBUILD_SERVER = '0'
  $env:MSBUILDDISABLENODEREUSE = '1'
  $source = Join-Path $temp 'source'
  New-Item -ItemType Directory -Force $source | Out-Null
  foreach ($name in 'global.json','Directory.Build.props','PodNet.Templates.slnx','README.md','src') { Copy-Item (Join-Path $repo $name) $source -Recurse }
  $payload = Join-Path $source 'src/Templates/content/GitHub-NuGet-Repo/PodNet.ProjectTemplate'
  foreach ($dir in 'bin','obj','artifacts','.vs','.vscode','.idea') {
    $debris = Join-Path $payload "src/ProjectTemplate/$dir"
    New-Item -ItemType Directory -Force $debris | Out-Null
    Set-Content (Join-Path $debris 'UNRELATED-LEFTOVER.txt') 'not part of template'
  }
  $packageDir = Join-Path $temp 'template-feed'
  New-Item -ItemType Directory -Force $packageDir | Out-Null
  Push-Location $source
  try { Invoke-Dotnet @('pack','PodNet.Templates.slnx','-c','Release','-o',$packageDir,'-p:Version=0.1.0-preview.1') } finally { Pop-Location }
  $package = Join-Path $packageDir 'PodNet.Templates.0.1.0-preview.1.nupkg'
  Require (Test-Path $package) 'Template package missing'
  Add-Type -AssemblyName System.IO.Compression.FileSystem
  $zip = [IO.Compression.ZipFile]::OpenRead($package)
  try {
    $names = @($zip.Entries | ForEach-Object FullName)
    Require (@($names | Where-Object { $_ -match 'UNRELATED-LEFTOVER' }).Count -eq 0) 'Build/editor debris in package'
    Require (@($names | Where-Object { $_ -match '\.template\.config/template\.json$' }).Count -eq 1) 'Template metadata missing'
    Require (@($names | Where-Object { $_ -match '/\.github/workflows/cd-nuget\.yml$' }).Count -eq 1) 'Hidden workflow missing'
  } finally { $zip.Dispose() }
  $hive = Join-Path $temp 'hive'
  Invoke-Dotnet @('new','install',$package,'--debug:custom-hive',$hive)
  $description = 'Research & development <safe> "quoted"'
  $tags = 'alpha & beta <tools>'
  foreach ($tfm in 'net11.0','netstandard2.0') {
    $name = if ($tfm -eq 'net11.0') { 'Gate.Modern' } else { 'Gate.Standard' }
    $output = Join-Path $temp $name
    Invoke-Dotnet @('new','pod-nuget-repo','--debug:custom-hive',$hive,'--name',$name,'--output',$output,'--description',$description,'--packageTags',$tags,'--targetFramework',$tfm)
    # The template source contains a repository directory; locate it without assuming CLI output naming.
    $solutions = @(Get-ChildItem $output -Filter '*.slnx' -Recurse)
    Require ($solutions.Count -eq 1) 'Expected one generated solution'
    $root = $solutions[0].DirectoryName
    $library = @(Get-ChildItem (Join-Path $root 'src') -Filter '*.csproj' -Recurse)
    $testProject = @(Get-ChildItem (Join-Path $root 'tests') -Filter '*.csproj' -Recurse)
    Require ($library.Count -eq 1 -and $testProject.Count -eq 1) 'Expected one library and one source test project'
    $project = [xml](Get-Content $library[0].FullName -Raw)
    $solutionXml = [xml](Get-Content $solutions[0].FullName -Raw)
    foreach ($entry in $solutionXml.Solution.Project) { Require (Test-Path (Join-Path $root $entry.Path)) "Broken solution path: $($entry.Path)" }
    $testXml = [xml](Get-Content $testProject[0].FullName -Raw)
    $reference = $testXml.Project.ItemGroup.ProjectReference.Include.Replace('\', [IO.Path]::DirectorySeparatorChar)
    Require ((Resolve-Path (Join-Path $testProject[0].DirectoryName $reference)).Path -eq $library[0].FullName) 'Broken project reference'
    Require ($project.Project.PropertyGroup.Description -eq $description) 'Description XML roundtrip failed'
    Require ($project.Project.PropertyGroup.PackageTags -eq $tags) 'Tags XML roundtrip failed'
    Require ($project.Project.PropertyGroup.TargetFramework -eq $tfm) 'Library framework mismatch'
    Require ($testXml.Project.PropertyGroup.TargetFramework -eq 'net11.0') 'Test framework mismatch'
    Require ((Get-Content $library[0].FullName -Raw) -match '&amp;' -and (Get-Content $library[0].FullName -Raw) -match '&lt;') 'XML values were not encoded'
    Require ((Get-Content (Join-Path $root 'README.md') -Raw).Contains($description)) 'README raw description missing'
    $year = [DateTime]::UtcNow.Year.ToString()
    Require ((Get-Content (Join-Path $root 'Directory.Build.props') -Raw).Contains("<PodNetCopyrightYear>$year</PodNetCopyrightYear>")) 'Copyright year missing'
    Require ((Get-Content (Join-Path $root 'LICENSE') -Raw).Contains("Copyright (c) $year")) 'License year missing'
    $allFiles = @(Get-ChildItem $root -File -Recurse -Force)
    Require (@($allFiles | Where-Object { $_.Name -match 'UNRELATED-LEFTOVER|\.tmpl$|\.sln$' }).Count -eq 0) 'Unexpected generated file'
    Require (@($allFiles | Where-Object { $_.FullName -match 'ProjectTemplate|\$CopyrightYear\$' }).Count -eq 0) 'Unreplaced path'
    $textFiles = @($allFiles | Where-Object { $_.Extension -in '.slnx','.csproj','.json','.props','.targets','.md','.yml' })
    foreach ($file in $textFiles) { Require ((Get-Content $file.FullName -Raw) -notmatch '3ED2BD42-60E2-4576-90EF-B70F1FADCEC1|AB59FA90-615E-4BEC-8986-B8087EE570CF|\$PodNetPackage(?:Description|Tags)(?:Xml)?\$') "Unreplaced template token in $($file.FullName)" }
    $escapedFeed = [Security.SecurityElement]::Escape($feed)
    @"
<?xml version="1.0" encoding="utf-8"?>
<configuration><packageSources><clear/><add key="candidate" value="$escapedFeed"/><add key="nuget.org" value="https://api.nuget.org/v3/index.json"/></packageSources><packageSourceMapping><packageSource key="candidate"><package pattern="PodNet.Sdk"/></packageSource><packageSource key="nuget.org"><package pattern="*"/></packageSource></packageSourceMapping></configuration>
"@ | Set-Content (Join-Path $root 'NuGet.Config')
    $testFile = Join-Path $testProject[0].DirectoryName 'AcceptanceTests.cs'
    @'
using Microsoft.VisualStudio.TestTools.UnitTesting;
[TestClass]
public class AcceptanceTests
{
    [TestMethod] public void Gate() => Assert.IsTrue(false, "deliberate acceptance failure");
}
'@ | Set-Content $testFile
    Push-Location $root
    try {
      Invoke-Dotnet @('build',$solutions[0].FullName)
      Invoke-Dotnet @('test','--project',$testProject[0].FullName) $true
      (Get-Content $testFile -Raw).Replace('Assert.IsTrue(false', 'Assert.IsTrue(true') | Set-Content $testFile
      Invoke-Dotnet @('test','--project',$testProject[0].FullName)
      $generatedFeed = Join-Path $temp "$name-pack"
      Invoke-Dotnet @('pack',$library[0].FullName,'-c','Release','-o',$generatedFeed,'-p:Version=1.2.3')
      $generated = @(Get-ChildItem $generatedFeed -Filter '*.nupkg' | Where-Object { $_.Name -notlike '*.symbols.nupkg' })
      Require ($generated.Count -eq 1 -and $generated[0].Name -eq "PodNet.$name.1.2.3.nupkg") 'Unexpected generated package ID'
      $archive = [IO.Compression.ZipFile]::OpenRead($generated[0].FullName)
      try {
        $nuspec = @($archive.Entries | Where-Object FullName -like '*.nuspec')[0]
        $reader = [IO.StreamReader]::new($nuspec.Open())
        try { $xml = [xml]$reader.ReadToEnd() } finally { $reader.Dispose() }
        Require ($xml.package.metadata.id -eq "PodNet.$name") 'Package ID mismatch'
        Require ($xml.package.metadata.description -eq $description) 'Package description mismatch'
        Require ($xml.package.metadata.tags -eq $tags) 'Package tags mismatch'
      } finally { $archive.Dispose() }
    } finally { Pop-Location }
  }
  if ($OutputFeed) { New-Item -ItemType Directory -Force $OutputFeed | Out-Null; Copy-Item $package $OutputFeed -Force }
  Write-Host 'Template acceptance passed.'
} finally {
  foreach ($key in $old.Keys) { [Environment]::SetEnvironmentVariable($key, $old[$key]) }
  if (Test-Path $temp) { Remove-Item $temp -Recurse -Force }
}