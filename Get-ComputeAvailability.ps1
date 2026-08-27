<#
.SYNOPSIS
    Reports Azure Virtual Machine SKU availability (regions, zones, subscription
    restrictions) alongside PAYGO, Spot, Reserved Instance, and Savings Plan
    monthly pricing.

.DESCRIPTION
    Two data sources:
      - Pricing:      Azure Retail Prices API (no auth required, public).
      - Availability: Get-AzComputeResourceSku (requires Az.Compute module and
                      a logged-in Azure context via Connect-AzAccount). When
                      unavailable, the script still returns pricing data and
                      the Zones column shows '?'.

    Availability info surfaces:
      - Region access: 'Allowed' or 'RESTRICTED' (subscription-level Location
        restriction; SKU cannot be deployed in the region at all)
      - Zones supported in the region (e.g. "1,2,3"), excluding any zones the
        subscription is blocked from (Zone-type restrictions)
      - 'N/A' when the SKU has no zonal deployment in the region
      - '?' when availability lookup was skipped or unavailable

    Compute has BOTH commitment-discount mechanisms (unlike storage):
      - Reserved Instances (RI):  SKU-locked, 1-year or 3-year terms.
      - Savings Plans (SP):       hourly $ commitment that floats across VM
                                  families and regions; 1-year or 3-year terms.

    Savings Plan rates are embedded inside each Consumption record as the
    `savingsPlan` array (term = "1 Year" / "3 Years"). RI rates are returned as
    separate items with priceType = "Reservation"; despite unitOfMeasure being
    "1 Hour", retailPrice is the FULL TERM lump-sum cost (1yr = 12 months,
    3yr = 36 months). This script divides by term months to derive monthly.

    PRICING SCOPE: Linux compute by default. SQL / Red Hat / other ISV license
    premiums are NEVER included. Pass -IncludeWindows to add a second row per
    SKU/region showing Windows compute rates (Linux base + Windows license).
    RIs and Savings Plans do NOT discount the OS license portion - the license
    component is billed at PAYGO rates even under commitments. Reported Save%
    is always relative to the SAME-OS PAYGO baseline.

    All output is monthly. HoursPerMonth (default 730) is used to project Spot,
    PAYGO, and SP hourly rates into monthly equivalents.

.PARAMETER Region
    One or more ARM region names (e.g. australiaeast, northeurope, eastus).
    Optional when -RegionCsv is supplied; inline values and CSV values are
    combined.

.PARAMETER RegionCsv
    Path to a CSV file listing ARM region names to include. Values may be
    comma-separated on one line, one per line, or a mix, with or without a
    header row (a leading Region/Location/Name header is ignored). Values are
    merged with any inline -Region values and de-duplicated. At least one
    region (inline or CSV) is required.

.PARAMETER VmSize
    One or more ARM SKU names (e.g. Standard_D2s_v5, Standard_E4s_v5). Optional
    when -VmSizeCsv is supplied; inline values and CSV values are combined.

.PARAMETER VmSizeCsv
    Path to a CSV file listing VM SKU names to include. Values may be
    comma-separated on one line, one per line, or a mix, with or without a
    header row (a leading VmSize/SKU/Size/Name header is ignored). Values are
    merged with any inline -VmSize values and de-duplicated. At least one VM
    size (inline or CSV) is required.

.PARAMETER IncludeSpot
    Include Spot pricing in the output. Spot is highly variable; the API returns
    the current published rate at query time.

.PARAMETER IncludeWindows
    Include Windows compute rates as additional rows alongside Linux. Windows
    rates bundle the Windows Server license premium, which is not discounted
    by Reserved Instances or Savings Plans (those only discount compute).
    Customers with Azure Hybrid Benefit (AHB) should ignore Windows rows and
    use the Linux rows + their own AHB-licensed pricing.

.PARAMETER HoursPerMonth
    Hours used to project hourly rates into monthly costs. Default 730
    (Azure billing convention: 365.25 * 24 / 12).

.PARAMETER ACD
    All-up customer discount percentage (0-100) to apply to the PAYGO rate.
    Use this to reflect EA/MCA negotiated discounts that lower your effective
    pay-as-you-go rate. RI and SP rates are NOT adjusted; Save% values are
    recalculated against the discounted PAYGO so commitment savings reflect
    your real baseline. Default 0 (list price).

.PARAMETER InstanceCount
    Multiply all monthly cost columns by this count to project an N-instance
    deployment. Save% values are unaffected (a ratio). Default 1.

.PARAMETER OutputCsv
    Optional path to export results as a CSV file.

.PARAMETER SkipAvailability
    Skip the Get-AzComputeResourceSku availability lookup even if Az.Compute
    and an Azure context are available. Useful for faster pricing-only runs.

.PARAMETER SkipPricing
    Skip the Azure Retail Prices API queries. Produces an availability-only
    matrix (subscription, region, SKU + RegionAccess/ZoneAccess). All pricing
    columns (PAYGO, Spot, RI, SP) are omitted from output and CSV. Cannot be
    combined with -SkipAvailability.

.PARAMETER Subscription
    One or more subscription names or IDs to evaluate. SKU availability and
    restrictions are subscription-scoped, so each sub gets its own row. When
    omitted, the current Az context subscription is used. Pricing data is
    public (Retail API) and identical across subs, so it is queried once per
    region and reused.

