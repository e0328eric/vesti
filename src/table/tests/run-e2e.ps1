param(
    [switch]$SkipBuild,
    [string[]]$Engines = @('pdflatex', 'lualatex', 'xelatex', 'pdftex', 'luatex', 'xetex', 'tex', 'tectonic'),
    [string]$OutputDirectory = '.zig-cache/native-table-e2e'
)
$ErrorActionPreference = 'Stop'
$repo = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../../..'))
$out = [System.IO.Path]::GetFullPath((Join-Path $repo $OutputDirectory))
if (-not $out.StartsWith($repo + [System.IO.Path]::DirectorySeparatorChar, [System.StringComparison]::OrdinalIgnoreCase)) {
    throw 'The test output directory must stay inside this repository.'
}
New-Item -ItemType Directory -Force -Path $out | Out-Null
$savedTexCache = $env:TEXMFCACHE
$env:TEXMFCACHE = Join-Path $out 'tex-cache'
New-Item -ItemType Directory -Force -Path $env:TEXMFCACHE | Out-Null
Push-Location $repo
try {
    if (-not $SkipBuild) {
        & zig build --global-cache-dir zig-pkg
        if ($LASTEXITCODE -ne 0) { throw 'The Vesti build failed.' }
    }
    $vesti = Join-Path $repo 'zig-out/bin/vesti.exe'
    $exporter = Join-Path $PSScriptRoot 'export.lua'
    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($engine in $Engines) {
        $command = Get-Command $engine -ErrorAction SilentlyContinue
        $tectonicDll = Join-Path $repo 'zig-out/bin/vesti_tectonic_x86_64.dll'
        $useTectonicDll = $engine -eq 'tectonic' -and -not $command -and (Test-Path -LiteralPath $tectonicDll) -and (Get-Command python -ErrorAction SilentlyContinue)
        if (-not $command -and -not $useTectonicDll) {
            $results.Add([pscustomobject]@{ Engine=$engine; Fixture=''; Status='unavailable'; Pdf='' })
            continue
        }
        $plain = $engine -in @('pdftex', 'luatex', 'xetex', 'tex')
        $fixtures = if ($engine -eq 'tex') { @('core') } elseif ($engine -in @('pdftex','pdflatex')) { @('native_tables', 'native_longtable', 'metrics') } else { @('native_tables', 'native_longtable') }
        foreach ($fixture in $fixtures) {
            $engineDir = Join-Path $out $engine
            New-Item -ItemType Directory -Force -Path $engineDir | Out-Null
            $source = if ($fixture -in @('core','metrics')) { Join-Path $PSScriptRoot "$fixture.ves" } else { Join-Path $repo "examples/$fixture.ves" }
            $tex = Join-Path $engineDir "$fixture.tex"
            $env:VESTI_TABLE_INPUT = $source
            $env:VESTI_TABLE_OUTPUT = $tex
            $env:VESTI_TABLE_PLAIN = if ($plain) { '1' } else { '0' }
            & $vesti compile --pdflatex --first_script $exporter $source *> (Join-Path $engineDir "$fixture-export.log")
            if ($LASTEXITCODE -ne 0) {
                $results.Add([pscustomobject]@{ Engine=$engine; Fixture=$fixture; Status='export failed'; Pdf='' })
                Write-Output "$engine / $fixture : export failed"
                continue
            }
            $generated = [System.IO.File]::ReadAllText($tex)
            if ($generated -match '\\usepackage(?:\[[^\]]*\])?\{(?:array|tabularx|longtable|multirow|xcolor|colortbl)\}') {
                throw "Unexpected table/color package in $tex"
            }
            if ($plain -and $generated.Contains('\usepackage')) { throw "Package import in plain output $tex" }
            if ($useTectonicDll) {
                # The offline bundled format can lack the fixture's 11pt host
                # class file. Reuse the locally installed class support file;
                # this is not a dependency of the native table runtime.
                $kpsewhich = Get-Command kpsewhich -ErrorAction SilentlyContinue
                if ($kpsewhich) {
                    $classSupport = & $kpsewhich.Source 'size11.clo'
                    if ($LASTEXITCODE -eq 0 -and $classSupport) {
                        Copy-Item -LiteralPath $classSupport -Destination (Join-Path $engineDir 'size11.clo') -Force
                    }
                }
                & python (Join-Path $PSScriptRoot 'tectonic.py') $tectonicDll $tex $engineDir *> (Join-Path $engineDir "$fixture-run.log")
            } elseif ($engine -eq 'tectonic') {
                & $command.Source '--keep-logs' '--outdir' $engineDir $tex *> (Join-Path $engineDir "$fixture-run.log")
            } else {
                & $command.Source '-interaction=nonstopmode' '-halt-on-error' "-output-directory=$engineDir" $tex *> (Join-Path $engineDir "$fixture-run.log")
            }
            $status = if ($LASTEXITCODE -eq 0) { 'passed' } else { 'TeX failed' }
            if ($status -eq 'passed' -and $engine -eq 'tex') {
                & dvipdfmx '-o' (Join-Path $engineDir "$fixture.pdf") (Join-Path $engineDir "$fixture.dvi") *> (Join-Path $engineDir "$fixture-dvi.log")
                if ($LASTEXITCODE -ne 0) { $status = 'DVI conversion failed' }
            }
            $pdf = Join-Path $engineDir "$fixture.pdf"
            if ($status -eq 'passed' -and -not (Test-Path -LiteralPath $pdf)) { $status = 'PDF missing' }
            if ($status -eq 'passed') {
                & pdftotext '-layout' $pdf (Join-Path $engineDir "$fixture.txt")
                if ($LASTEXITCODE -ne 0) { $status = 'text extraction failed' }
            }
            $pages = 0
            $checks = [System.Collections.Generic.List[string]]::new()
            if ($status -eq 'passed') {
                $text = [System.IO.File]::ReadAllText((Join-Path $engineDir "$fixture.txt"))
                $pages = ([regex]::Matches($text, "`f")).Count
                $normalized = [regex]::Replace($text, '\s+', ' ')
                $markers = switch ($fixture) {
                    'native_tables' { @('AT&T Common Stock','Year','1971','Native borders and merged cells','Group','Dotted','Wrapped text','Square dots need no graphics') }
                    'native_longtable' { @('Inventory report','Paper','Kit: outer case','Kit: inserts','Shared shipment: item A','Shared shipment: item B','New category: classroom supplies','Category subtotal','A longer description','Drawing paper','Colored pencils','Display folders','Storage boxes','Final item','End of inventory','The inventory has ended.') }
                    'core' { @('Portable primitive table','First detail','Second detail') }
                    'metrics' { @('Natural-one','Natural-two','Spanning natural-width constraint','Font test','Image-top','Image-bottom','Nested-left','Nested-right','Equivalent border signatures','Metric-long-one','Metric-long-two','Metric-long-three','Metric-long-four','Metric-long-five','Metric-long-six') }
                }
                $position = 0
                foreach ($marker in $markers) {
                    $next = $normalized.IndexOf($marker, $position, [System.StringComparison]::Ordinal)
                    if ($next -lt 0) { $checks.Add("missing/out-of-order marker: $marker"); break }
                    $position = $next + $marker.Length
                }
                if ($fixture -eq 'native_longtable') {
                    if ($pages -lt 3) { $checks.Add('expected multiple dedicated table pages') }
                    if (([regex]::Matches($normalized, 'Inventory report')).Count -ne 1) { $checks.Add('first header must appear once') }
                    if (([regex]::Matches($normalized, 'Inventory\s+.*?continued')).Count -lt 1) { $checks.Add('continuation header missing') }
                    if (([regex]::Matches($normalized, 'End of inventory')).Count -ne 1) { $checks.Add('last footer must appear once') }
                }
                if ($fixture -eq 'metrics') {
                    $tablePages = $text.Split("`f") | Where-Object { $_ -match 'Metric-long-' }
                    if ($tablePages.Count -ne 2) { $checks.Add('forced metric table must have two pages') }
                    elseif ($tablePages[0] -match 'Metric continuation header' -or $tablePages[-1] -match 'Metric continuation footer') { $checks.Add('explicit empty firsthead/lastfoot failed to override inheritance') }
                    if (([regex]::Matches($normalized, 'Metric continuation header')).Count -ne 1) { $checks.Add('metric continuation header count') }
                    if (([regex]::Matches($normalized, 'Metric continuation footer')).Count -ne 1) { $checks.Add('metric continuation footer count') }
                }
                $logPath = Join-Path $engineDir "$fixture.log"
                if (Test-Path -LiteralPath $logPath) {
                    $log = [System.IO.File]::ReadAllText($logPath)
                    if ($log -match 'Overfull \\[hv]box') { $checks.Add('overfull box warning') }
                    if ($log -match '(LaTeX|Package [^\r\n]+) Warning:') { $checks.Add('LaTeX/package warning') }
                }
                if ($checks.Count -gt 0) { $status = 'content/layout check failed' }
            }
            $results.Add([pscustomobject]@{ Engine=$engine; Fixture=$fixture; Status=$status; Pages=$pages; Checks=$checks.ToArray(); Pdf=$pdf })
            Write-Output "$engine / $fixture : $status"
        }
    }
    $results | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $out 'results.json') -Encoding utf8
    if ($results | Where-Object { $_.Status -ne 'passed' -and $_.Status -ne 'unavailable' }) { throw 'Native table end-to-end checks failed; see output logs and results.json.' }
} finally {
    Remove-Item Env:VESTI_TABLE_INPUT,Env:VESTI_TABLE_OUTPUT,Env:VESTI_TABLE_PLAIN -ErrorAction SilentlyContinue
    $env:TEXMFCACHE = $savedTexCache
    Pop-Location
}
