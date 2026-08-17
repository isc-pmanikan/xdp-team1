# PowerShell port of the dataviz skill's validate_palette.js categorical checks.
# This machine has neither Node nor a real Python, so the OKLab math, the
# Machado-Oliveira-Fernandes severity-1.0 CVD matrices, and the thresholds are
# transcribed from scripts/validate_palette.js to keep results comparable.
#
#   .\Validate-Palette.ps1 -Palette "#hex,#hex,..." [-Mode light|dark]
#                          [-Surface "#hex"] [-Pairs adjacent|all]

param(
    [Parameter(Mandatory = $true)][string]$Palette,
    [ValidateSet("light", "dark")][string]$Mode = "light",
    [string]$Surface,
    [ValidateSet("adjacent", "all")][string]$Pairs = "adjacent"
)

$BAND = @{ light = @(0.43, 0.77); dark = @(0.48, 0.67) }
$CHROMA_FLOOR = 0.10
$CVD_TARGET = 8.0
$CVD_FLOOR = 6.0
$NORMAL_FLOOR = 15.0
$CONTRAST_MIN = 3.0
$DEFAULT_SURFACE = @{ light = "#fcfcfb"; dark = "#1a1a19" }

$MACHADO = @{
    protan = @(@(0.152286, 1.052583, -0.204868), @(0.114503, 0.786281, 0.099216), @(-0.003882, -0.048116, 1.051998))
    deutan = @(@(0.367322, 0.860646, -0.227968), @(0.280085, 0.672501, 0.047413), @(-0.011820, 0.042940, 0.968881))
    tritan = @(@(1.255528, -0.076749, -0.178779), @(-0.078411, 0.930809, 0.147602), @(0.004733, 0.691367, 0.303900))
}

function Get-Linear([string]$hex) {
    $h = $hex.Trim().TrimStart('#')
    $out = @()
    foreach ($i in 0, 2, 4) {
        $c = [Convert]::ToInt32($h.Substring($i, 2), 16) / 255.0
        $out += if ($c -le 0.04045) { $c / 12.92 } else { [Math]::Pow(($c + 0.055) / 1.055, 2.4) }
    }
    return $out
}

function Get-RelLum([string]$hex) {
    $l = Get-Linear $hex
    return 0.2126 * $l[0] + 0.7152 * $l[1] + 0.0722 * $l[2]
}

function Get-Contrast([string]$a, [string]$b) {
    $x = Get-RelLum $a; $y = Get-RelLum $b
    $hi = [Math]::Max($x, $y); $lo = [Math]::Min($x, $y)
    return ($hi + 0.05) / ($lo + 0.05)
}

function Get-OklabFromLinear($rgb) {
    $r = $rgb[0]; $g = $rgb[1]; $b = $rgb[2]
    # [Math]::Cbrt does not exist in .NET Framework (PowerShell 5.1), so use Pow.
    # Safe here: all three matrix rows have strictly positive coefficients and
    # linear RGB is non-negative, so no negative base ever reaches Pow.
    $third = 1.0 / 3.0
    $l = [Math]::Pow((0.4122214708 * $r + 0.5363325363 * $g + 0.0514459929 * $b), $third)
    $m = [Math]::Pow((0.2119034982 * $r + 0.6806995451 * $g + 0.1073969566 * $b), $third)
    $s = [Math]::Pow((0.0883024619 * $r + 0.2817188376 * $g + 0.6299787005 * $b), $third)
    return @(
        (0.2104542553 * $l + 0.7936177850 * $m - 0.0040720468 * $s),
        (1.9779984951 * $l - 2.4285922050 * $m + 0.4505937099 * $s),
        (0.0259040371 * $l + 0.7827717662 * $m - 0.8086757660 * $s)
    )
}

function Get-Oklch([string]$hex) {
    $lab = Get-OklabFromLinear (Get-Linear $hex)
    return @($lab[0], [Math]::Sqrt($lab[1] * $lab[1] + $lab[2] * $lab[2]))
}

function Get-Simulated([string]$hex, [string]$kind) {
    $l = Get-Linear $hex
    $M = $MACHADO[$kind]
    $out = @()
    for ($i = 0; $i -lt 3; $i++) {
        $v = $M[$i][0] * $l[0] + $M[$i][1] * $l[1] + $M[$i][2] * $l[2]
        $out += [Math]::Max(0.0, [Math]::Min(1.0, $v))
    }
    return $out
}

function Get-DeltaE([string]$h1, [string]$h2, [string]$kind) {
    if ($kind) {
        $a = Get-OklabFromLinear (Get-Simulated $h1 $kind)
        $b = Get-OklabFromLinear (Get-Simulated $h2 $kind)
    } else {
        $a = Get-OklabFromLinear (Get-Linear $h1)
        $b = Get-OklabFromLinear (Get-Linear $h2)
    }
    $d0 = $a[0] - $b[0]; $d1 = $a[1] - $b[1]; $d2 = $a[2] - $b[2]
    return 100 * [Math]::Sqrt($d0 * $d0 + $d1 * $d1 + $d2 * $d2)
}