.PARAMETER SubscriptionCsv
    Path to a CSV file listing subscription names or IDs to evaluate. Values may
    be comma-separated on one line, one per line, or a mix, with or without a
    header row (a leading Subscription/SubscriptionId/SubscriptionName/Id/Name
    header is ignored). Values are merged with any inline -Subscription values
    and de-duplicated.

.PARAMETER Currency
    ISO currency code for pricing (e.g. USD, EUR, GBP, AUD). Passed to the Azure
    Retail Prices API. Default USD. All monetary columns are expressed in this
    currency.

.PARAMETER PassThru
    Emit the result rows as objects to the pipeline (in addition to the console
    table) so they can be filtered, sorted, or exported by the caller.

.PARAMETER ThrottleLimit
    Max parallel region queries. Default 5.

.EXAMPLE
    .\Get-ComputeAvailability.ps1 -Region australiaeast,eastus -VmSize Standard_D2s_v5,Standard_D4s_v5

.EXAMPLE
    .\Get-ComputeAvailability.ps1 -Region eastus -VmSize Standard_E8s_v5 -IncludeSpot -OutputCsv .\vm-prices.csv

.EXAMPLE
    .\Get-ComputeAvailability.ps1 -RegionCsv .\regions.csv -VmSizeCsv .\skus.csv -SubscriptionCsv .\subs.csv

.EXAMPLE
    .\Get-ComputeAvailability.ps1 -Region westeurope -VmSize Standard_D2s_v5 -Currency EUR -PassThru |
        Where-Object RI_3Yr_Save_Pct -gt 40 | Sort-Object RI_3Yr_PerMonth
#>
#Requires -Version 7.0
[CmdletBinding()]
param(
    [string[]]$VmSize        = @(),
    [string[]]$Region        = @(),
    [string]$VmSizeCsv       = '',
    [string]$RegionCsv       = '',
    [switch]$IncludeSpot,
    [switch]$IncludeWindows,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$HoursPerMonth      = 730,
    [ValidateRange(0, 100)]
    [double]$ACD             = 0,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$InstanceCount      = 1,
    [ValidatePattern('^[A-Za-z]{3}$')]
    [string]$Currency        = 'USD',
    [string]$OutputCsv       = '',
    [switch]$PassThru,
    [switch]$SkipAvailability,
    [switch]$SkipPricing,
    [string[]]$Subscription  = @(),
    [string]$SubscriptionCsv = '',
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ThrottleLimit      = 5
)

Set-StrictMode -Version 1

$Currency = $Currency.ToUpperInvariant()

if ($SkipAvailability -and $SkipPricing) {
    throw 'Cannot specify both -SkipAvailability and -SkipPricing; at least one data source is required.'
}

# ----- CSV-sourced VM sizes / subscriptions --------------------------------
# Read SKU names and/or subscription identifiers from CSV files and merge them
# with any inline -VmSize / -Subscription values. Values are trimmed, blanks
# dropped, and duplicates removed. Any layout is accepted: values may be
# comma-separated on one line, one per line, or a mix, with or without a header
# row. Tokens matching a known header name (case-insensitive) are discarded.
function Import-CsvValues {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string[]]$Header
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "CSV file not found: $Path"
    }
    $headerSet = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]$Header, [System.StringComparer]::OrdinalIgnoreCase)
    $tokens = [System.IO.File]::ReadAllText($Path) -split '[,\r\n]+'
    $values = @($tokens |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -ne '' -and -not $headerSet.Contains($_) } |
        Select-Object -Unique)
    if ($values.Count -eq 0) {
        Write-Warning "No values found in CSV file: $Path"
    }
    return $values
}

if ($VmSizeCsv) {
    $csvSkus = Import-CsvValues -Path $VmSizeCsv -Header @('VmSize','SKU','Size','Name')
    $VmSize  = @($VmSize + $csvSkus | Where-Object { $_ } | Select-Object -Unique)
}
if ($RegionCsv) {
    $csvRegions = Import-CsvValues -Path $RegionCsv -Header @('Region','Location','Name')
    $Region     = @($Region + $csvRegions | Where-Object { $_ } | Select-Object -Unique)
}
if ($SubscriptionCsv) {
    $csvSubs      = Import-CsvValues -Path $SubscriptionCsv -Header @('Subscription','SubscriptionId','SubscriptionName','Id','Name')
    $Subscription = @($Subscription + $csvSubs | Where-Object { $_ } | Select-Object -Unique)
}

