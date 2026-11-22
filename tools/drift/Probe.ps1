#requires -Version 7.3
# Integration probes against a caller-supplied modernized package. Only mutate generated fixtures.
[CmdletBinding()]
param([Parameter(Mandatory)][string]$TemplatePackage, [string]$SdkFeed, [string]$SdkVersion,
    [string]$Python='python', [string]$TargetFramework)
$ErrorActionPreference='Stop'
$PSNativeCommandUseErrorActionPreference=$false # drift and unable are expected subprocess outcomes
. "$PSScriptRoot/Workspace.ps1"
. "$PSScriptRoot/Facts.ps1"
$pkg=(Get-Item -LiteralPath $TemplatePackage).FullName
$null=Read-Manifest $pkg
$temp=New-Folder (Join-Path ([IO.Path]::GetTempPath()) ('podnet-probe-'+[guid]::NewGuid().ToString('N')))
$hive="$temp/hive"; $childEnvironment=@{DOTNET_CLI_HOME="$temp/home"; NUGET_PACKAGES="$temp/packages"; DOTNET_NOLOGO='1'}
function Check($label,$exitCode,$fact,$reason='*Ambiguous*primary*') {
    $arguments=@('-NoProfile','-File',"$PSScriptRoot/Detect.ps1",'-RepoPath',$root,'-TemplatePackage',$pkg,'-Python',$Python)
    if ($SdkVersion) { $arguments+=@('-SdkVersion',$SdkVersion) }
    if ($SdkFeed) { $arguments+=@('-SdkFeed',$SdkFeed) }
    $output=& pwsh @arguments; $actualExit=$LASTEXITCODE
    $r=$output | ConvertFrom-Json
    if ($actualExit -ne $exitCode -or ($fact -and ($r.deltas.Count -ne 1 -or $r.deltas[0].fact -ne $fact))) { throw "${label}: $output" }
    if ($r.status -ne @('clean','drift','unable')[$exitCode] -or ($exitCode -eq 0 -and $r.deltas.Count)) { throw "${label}: $output" }
    if ($exitCode -eq 2 -and $r.reason -notlike $reason) { throw "${label}: $output" }
    Write-Host "PASS $label"
    $r
}
try {
    $null=Invoke-Child dotnet $temp @('new','install',$pkg,'--debug:custom-hive',$hive)
    $root=Generate DriftProbe $TargetFramework 'Probe & description' 'extra'
    $null=Check 'generated repository' 0
    $primary=@(Get-Projects $root | Where-Object { (Relative $root $_.FullName) -like 'src/*' })[0]
    $xml=[xml](Get-Content -Raw -LiteralPath $primary.FullName)
    $group=$xml.DocumentElement.AppendChild($xml.CreateElement('ItemGroup'))
    $ref=$group.AppendChild($xml.CreateElement('PackageReference')); $ref.SetAttribute('Include','Probe.Unmanaged')
    $xml.DocumentElement.PrependChild($group) | Out-Null
    $xml.Save($primary.FullName)
    $extra=New-Folder "$root/src/Extra"
    [IO.File]::WriteAllText("$extra/Extra.csproj",'<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFramework>net9.0</TargetFramework><IsPackable>false</IsPackable></PropertyGroup></Project>')
    $sln=(Get-ChildItem -LiteralPath $root -Filter '*.slnx').FullName
    $sx=[xml](Get-Content -Raw -LiteralPath $sln); $sx.DocumentElement.AppendChild($sx.CreateElement('Project')).SetAttribute('Path','src/Extra/Extra.csproj'); $sx.Save($sln)
    $null=Check 'XML rearrangement, unrelated reference and solution member' 0
    $test=@(Get-Projects $root | Where-Object { (Relative $root $_.FullName) -like 'tests/*' })[0]
    $before=Relative $root $test.FullName
    $after='tests/Moved/'+$test.Name
    Move-Item -LiteralPath $test.DirectoryName -Destination "$root/tests/Moved"
    $member=$sx.SelectSingleNode("//Project[@Path='$before']"); $member.SetAttribute('Path',$after); $sx.Save($sln)
    $null=Check 'moved runnable test, updated solution' 0
    Copy-Item -LiteralPath "$root/$after" -Destination "$root/tests/Moved/Other.csproj"
    $null=Check 'two corresponding runnable tests' 2 $null '*Ambiguous runnable test*'
    Remove-Item -LiteralPath "$root/tests/Moved/Other.csproj"
    $workflow=(Get-ChildItem -LiteralPath "$root/.github/workflows" -Filter '*.yml').FullName
    $text=[IO.File]::ReadAllText($workflow)
    [IO.File]::WriteAllText($workflow,$text.Replace('v[0-9]+.[0-9]+.[0-9]+*','v*'))
    $null=Check 'broadened publishing tags' 1 'workflow/trigger'
    [IO.File]::WriteAllText($workflow,$text)
    $targets="$root/Directory.Build.targets"; $savedTargets=[IO.File]::ReadAllText($targets)
    Remove-Item -LiteralPath $targets
    $r=Check 'omitted managed packaging targets' 1
    if (!@($r.deltas | Where-Object { $_.fact -like 'library/Release/*/IncludeSymbols' -and $_.expected -eq 'true' -and $_.actual -ne 'true' }).Count) { throw ($r | ConvertTo-Json -Depth 10) }
    [IO.File]::WriteAllText($targets,$savedTargets)
    $propsPath="$root/Directory.Build.props"; $saved=[IO.File]::ReadAllText($propsPath)
    $props=[xml]$saved; $year=$props.SelectSingleNode('//PodNetCopyrightYear')
    if ($year.InnerText -ne [datetime]::UtcNow.Year) { throw 'Generated year is not current' }
    $null=$year.ParentNode.RemoveChild($year); $props.Save($propsPath)
    $testXml=[xml][IO.File]::ReadAllText("$root/$after")
    $group=$testXml.SelectSingleNode('//PropertyGroup'); $group.AppendChild($testXml.CreateElement('OutputPath')).InnerText='changed-output/'
    $testXml.Save("$root/$after")
    $r=Check 'omitted year and moved test output' 1
    foreach ($config in 'Debug','Release') {
        $y=@($r.deltas | Where-Object fact -like "library/$config/*/PodNetCopyrightYear")
        $o=@($r.deltas | Where-Object fact -like "test/$config/*/OutputPath")
        if ($y.Count -ne 1 -or $y[0].expected -ne $year.InnerText -or $y[0].actual -ne '' -or $o.Count -ne 1 -or $o[0].expected -notlike 'artifacts/bin/*' -or $o[0].actual -notlike 'tests/Moved/changed-output*') { throw ($r | ConvertTo-Json -Depth 10) }
    }
    [IO.File]::WriteAllText($propsPath,$saved); $null=$group.RemoveChild($group.SelectSingleNode('OutputPath'))
    $testXml.Save("$root/$after")
    $g=Read-Global "$root/global.json"; $g.sdk.version='99.0.100'; [IO.File]::WriteAllText("$root/global.json",($g|ConvertTo-Json -Depth 20))
    $null=Check 'uninstalled actual SDK pin, no cascade' 1 'global.sdk.version'
    [IO.File]::WriteAllText("$extra/Extra.csproj",([IO.File]::ReadAllText("$extra/Extra.csproj").Replace('false','true')))
    $null=Check 'ambiguous primary' 2

    # Focused comparison probe: inject a managed baseline requirement only into synthetic projects.
    $managed=@('IsPackable'); $properties=$managed+@('ManagePackageVersionsCentrally'); $evaluations=@{}
    $deltas=[Collections.Generic.List[object]]::new()
    $fixture='<Project Sdk="Microsoft.NET.Sdk"><PropertyGroup><TargetFrameworks>net8.0;net9.0</TargetFrameworks></PropertyGroup><ItemGroup><PackageReference Include="Managed" Version="[1.0]"/></ItemGroup>CHANGE</Project>'
    $left=New-Folder "$temp/left"; $right=New-Folder "$temp/right"
    [IO.File]::WriteAllText("$left/P.csproj",$fixture.Replace('CHANGE',''))
    $change='<ItemGroup Condition="''$(TargetFramework)|$(Configuration)'' == ''net9.0|Release''"><PackageReference Update="Managed" VersionOverride="[2.0]"/></ItemGroup>'
    [IO.File]::WriteAllText("$right/P.csproj",$fixture.Replace('CHANGE',$change))
    foreach ($c in 'Debug','Release') { foreach ($f in 'net8.0','net9.0') { Compare-Context library $c $f "$left/P.csproj" "$right/P.csproj" $left $right } }
    if ($deltas.Count -ne 1 -or $deltas[0].fact -ne 'library/Release/net9.0/package/ref/Managed' -or $deltas[0].actual -ne '[2.0]') { throw ($deltas|ConvertTo-Json) }
    Write-Host 'PASS one conditional managed version delta'
} finally { Remove-Item -LiteralPath $temp -Recurse -Force }
exit 0  # Expected drift/unable child exits are assertions, not a suite failure.