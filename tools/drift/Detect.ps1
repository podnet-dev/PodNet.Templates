#requires -Version 7.3
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$RepoPath,
    [Parameter(Mandatory)][string]$TemplatePackage,
    [string]$SdkFeed, [string]$PrimaryProject, [string]$SdkVersion,
    [string]$Python = 'python'
)
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot/Workspace.ps1"
. "$PSScriptRoot/Facts.ps1"
$deltas = [Collections.Generic.List[object]]::new()
$inference = [ordered]@{}
$result = [ordered]@{ schemaVersion=1; status='unable'; templateSha256=$null; inference=$inference; deltas=$deltas; reason=$null }
$code = 2; $temp = $null
$managed = 'LangVersion','Nullable','ImplicitUsings','UseArtifactsOutput','ArtifactsPath','OutputPath','IntermediateOutputPath','IsPackable','IsTestProject','IsTestingPlatformApplication','OutputType','EnableMSTestRunner','TestingPlatformDotnetTestSupport','PodNetCopyrightYear'
$managed += 'PackageOutputPath','GenerateDocumentationFile','IncludeSymbols','IncludeSource','EmbedAllSources','SymbolPackageFormat','PackageReadmeFile','PackageIcon','PackageLicenseExpression','PackageRequireLicenseAcceptance','Copyright','Authors','Company','RepositoryType','RepositoryUrl','PackageProjectUrl','PackageReleaseNotes','PodNetIncludeDefaultReadmePath','PodNetIncludeDefaultIcon','PodNetIncludeDefaultSponsorsFile','NugetizerIntegrationTest'
$properties = $managed + @('TargetFramework','TargetFrameworks','Description','PackageTags','PackageId','MSBuildProjectName','ManagePackageVersionsCentrally')
$evaluations = @{}
function Generated-Roles($root) {
    $projects = @(Get-Projects $root)
    $lib = @($projects | Where-Object { (Relative $root $_.FullName) -like 'src/*' })
    $test = @($projects | Where-Object { (Relative $root $_.FullName) -like 'tests/*' })
    $test = @($test | Where-Object {
        $p = (Get-Evaluation $root $_.FullName Debug '').Properties
        ($p.IsTestProject -eq 'true' -or $p.IsTestingPlatformApplication -eq 'true') -and $p.NugetizerIntegrationTest -ne 'true'
    })
    if ($lib.Count -ne 1 -or $test.Count -ne 1) { throw 'Expected one generated src library and one identifiable runnable source test' }
    @{ library=$lib[0].FullName; test=$test[0].FullName }
}
function Infer-Text($key,$value,$pattern,$marker) {
    if (!$pattern.Contains($marker)) {
        if ($value -ceq $pattern) { return '' }; throw "Cannot infer template input $key"
    }
    $parts = $pattern.Split([string[]]@($marker),[StringSplitOptions]::None)
    if ($parts.Count -ne 2 -or !$value.StartsWith($parts[0]) -or !$value.EndsWith($parts[1]) -or $value.Length -lt ($pattern.Length-$marker.Length)) { throw "Unrecognized $key defaults" }
    $value.Substring($parts[0].Length,$value.Length-$parts[0].Length-$parts[1].Length)
}
try {
    $repo = (Get-Item -LiteralPath $RepoPath).FullName
    $package = (Get-Item -LiteralPath $TemplatePackage).FullName
    if ([IO.Path]::GetExtension($package) -ne '.nupkg') { throw 'Expected a local template nupkg' }
    $base = [IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if (Inside $repo $base) { throw 'Temporary storage must be outside assessed repository' }
    $temp = New-Folder (Join-Path $base ('podnet-drift-'+[guid]::NewGuid().ToString('N')))
    $packageCopy = Join-Path (New-Folder "$temp/input") ([IO.Path]::GetFileName($package))
    [IO.File]::Copy($package,$packageCopy)
    $result.templateSha256 = (Get-FileHash -LiteralPath $packageCopy).Hash.ToLowerInvariant()
    $manifest = Read-Manifest $packageCopy
    if ($manifest.symbols.sdkVersion.isRequired -and !$SdkVersion) { throw 'Template requires an explicit baseline -SdkVersion' }
    $hive = "$temp/hive"; $actual = "$temp/actual"
    $childEnvironment = @{
        DOTNET_CLI_HOME="$temp/home"; NUGET_PACKAGES="$temp/packages"; NUGET_HTTP_CACHE_PATH="$temp/http";
        NUGET_PLUGINS_CACHE_PATH="$temp/plugins"; NUGET_SCRATCH="$temp/scratch"; DOTNET_NOLOGO='1';
        DOTNET_CLI_TELEMETRY_OPTOUT='1'; DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE='true'; MSBUILDDISABLENODEREUSE='1'
    }
    # Parent config applies equally to both trees. Restrict the candidate feed to its SDK ID.
    $sources = ''; $mapping = ''
    if ($SdkFeed) {
        $feed = Get-Item -LiteralPath $SdkFeed
        if (!$feed.PSIsContainer) { throw 'Expected local SDK feed directory' }
        $sources = '<add key="candidate" value="'+[Security.SecurityElement]::Escape($feed.FullName)+'" />'
        $mapping = '<packageSourceMapping><clear/><packageSource key="candidate"><package pattern="PodNet.Sdk"/></packageSource><packageSource key="nuget.org"><package pattern="*"/></packageSource></packageSourceMapping>'
    }
    [IO.File]::WriteAllText("$temp/NuGet.Config",'<configuration><packageSources><clear/>'+ $sources +'<add key="nuget.org" value="https://api.nuget.org/v3/index.json"/></packageSources>'+$mapping+'</configuration>')
    Copy-Tree $repo $actual
    if (@(Get-ChildItem -LiteralPath $actual -Recurse -File -Force -Filter NuGet.Config).Count) { throw 'Repository NuGet.Config requires manual source review (unsupported)' }
    $null = Invoke-Child dotnet $temp @('new','install',$packageCopy,'--debug:custom-hive',$hive)
    # Bootstrap without using *any* actual policy value, even for SDK resolution.
    $seed = Generate DriftProbe $null DriftDescription DriftTag
    $policy = Read-Global "$seed/global.json"
    $original = if (Test-Path -LiteralPath "$actual/global.json") { Read-Global "$actual/global.json" } else { @{} }
    Compare-Global $policy $original
    if (@(Get-ChildItem -LiteralPath $actual -File -Recurse -Filter global.json | Where-Object { (Relative $actual $_.FullName) -ne 'global.json' }).Count) { throw 'Nested global.json unsupported' }
    $evalGlobal = @{} + $original
    foreach ($key in 'sdk','msbuild-sdks','test') {
        if ($policy.Contains($key)) {
            $section = @{}; if ($key -eq 'msbuild-sdks' -and $original[$key]) { $section += $original[$key] }
            foreach ($member in $policy[$key].Keys) { $section[$member] = $policy[$key][$member] }
            $evalGlobal[$key] = $section
        }
    }
    [IO.File]::WriteAllText("$actual/global.json",($evalGlobal | ConvertTo-Json -Depth 20))
    if ($PrimaryProject) {
        $p = [IO.Path]::GetFullPath($PrimaryProject,$repo)
        if (!(Inside $repo $p) -or [IO.Path]::GetExtension($p) -ne '.csproj') { throw 'PrimaryProject must name a csproj inside the repository' }
        $primary = (Get-Item -LiteralPath (Join-Path $actual (Relative $repo $p))).FullName
        $confidence = 'explicit'
    } else {
        $candidates = @(Get-Projects $actual | Where-Object { (Relative $actual $_.FullName) -like 'src/*' })
        if ($candidates.Count -gt 1) {
            $candidates = @($candidates | Where-Object { (Get-Evaluation $actual $_.FullName Release '').Properties.IsPackable -eq 'true' })
        }
        if ($candidates.Count -ne 1) { throw 'Ambiguous or missing primary project; specify -PrimaryProject' }
        $primary = $candidates[0].FullName; $confidence = 'inferred'
    }
    $inference.primary = @{value=(Relative $actual $primary); confidence=$confidence}
    $props = (Get-Evaluation $actual $primary Release '').Properties
    $id = if ($props.PackageId) { $props.PackageId } else { $props.MSBuildProjectName }
    $name = $id -creplace '^PodNet\.',''
    if ($name -notmatch '^[a-z0-9][a-z0-9._-]*$') { throw 'Unsupported evaluated package name' }
    $seedRoles = Generated-Roles $seed
    $seedProps = (Get-Evaluation $seed $seedRoles.library Release '').Properties
    $inputs = @{}
    foreach ($i in @(@('description','Description','DriftDescription'),@('packageTags','PackageTags','DriftTag'))) {
        $key,$prop,$marker = $i
        try { $inputs[$key] = Infer-Text $key $props[$prop] $seedProps[$prop] $marker }
        catch {
            if ($manifest.symbols[$key].isRequired) { throw }
            # Some templates conditionally emit an entirely different value on omission.
            $d = if ($key -ne 'description') { 'DriftDescription' }
            $t = if ($key -ne 'packageTags') { 'DriftTag' }
            $defaults = Generate $name $null $d $t
            $dp = (Get-Evaluation $defaults (Generated-Roles $defaults).library Release '').Properties
            if ($props[$prop] -cne $dp[$prop]) { throw "Unrecognized template default for $key" }
            $inputs[$key] = ''
        }
    }
    $desc = $inputs.description; $tags = $inputs.packageTags
    $inference.inputs = [ordered]@{name=$name; description=$desc; packageTags=$tags; confidence='evaluated'}
    $members = @(Solution-Members $actual)
    $baselineByTfm = @{}; $seenTest = @{}
    $inference.frameworks = [ordered]@{}
    foreach ($config in 'Debug','Release') {
        $tfms = @(Frameworks (Get-Evaluation $actual $primary $config '').Properties | Sort-Object -Unique)
        $inference.frameworks[$config] = $tfms
        foreach ($tfm in $tfms) {
            if (!$baselineByTfm.ContainsKey($tfm)) { $baselineByTfm[$tfm] = Generate $name $tfm $desc $tags }
            $br = $baselineByTfm[$tfm]; $roles = Generated-Roles $br
            $bp = (Get-Evaluation $br $roles.library $config $tfm).Properties
            $rp = (Get-Evaluation $actual $primary $config $tfm).Properties
            foreach ($k in 'Description','PackageTags','PackageId') {
                if ($bp[$k] -cne $rp[$k]) { throw "Inferred template inputs do not reproduce $k for $config/$tfm" }
            }
            $required = @(Solution-Members $br)
            foreach ($role in 'library','test') {
                $ep = $roles[$role]; $rel = Relative $br $ep
                if ($rel -cnotin $required) { throw "Missing generated solution member: $rel" }
                $ap = if ($role -eq 'library') { $primary } else { Resolve-TestProject $actual $rel $primary }
                $actualRel = Relative $actual $ap
                if (!$seenTest.ContainsKey("member/$role")) {
                    if ($actualRel -cnotin $members) { Delta "solution/$role" $actualRel $null }
                    if (!(Test-Path -LiteralPath $ap -PathType Leaf)) { Delta "project/$role" $actualRel $null }
                    $seenTest["member/$role"] = $true
                }
                if (!(Test-Path -LiteralPath $ap -PathType Leaf)) { continue }
                $expectedTfms = @(Frameworks (Get-Evaluation $br $ep $config '').Properties)
                if ($role -eq 'library' -and $tfm -notin $expectedTfms) { throw 'Generated library did not adopt targetFramework' }
                $actualTfms = @(Frameworks (Get-Evaluation $actual $ap $config '').Properties)
                foreach ($f in $expectedTfms) {
                    $key = "$role/$config/$f"; if ($seenTest[$key]) { continue }; $seenTest[$key] = $true
                    if ($f -notin $actualTfms) { Delta "$key/framework" $f $null; continue }
                    Compare-Context $role $config $f $ep $ap $br $actual
                    if ($role -eq 'test') {
                        $expectsRef = References-Primary (Get-Evaluation $br $ep $config $f) $roles.library
                        if ($expectsRef) { Delta "$key/references-library" $true (References-Primary (Get-Evaluation $actual $ap $config $f) $primary) }
                    }
                }
            }
        }
    }
    Compare-Workflow $br $actual
    if ($deltas.Count) { $code = 1; $result.status = 'drift' } else { $code = 0; $result.status = 'clean' }
} catch { $result.reason = $_.Exception.Message }
finally {
    if ($temp) {
        try { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction Stop }
        catch { $code = 2; $result.status = 'unable'; $result.reason = "Temporary cleanup failed: $temp" }
    }
}
$result | ConvertTo-Json -Depth 20 -Compress
exit $code