if ($VmSize.Count -eq 0) {
    throw 'No VM sizes specified. Provide -VmSize and/or -VmSizeCsv.'
}
if ($Region.Count -eq 0) {
    throw 'No regions specified. Provide -Region and/or -RegionCsv.'
}

Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Azure Virtual Machine Availability + Price Comparison' -ForegroundColor Cyan
Write-Host "  Regions        : $($Region -join ', ')" -ForegroundColor Cyan
Write-Host "  VM Sizes       : $($VmSize -join ', ')" -ForegroundColor Cyan
if ($Subscription -and -not $SkipAvailability) { Write-Host "  Subscriptions  : $($Subscription -join ', ')" -ForegroundColor Cyan }
# Spot / license / hours / discount / instance options only affect pricing output,
# and the licensing NOTE with them; hide the whole group when pricing is skipped.
if (-not $SkipPricing) {
    Write-Host "  Spot           : $(if ($IncludeSpot) { 'included' } else { 'excluded' })" -ForegroundColor Cyan
    Write-Host "  WindowsLicense : $(if ($IncludeWindows) { 'included (license bundled)' } else { 'excluded' })" -ForegroundColor Cyan
    Write-Host "  Hours/Mo       : $HoursPerMonth" -ForegroundColor Cyan
    Write-Host "  Currency       : $Currency" -ForegroundColor Cyan
    if ($ACD -gt 0) { Write-Host "  ACD            : -$ACD% applied to PAYGO" -ForegroundColor Cyan }
    if ($InstanceCount -gt 1) { Write-Host "  Instances      : x$InstanceCount" -ForegroundColor Cyan }
    Write-Host '' -ForegroundColor Cyan
    if ($IncludeWindows) {
        Write-Host '  NOTE: Windows rows bundle the Windows Server license premium.' -ForegroundColor Yellow
        Write-Host '        RIs and Savings Plans do NOT discount the OS license portion -' -ForegroundColor Yellow
        Write-Host '        only the underlying compute. SQL / other ISV licenses excluded.' -ForegroundColor Yellow
        Write-Host '        Azure Hybrid Benefit (AHB) users: ignore Windows rows and use Linux.' -ForegroundColor Yellow
    } else {
        Write-Host '  NOTE: Prices do NOT include Windows / SQL / other OS license costs.' -ForegroundColor Yellow
        Write-Host '        Reservations and Savings Plans only discount the compute portion.' -ForegroundColor Yellow
        Write-Host '        Use -IncludeWindows to add Windows-licensed pricing rows.' -ForegroundColor Yellow
    }
}
# Run-mode status is unrelated to the pricing inputs above; keep it at the bottom.
if ($SkipPricing)      { Write-Host '  Pricing        : skipped (availability-only)' -ForegroundColor Cyan }
if ($SkipAvailability) { Write-Host '  Availability   : skipped (pricing-only)' -ForegroundColor Cyan }
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''

$rows = [System.Collections.Concurrent.ConcurrentBag[pscustomobject]]::new()

function Format-Price {
    # All values here are monthly amounts in the selected currency; show 2
    # decimals with thousands separators. $null -> 'N/A'.
    param([object]$Value)
    if ($null -eq $Value) { return 'N/A' }
    return ([double]$Value).ToString('N2')
}

function Format-Pct {
    # Save% display: $null -> 'N/A', otherwise append '%'.
    param([object]$Value)
    if ($null -eq $Value) { return 'N/A' }
    return "$Value%"
}

# ----- Subscription resolution + SKU availability lookup -------------------
# Resolve target subscriptions:
#   - If -Subscription was supplied, look each up by Name then by Id
#   - Else use current Az context (or a single empty placeholder if Az is
#     unavailable, so the script still produces pricing-only rows)
# Each emitted row carries SubscriptionName/Id so multi-sub diffs are visible.
#
# Availability is the ONLY subscription-scoped data. When -SkipAvailability is
# set, pricing is identical across subscriptions, so any -Subscription input is
# ignored and we collapse to a single subscription (current context, or a
# placeholder) to avoid emitting duplicate pricing rows.
$subs = [System.Collections.Generic.List[hashtable]]::new()
$azAvailable = $false
try {
    $null = Get-Command Get-AzContext -ErrorAction Stop
    $azAvailable = $true
} catch { }

if ($SkipAvailability -and $Subscription.Count -gt 0) {
    Write-Warning "-Subscription is ignored with -SkipAvailability (subscription scope only affects availability); pricing is identical across subscriptions, so a single row set is produced."
}

if ($Subscription.Count -gt 0 -and -not $SkipAvailability) {
    if (-not $azAvailable) {
        Write-Warning "-Subscription specified but Az module not available. Install Az.Accounts and Connect-AzAccount."
    } else {
        foreach ($s in $Subscription) {
            $resolved = $null
            try { $resolved = Get-AzSubscription -SubscriptionName $s -ErrorAction Stop } catch { }
            if (-not $resolved) {
                try { $resolved = Get-AzSubscription -SubscriptionId $s -ErrorAction Stop } catch { }
            }
            if ($resolved) {
                $subs.Add(@{ Name = $resolved.Name; Id = $resolved.Id })
            } else {
                Write-Warning "Subscription not found / not accessible: $s"
            }
        }
    }
}

if ($subs.Count -eq 0) {
    # Fall back to current context, or a single empty placeholder
    if ($azAvailable) {
        try {
            $ctx = Get-AzContext -ErrorAction Stop
            if ($ctx -and $ctx.Subscription) {
                $subs.Add(@{ Name = $ctx.Subscription.Name; Id = $ctx.Subscription.Id })
            }
        } catch { }
    }
    if ($subs.Count -eq 0) { $subs.Add(@{ Name = ''; Id = '' }) }
}

# ----- Pre-flight: validate region names against Azure ---------------------
# Get-AzLocation returns regions the current context can see. Pruning invalid
# region names here avoids wasted Retail API calls and confusing downstream
# warnings. If Az is unavailable, this step is silently skipped and bad regions
# will surface later via empty Retail API results.
if ($azAvailable -and ($subs[0].Id -ne '')) {
    try {
        # Build case-insensitive canonical-name map: lowercased input -> canonical
        $validRegions = (Get-AzLocation -ErrorAction Stop).Location
        $canonMap     = [System.Collections.Generic.Dictionary[string,string]]::new(
            [System.StringComparer]::OrdinalIgnoreCase)
        foreach ($v in $validRegions) { $canonMap[$v] = $v }

        $invalidRegions = @($Region | Where-Object { -not $canonMap.ContainsKey($_) })
        if ($invalidRegions) {
            Write-Warning "Invalid Azure region name(s) - removed from query: $($invalidRegions -join ', ')"
        }
        # Normalize survivors to canonical (ARM API filter is case-sensitive)
        $Region = @($Region |
            Where-Object { $canonMap.ContainsKey($_) } |
            ForEach-Object { $canonMap[$_] } |
            Select-Object -Unique)

        if ($Region.Count -eq 0) {
            throw 'No valid regions remain after validation. Use Get-AzLocation to see available region names.'
        }
    } catch [System.Management.Automation.RuntimeException] {
        throw
    } catch {
        Write-Warning "Region validation skipped: $($_.Exception.Message)"
    }
}

