# Run after `zig build`. Exercises the real parser/code generator and plain
# pdfTeX with a 30,000pt body, which exceeds TeX's maximum single dimension.
$ErrorActionPreference = 'Stop'
$repoDirectory = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$stressDirectory = Join-Path $repoDirectory '.zig-cache/tables/stress'
$vestiExecutable = Join-Path $repoDirectory 'zig-out/bin/vesti.exe'
if (-not (Test-Path -LiteralPath $vestiExecutable)) {
    throw 'Build Vesti first with zig build.'
}
$pdftexExecutable = (Get-Command pdftex -ErrorAction Stop).Source
$textCommand = Get-Command pdftotext -ErrorAction SilentlyContinue
if ($null -ne $textCommand) {
    $pdftotextExecutable = $textCommand.Source
} else {
    $pdftotextExecutable = Join-Path ([IO.Path]::GetDirectoryName($pdftexExecutable)) 'pdftotext.exe'
    if (-not (Test-Path -LiteralPath $pdftotextExecutable)) {
        throw 'pdftotext must be on PATH or beside pdftex.'
    }
}
New-Item -ItemType Directory -Path $stressDirectory -Force | Out-Null
$inputPath = Join-Path $stressDirectory 'long-1000.ves'
$outputPath = Join-Path $stressDirectory 'long-1000.tex'
$lines = [Collections.Generic.List[string]]::new()
$lines.Add('#longtabular(width=200pt,pageheight=500pt,grid=all,minheight=30pt) {')
$lines.Add('columns { col(width=flex(1)); }')
$lines.Add('firsthead { row { cell { FIRSTHEADER } } }')
$lines.Add('head { row { cell { REPEATEDHEADER } } }')
$lines.Add('foot { row { cell { CONTINUEDFOOTER } } }')
$lines.Add('lastfoot { row { cell { FINALFOOTER } } }')
$lines.Add('body {')
for ($row = 1; $row -le 1000; $row++) {
    $lines.Add('row { cell { ROW' + $row.ToString('0000') + ' } }')
}
$lines.Add('} }')
[IO.File]::WriteAllLines($inputPath, $lines)

$savedEnvironment = @{}
foreach ($name in @('VESTI_TABLE_INPUT', 'VESTI_TABLE_OUTPUT', 'VESTI_TABLE_PLAIN')) {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
try {
    $env:VESTI_TABLE_INPUT = $inputPath
    $env:VESTI_TABLE_OUTPUT = $outputPath
    $env:VESTI_TABLE_PLAIN = '1'
    $exporterPath = Join-Path $PSScriptRoot 'export.lua'
    & $vestiExecutable compile --pdflatex --first_script $exporterPath $inputPath
    if ($LASTEXITCODE -ne 0) { throw 'Vesti failed to generate the stress table.' }
} finally {
    foreach ($name in $savedEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name], 'Process')
    }
}

Push-Location -LiteralPath $stressDirectory
try {
    $texOutput = & $pdftexExecutable -interaction=nonstopmode -halt-on-error 'long-1000.tex' 2>&1
    if ($LASTEXITCODE -ne 0) { throw ($texOutput -join [Environment]::NewLine) }
    & $pdftotextExecutable -layout 'long-1000.pdf' 'long-1000.txt'
    if ($LASTEXITCODE -ne 0) { throw 'pdftotext failed to extract the stress result.' }
    $text = [IO.File]::ReadAllText((Join-Path $stressDirectory 'long-1000.txt'))
    $matches = [regex]::Matches($text, 'ROW([0-9]{4})')
    if ($matches.Count -ne 1000) { throw ('Expected 1000 rows, found ' + $matches.Count) }
    for ($index = 0; $index -lt 1000; $index++) {
        if ([int]$matches[$index].Groups[1].Value -ne ($index + 1)) {
            throw ('Duplicated, missing, or reordered row at position ' + ($index + 1))
        }
    }
    $pages = [regex]::Matches($text, '\f').Count
    if ($pages -ne 72) { throw ('Expected 72 pages, found ' + $pages) }
    foreach ($marker in @(@('FIRSTHEADER', 1), @('REPEATEDHEADER', 71), @('CONTINUEDFOOTER', 71), @('FINALFOOTER', 1))) {
        $count = [regex]::Matches($text, $marker[0]).Count
        if ($count -ne $marker[1]) { throw ('Wrong repetition count for ' + $marker[0] + ': ' + $count) }
    }
    $log = [IO.File]::ReadAllText((Join-Path $stressDirectory 'long-1000.log'))
    if ($log -match '(?m)Overfull|Underfull|^!') { throw 'Stress TeX log contains warnings or errors.' }
    Write-Output 'PASS: 72 pages; rows 1-1000 exactly once in order; correct headers and footers; clean TeX log.'
    Write-Output ('Artifacts: ' + $stressDirectory)
} finally {
    Pop-Location
}