# ---- run ----
$colors = @($Palette -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
if (-not $Surface) { $Surface = $DEFAULT_SURFACE[$Mode] }
$lo = $BAND[$Mode][0]; $hi = $BAND[$Mode][1]
$ok = $true
$rows = @()

function Add-Row([string]$state, [string]$name, [string]$detail) {
    $o = New-Object PSObject
    $o | Add-Member NoteProperty State $state
    $o | Add-Member NoteProperty Name $name
    $o | Add-Member NoteProperty Detail $detail
    return $o
}

$offband = @($colors | Where-Object { $L = (Get-Oklch $_)[0]; ($L -lt $lo) -or ($L -gt $hi) })
if ($offband.Count) { $ok = $false }
if ($offband.Count) {
    $detail = "outside band: " + (($offband | ForEach-Object { "$_ L=$([Math]::Round((Get-Oklch $_)[0],3))" }) -join ', ')
    $rows += Add-Row "FAIL" "Lightness band" $detail
} else {
    $rows += Add-Row "PASS" "Lightness band" "all $($colors.Count) inside L $lo-$hi"
}

$lowc = @($colors | Where-Object { (Get-Oklch $_)[1] -lt $CHROMA_FLOOR })
if ($lowc.Count) { $ok = $false }
if ($lowc.Count) {
    $detail = "below floor (reads gray): " + (($lowc | ForEach-Object { "$_ C=$([Math]::Round((Get-Oklch $_)[1],3))" }) -join ', ')
    $rows += Add-Row "FAIL" "Chroma floor" $detail
} else {
    $rows += Add-Row "PASS" "Chroma floor" "all $($colors.Count) >= $CHROMA_FLOOR"
}

# Pair indices are kept as two flat int arrays: PowerShell's += flattens
# nested arrays, which silently turned every pair into (0, null).
$n = $colors.Count
$pi = @(); $pj = @()
if ($Pairs -eq "all") {
    for ($i = 0; $i -lt $n; $i++) {
        for ($j = $i + 1; $j -lt $n; $j++) { $pi += $i; $pj += $j }
    }
} else {
    for ($i = 0; $i -lt $n - 1; $i++) { $pi += $i; $pj += ($i + 1) }
}
$pairCount = $pi.Count
$label = $(if ($Pairs -eq "all") { "all-pairs" } else { "adjacent" })

$worstD = 999; $worstKind = ""; $worstA = ""; $worstB = ""
foreach ($kind in "protan", "deutan") {
    for ($k = 0; $k -lt $pairCount; $k++) {
        $d = Get-DeltaE $colors[$pi[$k]] $colors[$pj[$k]] $kind
        if ($d -lt $worstD) {
            $worstD = $d; $worstKind = $kind
            $worstA = $colors[$pi[$k]]; $worstB = $colors[$pj[$k]]
        }
    }
}
$tri = 999
for ($k = 0; $k -lt $pairCount; $k++) {
    $d = Get-DeltaE $colors[$pi[$k]] $colors[$pj[$k]] "tritan"
    if ($d -lt $tri) { $tri = $d }
}
$state = $(if ($worstD -ge $CVD_TARGET) { "PASS" } elseif ($worstD -ge $CVD_FLOOR) { "WARN" } else { "FAIL" })
if ($state -eq "FAIL") { $ok = $false }
$rows += Add-Row $state "CVD separation" "worst $label $worstB<->$worstA dE $([Math]::Round($worstD,1)) ($worstKind) - tritan $([Math]::Round($tri,1))"

$nWorst = 999; $nA = ""; $nB = ""
for ($k = 0; $k -lt $pairCount; $k++) {
    $d = Get-DeltaE $colors[$pi[$k]] $colors[$pj[$k]] $null
    if ($d -lt $nWorst) { $nWorst = $d; $nA = $colors[$pi[$k]]; $nB = $colors[$pj[$k]] }
}
$nstate = $(if ($nWorst -ge $NORMAL_FLOOR) { "PASS" } else { "FAIL" })
if ($nstate -eq "FAIL") { $ok = $false }
$rows += Add-Row $nstate "Normal-vision floor" "worst $label $nB<->$nA dE $([Math]::Round($nWorst,1)) (normal)"

$low = @($colors | Where-Object { (Get-Contrast $_ $Surface) -lt $CONTRAST_MIN })
if ($low.Count) {
    $detail = "below ${CONTRAST_MIN}:1 - relief required (visible labels or table view): " +
        (($low | ForEach-Object { "$_ $([Math]::Round((Get-Contrast $_ $Surface),2)):1" }) -join ', ')
    $rows += Add-Row "WARN" "Contrast vs surface" $detail
} else {
    $rows += Add-Row "PASS" "Contrast vs surface" "all $($colors.Count) >= ${CONTRAST_MIN}:1"
}

Write-Output ""
Write-Output "Palette ($Mode, surface $Surface, $Pairs): $($colors.Count) slots"
foreach ($r in $rows) { Write-Output ("  [{0,-4}] {1,-22} {2}" -f $r.State, $r.Name, $r.Detail) }
Write-Output ""
Write-Output ("  -> " + $(if ($ok) { "ALL CHECKS PASS" } else { "FAILED - fix the marked checks" }))
Write-Output ""
if (-not $ok) { exit 1 }