# Availability map keyed "subId|region|sku" -> @{ Zones; RegionBlocked; Reason }
# Parallelized across (sub x region) work items via ARM REST. We acquire a
# single Bearer token up front and reuse it in every parallel runspace, which
# avoids per-sub Set-AzContext serialization and gives the same ThrottleLimit
# concurrency the pricing block enjoys.
$availMap        = @{}
$availAvailable  = $false
if (-not $SkipAvailability) {
    try {
        if (-not $azAvailable) { throw 'Az.Accounts not available; run Connect-AzAccount.' }
        $ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $ctx -or -not $ctx.Subscription) { throw 'No active Azure context.' }

        # Acquire ARM token once. Newer Az.Accounts (>=2.20) returns SecureString
        # by default; older versions return plain string. Handle both shapes.
        $tokenResult = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
        $armToken    = if ($tokenResult.Token -is [System.Security.SecureString]) {
            [System.Net.NetworkCredential]::new('', $tokenResult.Token).Password
        } else { [string]$tokenResult.Token }

        $workItems = @(foreach ($sub in $subs) {
            if (-not $sub.Id) { continue }   # placeholder sub, skip availability
            foreach ($r in $Region) {
                @{ SubId = $sub.Id; SubName = $sub.Name; Region = $r }
            }
        })

        if ($workItems.Count -gt 0) {
            Write-Progress -Activity 'SKU availability lookup' -Status "$($workItems.Count) subscription/region pair(s)..."
            $availResults = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
            $vmSizeSet    = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]$VmSize, [System.StringComparer]::OrdinalIgnoreCase)

            $workItems | ForEach-Object -Parallel {
                $item     = $_
                $token    = $using:armToken
                $skuSet   = $using:vmSizeSet
                $bag      = $using:availResults

                $filter = "location eq '$($item.Region)'"
                $uri    = "https://management.azure.com/subscriptions/$($item.SubId)/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=$([Uri]::EscapeDataString($filter))"
                $headers = @{ Authorization = "Bearer $token" }
                $allItems = [System.Collections.Generic.List[object]]::new()
                try {
                    do {
                        $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
                        if ($resp.value) { $allItems.AddRange([object[]]$resp.value) }
                        $uri = if ($resp.PSObject.Properties['nextLink'] -and $resp.nextLink) { $resp.nextLink } else { $null }
                    } while ($uri)
                } catch {
                    Write-Warning "Availability lookup failed (sub: $($item.SubName), region: $($item.Region)): $($_.Exception.Message)"
                    return
                }

                foreach ($s in $allItems) {
                    if ($s.resourceType -ne 'virtualMachines') { continue }
                    if (-not $skuSet.Contains($s.name))        { continue }

                    # Start with all zones the SKU lists in this region, then
                    # subtract any zones explicitly restricted for the sub.
                    $allZones = @()
                    if ($s.locationInfo -and $s.locationInfo[0].zones) {
                        $allZones = @($s.locationInfo[0].zones | Sort-Object)
                    }
                    $allowedZones  = $allZones
                    $regionBlocked = $false
                    $reason        = ''
                    if ($s.restrictions) {
                        foreach ($rest in $s.restrictions) {
                            if ($rest.reasonCode) { $reason = $rest.reasonCode }
                            switch ($rest.type) {
                                'Location' { $regionBlocked = $true }
                                'Zone'     {
                                    $blockedZones = @()
                                    if ($rest.restrictionInfo -and $rest.restrictionInfo.zones) {
                                        $blockedZones = @($rest.restrictionInfo.zones)
                                    }
                                    $allowedZones = @($allowedZones | Where-Object { $_ -notin $blockedZones })
                                }
                            }
                        }
                    }
                    $bag.Add(@{
                        Key            = "$($item.SubId)|$($item.Region)|$($s.name)"
                        Zones          = $allowedZones
                        RegionBlocked  = $regionBlocked
                        Reason         = $reason
                    })
                }
            } -ThrottleLimit $ThrottleLimit

            foreach ($entry in $availResults) {
                $availMap[$entry.Key] = @{
                    Zones          = $entry.Zones
                    RegionBlocked  = $entry.RegionBlocked
                    Reason         = $entry.Reason
                }
            }
            Write-Progress -Activity 'SKU availability lookup' -Completed
        }
        $availAvailable = $true
    } catch {
        Write-Warning "SKU availability unavailable - $($_.Exception.Message)"
        Write-Warning "Install Az.Accounts and run Connect-AzAccount to enable, or pass -SkipAvailability to silence."
    }
}

