# Private helpers; called only from Detect.ps1. All child working directories are temporary.
function New-Folder($path) { [IO.Directory]::CreateDirectory($path).FullName }
function Relative($root, $path) { [IO.Path]::GetRelativePath($root, $path).Replace('\','/') }
function Inside($root, $path) {
    $rel = Relative $root $path
    $rel -ne '..' -and !$rel.StartsWith('../') -and ![IO.Path]::IsPathRooted($rel)
}
function Copy-Tree($from, $to) {
    $null = New-Folder $to
    foreach ($item in Get-ChildItem -LiteralPath $from -Force) {
        if ($item.Name -in '.git','.vs','artifacts','bin','obj','TestResults','node_modules') { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Linked input unsupported: $($item.FullName)" }
        $dest = Join-Path $to $item.Name
        if ($item.PSIsContainer) { Copy-Tree $item.FullName $dest } else { [IO.File]::Copy($item.FullName,$dest) }
    }
}
function Invoke-Child($exe, $cwd, [string[]]$arguments) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $exe; $info.WorkingDirectory = $cwd; $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true; $info.RedirectStandardError = $true
    $info.RedirectStandardInput = $true
    foreach ($arg in $arguments) { $info.ArgumentList.Add($arg) }
    foreach ($key in $childEnvironment.Keys) { $info.Environment[$key] = $childEnvironment[$key] }
    $proc = [Diagnostics.Process]::Start($info)
    try {
        $proc.StandardInput.Close()
        $out = $proc.StandardOutput.ReadToEndAsync(); $err = $proc.StandardError.ReadToEndAsync()
        if (!$proc.WaitForExit(180000)) { $proc.Kill($true); throw "$exe timed out" }
        $text = $out.GetAwaiter().GetResult(); $errorText = $err.GetAwaiter().GetResult()
        if ($proc.ExitCode) { throw "$exe $($arguments[0]) failed ($($proc.ExitCode)): $(($errorText + $text).Trim())" }
        $text
    } finally { $proc.Dispose() }
}
function Read-Manifest($package) {
    $zip = [IO.Compression.ZipFile]::OpenRead($package)
    try {
        $matches = @(foreach ($entry in $zip.Entries) {
            if ($entry.FullName -notmatch '(?:^|/)\.template\.config/template\.json$') { continue }
            $r = [IO.StreamReader]::new($entry.Open())
            try { $m = $r.ReadToEnd() | ConvertFrom-Json -AsHashtable } finally { $r.Dispose() }
            if ('pod-nuget-repo' -in @($m.shortName)) { $m }
        })
        if ($matches.Count -ne 1) { throw 'Expected exactly one pod-nuget-repo manifest in the supplied package' }
        $manifest = $matches[0]
        if ($manifest.postActions) { throw 'Template post-actions are unsupported' }
        if ($manifest.additionalConfigFiles) { throw 'Split template configuration is unsupported' }
        foreach ($key in $manifest.symbols.Keys) {
            if ($manifest.symbols[$key].isRequired -and $key -cnotin 'description','packageTags','targetFramework','sdkVersion') { throw "Unsupported required template input: $key" }
        }
        $manifest
    } finally { $zip.Dispose() }
}
function Generate($name, $tfm, $description, $tags) {
    $out = New-Folder (Join-Path $temp ([guid]::NewGuid().ToString('N')))
    $argv = @('new','pod-nuget-repo','--debug:custom-hive',$hive,'--no-update-check','-n',$name,'-o',$out)
    if ($tfm) { $argv += @('--targetFramework',$tfm) }
    if ($SdkVersion) { $argv += @('--sdkVersion',$SdkVersion) }
    foreach ($pair in @{description=$description; packageTags=$tags}.GetEnumerator()) {
        if ($pair.Value) { $argv += @("--$($pair.Key)",[string]$pair.Value) }
    }
    $null = Invoke-Child dotnet $temp $argv
    $globals = @(Get-ChildItem -LiteralPath $out -Recurse -File -Filter global.json)
    if ($globals.Count -ne 1) { throw 'Expected one generated global.json' }
    $globals[0].DirectoryName
}
function Read-Global($path) { Get-Content -Raw -LiteralPath $path | ConvertFrom-Json -AsHashtable }
function Get-Projects($root) { Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.csproj' | Sort-Object FullName }
function Get-Evaluation($root,$project,$config,$tfm) {
    $key = "$project|$config|$tfm"
    if (!$evaluations.ContainsKey($key)) {
        $argv = @('msbuild',$project,'-nologo','-verbosity:quiet','-nodeReuse:false',"-property:Configuration=$config",('-getProperty:'+($properties -join ',')),'-getItem:PackageReference,PackageVersion,ProjectReference')
        if ($tfm) { $argv += "-property:TargetFramework=$tfm" }
        $evaluations[$key] = (Invoke-Child dotnet $root $argv) | ConvertFrom-Json -AsHashtable
    }
    $evaluations[$key]
}
function Frameworks($props) {
    $value = if ($props.TargetFrameworks) { $props.TargetFrameworks } else { $props.TargetFramework }
    if (!$value) { throw 'Could not infer target framework' }
    foreach ($f in $value.Split(';')) {
        $f = $f.Trim()
        if ($f -notmatch '^[a-z0-9][a-z0-9.\-]*$') { throw "Unsupported target framework: $f" }
        $f
    }
}