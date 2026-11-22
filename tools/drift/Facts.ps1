function Delta($fact,$expected,$actual) {
    if (![object]::Equals($expected,$actual)) { $deltas.Add([ordered]@{fact=$fact; expected=$expected; actual=$actual}) }
}
function Compare-Global($expected,$actual,$prefix='global') {
    foreach ($key in @($expected.Keys | Sort-Object)) {
        $v = if ($actual -is [Collections.IDictionary]) { $actual[$key] }
        if ($expected[$key] -is [Collections.IDictionary]) { Compare-Global $expected[$key] $v "$prefix.$key" }
        elseif ($expected[$key] -is [array]) { throw "Unsupported global.json array: $prefix.$key" }
        else { Delta "$prefix.$key" $expected[$key] $v }
    }
}
function Solution-Members($root) {
    $solutions = @(Get-ChildItem -LiteralPath $root -File | Where-Object Extension -in '.sln','.slnx')
    if (!$solutions.Count) { return }
    if ($solutions.Count -ne 1) { throw 'Expected one root solution' }
    if ($solutions[0].Extension -eq '.sln') {
        $null = Invoke-Child dotnet $root @('sln',$solutions[0].FullName,'migrate')
        Delta 'solution/format' '.slnx' '.sln'
        $solutions = @(Get-ChildItem -LiteralPath $root -File -Filter '*.slnx')
    }
    $xml = [xml](Get-Content -Raw -LiteralPath $solutions[0].FullName)
    if ($xml.DocumentElement.Name -cne 'Solution') { throw 'Invalid slnx root' }
    foreach ($node in $xml.SelectNodes('//Project[@Path]')) {
        $p = [IO.Path]::GetFullPath($node.GetAttribute('Path').Replace('\','/'),$root)
        Relative $root $p
    }
}
function References-Primary($evaluation,$primary) {
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($ref in $evaluation.Items.ProjectReference) {
        if ([string]::Equals($ref.FullPath,$primary,$comparison)) { return $true }
    }
    return $false
}
function Resolve-TestProject($root,$rel,$primary) {
    $expected = Join-Path $root $rel
    if (Test-Path -LiteralPath $expected -PathType Leaf) { return $expected }
    $runnable = @(foreach ($project in Get-Projects $root) {
        if ($project.FullName -eq $primary) { continue }
        $eval = Get-Evaluation $root $project.FullName Debug ''
        $p = $eval.Properties
        if (($p.IsTestProject -eq 'true' -or $p.IsTestingPlatformApplication -eq 'true') -and $p.NugetizerIntegrationTest -ne 'true') { $project }
    })
    $matches = @($runnable | Where-Object {
        $_.Name -eq [IO.Path]::GetFileName($rel) -or (References-Primary (Get-Evaluation $root $_.FullName Debug '') $primary)
    })
    if ($matches.Count -eq 1) { return $matches[0].FullName }
    if ($runnable.Count) { throw "Ambiguous runnable test role for $rel (matching candidates: $($matches.Count))" }
    return $expected  # No runnable substitute; report missing project and solution facts.
}
function Versions($items) {
    $map = @{}
    foreach ($i in $items) {
        if ($map.ContainsKey($i.Identity)) { throw "Ambiguous duplicate package: $($i.Identity)" }
        $map[$i.Identity] = $i
    }
    $map
}
function Package-Facts($evaluation) {
    $central = Versions $evaluation.Items.PackageVersion
    $refs = Versions $evaluation.Items.PackageReference
    $facts = @{}
    foreach ($id in $refs.Keys) {
        $i = $refs[$id]; $v = $i.VersionOverride
        if (!$v) { $v = $i.Version }
        if (!$v -and $evaluation.Properties.ManagePackageVersionsCentrally -eq 'true' -and $central.ContainsKey($id)) { $v = $central[$id].Version }
        $facts["ref/$id"] = ([string]$v).Trim().Replace(' ','').ToLowerInvariant()
    }
    foreach ($id in $central.Keys) {
        # For a referenced package compare effective version only, not where it was declared.
        $facts["central/$id"] = ([string]$central[$id].Version).Trim().Replace(' ','').ToLowerInvariant()
    }
    $facts
}
function Compare-Context($role,$config,$tfm,$ep,$ap,$br,$ar) {
    $e = Get-Evaluation $br $ep $config $tfm; $a = Get-Evaluation $ar $ap $config $tfm
    $prefix = "$role/$config/$tfm"
    foreach ($k in $managed) {
        if (!$e.Properties.Contains($k) -or !$a.Properties.Contains($k)) { throw "Missing evaluation for $prefix/$k" }
        if ($k -eq 'PodNetCopyrightYear' -and $e.Properties[$k] -notmatch '^[1-9][0-9]{3}$') { throw "Invalid generated year for $prefix" }
        if ($k -in 'OutputPath','IntermediateOutputPath','PackageOutputPath' -and !$e.Properties[$k]) { throw "Empty generated $prefix/$k" }
        $values = @(foreach ($pair in @(@($br,$e,$ep),@($ar,$a,$ap))) {
            $s = ([string]$pair[1].Properties[$k]).Trim()
            if ($k -in 'ArtifactsPath','OutputPath','IntermediateOutputPath','PackageOutputPath' -and $s) {
                $s = (Relative $pair[0] ([IO.Path]::GetFullPath($s.Replace('\','/'),[IO.Path]::GetDirectoryName($pair[2])))).TrimEnd('/')
            } elseif ($s -in 'true','false' -or $k -in 'LangVersion','Nullable','ImplicitUsings','OutputType') { $s = $s.ToLowerInvariant() }
            $s
        })
        Delta "$prefix/$k" $values[0] $values[1]
    }
    $ef = Package-Facts $e; $af = Package-Facts $a
    foreach ($k in @($ef.Keys | Sort-Object)) {
        if ($k.StartsWith('central/') -and $ef.ContainsKey('ref/'+$k.Substring('central/'.Length))) { continue }
        $value = if ($af.ContainsKey($k)) { $af[$k] }
        Delta "$prefix/package/$k" $ef[$k] $value
    }
}
function Get-WorkflowCalls($root) {
    $json = Invoke-Child $Python $temp @('-I','-B',(Join-Path $PSScriptRoot workflow.py),$root)
    foreach ($call in (ConvertFrom-Json -InputObject $json -AsHashtable -NoEnumerate)) { $call }
}
function Compare-Workflow($br,$ar) {
    $expected = @(Get-WorkflowCalls $br); $actual = @(Get-WorkflowCalls $ar)
    if ($expected.Count -ne 1) { throw 'Expected one direct publishing action in the baseline' }
    if ($actual.Count -gt 1) { throw 'Ambiguous publishing action in repository' }
    if (!$actual.Count) { Delta 'workflow/pod-nugetizer' 'present' $null; return }
    $e = $expected[0]; $a = $actual[0]
    foreach ($k in 'ref','username','stages','trigger') { Delta "workflow/$k" $e[$k] $a[$k] }
    foreach ($k in @($e.permissions.Keys | Sort-Object)) {
        $v = $a.permissions[$k]; if (!$v) { $v = $a.permissions['*'] }
        Delta "workflow/permissions/$k" $e.permissions[$k] $v
    }
}