# ----- Canonicalize VM SKU names ------------------------------------------
# The Retail API's armSkuName filter is case-sensitive server-side
# (armSkuName eq 'standard_d2s_v5' returns zero rows). Normalize user input
# to canonical case using the ARM SKU catalog. Prefer the availability data
# we already fetched; fall back to a one-shot ARM call when availability was
# skipped or empty.
if ($azAvailable -and ($subs[0].Id -ne '')) {
    $skuCanonMap = [System.Collections.Generic.Dictionary[string,string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    if ($availMap.Count -gt 0) {
        foreach ($key in $availMap.Keys) {
            $name = $key.Split('|', 3)[2]
            if (-not $skuCanonMap.ContainsKey($name)) { $skuCanonMap[$name] = $name }
        }
    } elseif (-not $SkipPricing) {
        # No availability data and pricing is needed - one un-filtered ARM call
        # against the first valid region just to canonicalize names.
        try {
            $tokenResult = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
            $token = if ($tokenResult.Token -is [System.Security.SecureString]) {
                [System.Net.NetworkCredential]::new('', $tokenResult.Token).Password
            } else { [string]$tokenResult.Token }
            $filter  = "location eq '$($Region[0])'"
            $uri     = "https://management.azure.com/subscriptions/$($subs[0].Id)/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=$([Uri]::EscapeDataString($filter))"
            $headers = @{ Authorization = "Bearer $token" }
            do {
                $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
                if ($resp.value) {
                    foreach ($s in $resp.value) {
                        if ($s.resourceType -eq 'virtualMachines' -and -not $skuCanonMap.ContainsKey($s.name)) {
                            $skuCanonMap[$s.name] = $s.name
                        }
                    }
                }
                $uri = if ($resp.PSObject.Properties['nextLink'] -and $resp.nextLink) { $resp.nextLink } else { $null }
            } while ($uri)
        } catch {
            Write-Warning "SKU name canonicalization skipped: $($_.Exception.Message)"
        }
    }

    if ($skuCanonMap.Count -gt 0) {
        $VmSize = @($VmSize | ForEach-Object {
            if ($skuCanonMap.ContainsKey($_)) { $skuCanonMap[$_] } else { $_ }
        })
    }
}

# ---------------------------------------------------------------------------
Write-Progress -Activity 'Querying regions' -Status "$($Region.Count) region(s)..."

$Region | ForEach-Object -Parallel {
    $region       = $_
    $vmSizes      = $using:VmSize
    $includeSpot  = $using:IncludeSpot
    $includeWin   = $using:IncludeWindows
    $skipPricing  = $using:SkipPricing
    $hoursPerMo   = $using:HoursPerMonth
    $acd          = $using:ACD
    $instCount    = $using:InstanceCount
    $availMap     = $using:availMap
    $availOn      = $using:availAvailable
    $subs         = $using:subs
    $rowsBag      = $using:rows
    $currency     = $using:Currency

    function Invoke-PricingPages {
        param([string]$Filter)
        # api-version=2023-01-01-preview is required to surface the `savingsPlan`
        # array on Consumption records. Without it, SP rates are not returned.
        $uri   = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=$currency&`$filter=$([Uri]::EscapeDataString($Filter))"
        $items = [System.Collections.Generic.List[object]]::new()
        do {
            $page = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
            if ($page.Items) { $items.AddRange([object[]]$page.Items) }
            $uri  = if ($page.PSObject.Properties['NextPageLink'] -and $page.NextPageLink) { $page.NextPageLink } else { $null }
        } while ($uri)
        return , $items.ToArray()
    }

    # Pricing API: skipped entirely when -SkipPricing was passed. We still emit
    # one row per (sub, sku) for availability-only output below.
    $consIndex = @{}
    $riIndex   = @{}
    if (-not $skipPricing) {
        # Build single-region SKU filter: armSkuName eq 'A' or armSkuName eq 'B' ...
        $skuClause = ($vmSizes | ForEach-Object { "armSkuName eq '$_'" }) -join ' or '

        # Single combined request: Consumption + Reservation in one call (halves API hits per region)
        $combinedFilter = "serviceName eq 'Virtual Machines' and armRegionName eq '$region' " +
                          "and (priceType eq 'Consumption' or priceType eq 'Reservation') " +
                          "and ($skuClause)"

        $items = @()
        try { $items = Invoke-PricingPages -Filter $combinedFilter }
        catch { Write-Warning "[$region] price query failed: $($_.Exception.Message)" ; return }

        # Split locally by priceType
        $consumptionItems = $items | Where-Object { $_.type -eq 'Consumption' }
        $reservationItems = $items | Where-Object { $_.type -eq 'Reservation' }

        # Index consumption records by OS. productName containing 'Windows'
        # discriminates Windows-licensed rates from Linux/base rates.
        # Kind: Spot if meterName contains "Spot"; skip legacy "Low Priority" meters.
        # Key: "{armSkuName}|{OS}|{Kind}" -> @{ Rate; SP1Yr; SP3Yr }   (hourly rates)
        foreach ($item in $consumptionItems) {
            $itemOs = if ($item.productName -match 'Windows') { 'Windows' } else { 'Linux' }
            if ($itemOs -eq 'Windows' -and -not $includeWin) { continue }
            if ($item.meterName    -match 'Low Priority') { continue }
            $itemKind = if ($item.meterName -match 'Spot') { 'Spot' } else { 'PAYGO' }
            $key      = "$($item.armSkuName)|$itemOs|$itemKind"

            $sp1 = $null; $sp3 = $null
            if ($item.PSObject.Properties['savingsPlan'] -and $item.savingsPlan) {
                foreach ($sp in $item.savingsPlan) {
                    switch ($sp.term) {
                        '1 Year'  { $sp1 = $sp.retailPrice }
                        '3 Years' { $sp3 = $sp.retailPrice }
                    }
                }
            }
            # Keep first match per key (API may emit duplicates across product variants)
            if (-not $consIndex.ContainsKey($key)) {
                $consIndex[$key] = @{ Rate = $item.retailPrice; SP1Yr = $sp1; SP3Yr = $sp3 }
            }
        }

        # Index reservations per OS: "{armSkuName}|{OS}|{Term}" -> total lump-sum term price.
        # NOTE: unitOfMeasure is "1 Hour" but retailPrice is the FULL TERM cost.
        foreach ($item in $reservationItems) {
            $itemOs = if ($item.productName -match 'Windows') { 'Windows' } else { 'Linux' }
            if ($itemOs -eq 'Windows' -and -not $includeWin) { continue }
            $termStr = $item.reservationTerm   # "1 Year" or "3 Years" (skip "10 Years" v8 variant)
            if ($termStr -notin @('1 Year','3 Years')) { continue }
            $key = "$($item.armSkuName)|$itemOs|$termStr"
            if (-not $riIndex.ContainsKey($key)) {
                $riIndex[$key] = $item.retailPrice   # total lump-sum for the full term
            }
        }
    }

    # OS dimension only applies when pricing is included. With -SkipPricing we
    # emit a single row per (sub, sku) with no OS distinction.
    $osList = if ($skipPricing)   { @('') }
              elseif ($includeWin) { @('Linux','Windows') }
              else                 { @('Linux') }
    foreach ($sub in $subs) {
     foreach ($sku in $vmSizes) {
      foreach ($os in $osList) {
        # Pricing math (skipped entirely when -SkipPricing was passed)
        $payMo = $null; $spotMo = $null; $spotPct = $null
        $ri1Mo = $null; $ri1Pct = $null; $ri3Mo = $null; $ri3Pct = $null
        $sp1Mo = $null; $sp1Pct = $null; $sp3Mo = $null; $sp3Pct = $null

        if (-not $skipPricing) {
            $payg = $consIndex["$sku|$os|PAYGO"]
            if (-not $payg) { continue }   # SKU/OS not available in region

            # PAYGO monthly, with optional all-up customer discount applied, then
            # scaled by InstanceCount. Save% comparisons below all use this figure.
            $acdMult = 1 - ($acd / 100)
            $payMo   = $payg.Rate * $hoursPerMo * $acdMult * $instCount

            # Spot (hourly -> monthly, scaled by InstanceCount)
            if ($includeSpot) {
                $spot = $consIndex["$sku|$os|Spot"]
                if ($spot) {
                    $spotMo  = $spot.Rate * $hoursPerMo * $instCount
                    $spotPct = if ($payMo -gt 0) { [Math]::Round((1 - $spotMo / $payMo) * 100, 1) } else { $null }
                }
            }

            # Reserved Instance / Savings Plan:
            # The Retail API publishes ONE OS-agnostic RI/SP entry per SKU (under the
            # Linux product line). The Windows license premium is NEVER discounted by
            # a commitment - it bills at PAYGO rates regardless. So for Windows rows
            # we reuse the Linux RI/SP compute rate and add the Windows license delta
            # (= Windows_PAYGO - Linux_PAYGO) at PAYGO, which matches real billing.
            $baseRiPayg = if ($os -eq 'Windows') { $consIndex["$sku|Linux|PAYGO"] } else { $payg }
            $ri1Total   = $riIndex["$sku|Linux|1 Year"]
            $ri3Total   = $riIndex["$sku|Linux|3 Years"]
            $licenseDeltaHr = if ($os -eq 'Windows' -and $baseRiPayg) { $payg.Rate - $baseRiPayg.Rate } else { 0 }
            $licenseMo      = $licenseDeltaHr * $hoursPerMo * $instCount   # PAYGO; no ACD on license premium

            $ri1Mo = if ($null -ne $ri1Total) { (($ri1Total / 12) * $instCount) + $licenseMo } else { $null }
            $ri3Mo = if ($null -ne $ri3Total) { (($ri3Total / 36) * $instCount) + $licenseMo } else { $null }
            $ri1Pct = if ($null -ne $ri1Mo -and $payMo -gt 0) { [Math]::Round((1 - $ri1Mo / $payMo) * 100, 1) } else { $null }
            $ri3Pct = if ($null -ne $ri3Mo -and $payMo -gt 0) { [Math]::Round((1 - $ri3Mo / $payMo) * 100, 1) } else { $null }

            # Savings Plan (hourly -> monthly, scaled by InstanceCount)
            # Same OS-agnostic semantics as RI: SP discounts compute only; Windows
            # license premium added on top at PAYGO rates.
            $baseSp1 = if ($baseRiPayg) { $baseRiPayg.SP1Yr } else { $null }
            $baseSp3 = if ($baseRiPayg) { $baseRiPayg.SP3Yr } else { $null }
            $sp1Mo = if ($null -ne $baseSp1) { ($baseSp1 * $hoursPerMo * $instCount) + $licenseMo } else { $null }
            $sp3Mo = if ($null -ne $baseSp3) { ($baseSp3 * $hoursPerMo * $instCount) + $licenseMo } else { $null }
            $sp1Pct = if ($null -ne $sp1Mo -and $payMo -gt 0) { [Math]::Round((1 - $sp1Mo / $payMo) * 100, 1) } else { $null }
            $sp3Pct = if ($null -ne $sp3Mo -and $payMo -gt 0) { [Math]::Round((1 - $sp3Mo / $payMo) * 100, 1) } else { $null }
        }

        # Availability lookup (may be absent if -SkipAvailability or auth failed)
        $regionAccess = '?'
        $zonesStr     = '?'
        $regionBlocked = $false
        $reason       = ''
        if ($availOn -and $sub.Id) {
            $info = $availMap["$($sub.Id)|$region|$sku"]
            if ($info) {
                $regionBlocked = [bool]$info.RegionBlocked
                $reason        = [string]$info.Reason
                $regionAccess  = if ($regionBlocked) { 'RESTRICTED' } else { 'Allowed' }
                $zonesStr      = if ($regionBlocked)               { '-' }
                                 elseif ($info.Zones.Count -eq 0)  { 'N/A' }
                                 else { ($info.Zones -join ',') }
            } else {
                $regionAccess = 'not listed'
                $zonesStr     = 'not listed'
            }
        }

        $rowsBag.Add([pscustomobject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            Region          = $region
            VmSize          = $sku
            OS              = $os
            RegionAccess    = $regionAccess
            ZoneAccess      = $zonesStr
            RegionBlocked   = $regionBlocked
            RestrictReason  = $reason
            PAYGO_PerMonth  = if ($null -ne $payMo)  { [Math]::Round($payMo, 2) }  else { $null }
            Spot_PerMonth   = if ($null -ne $spotMo) { [Math]::Round($spotMo, 2) } else { $null }
            Spot_Saving_Pct = $spotPct
            RI_1Yr_PerMonth = if ($null -ne $ri1Mo) { [Math]::Round($ri1Mo, 2) } else { $null }
            RI_1Yr_Save_Pct = $ri1Pct
            RI_3Yr_PerMonth = if ($null -ne $ri3Mo) { [Math]::Round($ri3Mo, 2) } else { $null }
            RI_3Yr_Save_Pct = $ri3Pct
            SP_1Yr_PerMonth = if ($null -ne $sp1Mo) { [Math]::Round($sp1Mo, 2) } else { $null }
            SP_1Yr_Save_Pct = $sp1Pct
            SP_3Yr_PerMonth = if ($null -ne $sp3Mo) { [Math]::Round($sp3Mo, 2) } else { $null }
            SP_3Yr_Save_Pct = $sp3Pct
        })
      }
     }
    }
} -ThrottleLimit $ThrottleLimit

Write-Progress -Activity 'Querying regions' -Completed

# Input validation: any region that returned zero rows is a likely API failure.
# Note: actual unknown region names are pre-filtered upstream via Get-AzLocation
# when Az is available, so this primarily catches Retail-API outages or
# regions with no published VM pricing.
$regionsWithData = [System.Collections.Generic.HashSet[string]]::new()
$received        = [System.Collections.Generic.HashSet[string]]::new()
foreach ($r in $rows) {
    [void]$regionsWithData.Add($r.Region)
    [void]$received.Add("$($r.Region)|$($r.VmSize)")
}

$badRegions = @($Region | Where-Object { -not $regionsWithData.Contains($_) })
if ($badRegions) {
    Write-Warning "No data returned for region(s): $($badRegions -join ', ')"
}

# Remaining gaps = SKU missing in an otherwise-valid region.
# Distinguish two cases:
#   - SKU missing in EVERY valid region  -> likely a typo/unknown SKU name
#   - SKU missing in SOME valid regions  -> regional availability gap
$validRegionCount = $Region.Count - $badRegions.Count
$skuGaps = @{}
foreach ($r in $Region) {
    if ($badRegions -contains $r) { continue }
    foreach ($s in $VmSize) {
        if (-not $received.Contains("$r|$s")) {
            if (-not $skuGaps.ContainsKey($s)) { $skuGaps[$s] = [System.Collections.Generic.List[string]]::new() }
            $skuGaps[$s].Add($r)
        }
    }
}
foreach ($s in $skuGaps.Keys) {
    if ($skuGaps[$s].Count -eq $validRegionCount) {
        Write-Warning "Unknown SKU (not found in any queried region): $s"
    } else {
        Write-Warning "SKU not available in region(s): $s ($($skuGaps[$s] -join ', '))"
    }
}

# Commitment-pricing gaps: for each SKU present in the results, identify which
# commitment types (RI 1Yr/3Yr, SP 1Yr/3Yr) are missing across ALL of its rows.
# Some specialty SKUs (e.g. memory-optimized) don't have published RI pricing.
# RI/SP availability is OS-agnostic (the Retail API publishes one entry per
# SKU regardless of OS), so we group by VmSize only and emit a single warning.
# Skipped under -SkipPricing (no pricing data to check).
if (-not $SkipPricing) {
    $commitmentChecks = @(
        @{ Name = 'RI 1Yr'; Prop = 'RI_1Yr_PerMonth' }
        @{ Name = 'RI 3Yr'; Prop = 'RI_3Yr_PerMonth' }
        @{ Name = 'SP 1Yr'; Prop = 'SP_1Yr_PerMonth' }
        @{ Name = 'SP 3Yr'; Prop = 'SP_3Yr_PerMonth' }
    )
    $rowsBySku = $rows | Group-Object VmSize
    foreach ($g in $rowsBySku) {
        $missingTypes = foreach ($chk in $commitmentChecks) {
            $hasAny = $g.Group | Where-Object { $null -ne $_.($chk.Prop) }
            if (-not $hasAny) { $chk.Name }
        }
        if ($missingTypes) {
            Write-Warning "No commitment pricing published for $($g.Name): $($missingTypes -join ', ')"
        }
    }
}

$sorted = @($rows | Sort-Object SubscriptionName, Region, VmSize, OS)

if ($sorted.Count -eq 0) {
    Write-Host 'No pricing data returned. Check region names and SKU names (e.g. Standard_D2s_v5) and try again.' -ForegroundColor Red
} else {
    # Show sub columns when we have a real sub (resolved Az context or
    # explicit -Subscription). Skip them in the pricing-only fallback where no
    # sub identity was resolved, and always under -SkipAvailability (where
    # subscription scope is irrelevant and collapsed to a single row set).
    $showSubCols = (-not $SkipAvailability) -and (($subs.Count -gt 1) -or ($subs[0].Id -ne ''))
    $cols = @()
    if ($showSubCols) {
        $cols += @{n='SubscriptionName'; e={ $_.SubscriptionName }}
        $cols += @{n='SubscriptionId';   e={ $_.SubscriptionId }}
    }
    $cols += @('Region', 'VmSize')
    if ($IncludeWindows -and -not $SkipPricing) { $cols += @{n='OS'; e={ $_.OS }} }
    if (-not $SkipAvailability) {
        $cols += @{n='RegionAccess'; e={ $_.RegionAccess }}
        $cols += @{n='ZoneAccess';   e={ $_.ZoneAccess }}
    }
    if (-not $SkipPricing) {
        $cols += @(
            @{n=$(if ($ACD -gt 0) { "PAYGO/Mo(-$ACD%)" } else { 'PAYGO/Mo' }); e={ Format-Price $_.PAYGO_PerMonth }}
        )
        if ($IncludeSpot) {
            $cols += @{n='Spot/Mo'; e={ Format-Price $_.Spot_PerMonth }}
            $cols += @{n='Spot%';   e={ Format-Pct   $_.Spot_Saving_Pct }}
        }
        $cols += @(
            @{n='RI1Yr/Mo'; e={ Format-Price $_.RI_1Yr_PerMonth }},
            @{n='RI1Yr%';   e={ Format-Pct   $_.RI_1Yr_Save_Pct }},
            @{n='RI3Yr/Mo'; e={ Format-Price $_.RI_3Yr_PerMonth }},
            @{n='RI3Yr%';   e={ Format-Pct   $_.RI_3Yr_Save_Pct }},
            @{n='SP1Yr/Mo'; e={ Format-Price $_.SP_1Yr_PerMonth }},
            @{n='SP1Yr%';   e={ Format-Pct   $_.SP_1Yr_Save_Pct }},
            @{n='SP3Yr/Mo'; e={ Format-Price $_.SP_3Yr_PerMonth }},
            @{n='SP3Yr%';   e={ Format-Pct   $_.SP_3Yr_Save_Pct }}
        )
    }
    # Build the table manually so column rendering doesn't depend on terminal width.
    # Each $cols entry is either a string (property name) or a hashtable @{n;e}.
    $headers = foreach ($c in $cols) { if ($c -is [string]) { $c } else { $c.n } }
    $getCell = {
        param($row, $c)
        if ($c -is [string]) {
            $v = $row.$c; if ($null -eq $v) { '' } else { "$v" }
        } else {
            # Pipe through ForEach-Object so $_ is bound to $row inside $c.e
            $out = $row | ForEach-Object -Process $c.e
            if ($null -eq $out) { '' } else { "$out" }
        }
    }

    # Compute width per column = max(header, max cell value)
    $widths = @{}
    foreach ($h in $headers) { $widths[$h] = $h.Length }
    foreach ($row in $sorted) {
        for ($i = 0; $i -lt $cols.Count; $i++) {
            $val = (& $getCell $row $cols[$i])
            if ($val.Length -gt $widths[$headers[$i]]) { $widths[$headers[$i]] = $val.Length }
        }
    }

    $sep = '  '
    # Numeric columns (monthly costs and saving percentages) are right-aligned
    # so decimal points line up; text columns stay left-aligned.
    $isNumeric = { param($h) $h -match '/Mo|%$' }
    $headerLine = ($headers | ForEach-Object {
        if (& $isNumeric $_) { $_.PadLeft($widths[$_]) } else { $_.PadRight($widths[$_]) }
    }) -join $sep
    $underline  = ($headers | ForEach-Object {
        $dash = '-' * $_.Length
        if (& $isNumeric $_) { $dash.PadLeft($widths[$_]) } else { $dash.PadRight($widths[$_]) }
    }) -join $sep
    Write-Host $headerLine
    Write-Host $underline
    foreach ($row in $sorted) {
        $cells = for ($i = 0; $i -lt $cols.Count; $i++) {
            $h = $headers[$i]
            $v = (& $getCell $row $cols[$i])
            if (& $isNumeric $h) { $v.PadLeft($widths[$h]) } else { $v.PadRight($widths[$h]) }
        }
        Write-Host ($cells -join $sep)
    }
    Write-Host ''

    if (-not $SkipPricing) {
        Write-Host "  RI/Mo = total term lump-sum (retailPrice) / term months (12 or 36)" -ForegroundColor DarkGray
        Write-Host "  SP/Mo = Savings Plan hourly commitment * $HoursPerMonth" -ForegroundColor DarkGray
        Write-Host "  Save% = saving vs PAYGO monthly (positive = cheaper than PAYGO)" -ForegroundColor DarkGray
        Write-Host "  All amounts shown in $Currency." -ForegroundColor DarkGray
    }
}

if ($OutputCsv) {
    $sorted | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`n  Exported: $OutputCsv" -ForegroundColor Green
}

if ($PassThru) { $sorted }
