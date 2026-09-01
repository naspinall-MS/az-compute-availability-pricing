<#
.SYNOPSIS
    Reports Azure Virtual Machine SKU availability (regions, zones, subscription
    restrictions) alongside PAYGO, Spot, Reserved Instance, and Savings Plan
    monthly pricing.

.DESCRIPTION
    Two data sources:
      - Pricing:      Azure Retail Prices API (no auth required, public).
      - Availability: Microsoft.Compute/skus ARM REST endpoint (requires the
                      Az.Accounts module and a logged-in Azure context via
                      Connect-AzAccount for the bearer token). When unavailable,
                      the script still returns pricing data and the availability
                      columns show '?'.

    Availability info surfaces as three separate columns:
      - RegionAvailability: 'Available' (the SKU is listed/offered in the
        region) or 'Unavailable' (not listed); '?' when the lookup was skipped.
      - ZoneAvailability: the zones the SKU is offered in (e.g. "1,2,3"),
        'N/A' for a non-zonal region, 'Unavailable' when the SKU is not listed
        in the region, or '?'.
      - Restrictions: 'None', the restriction detail (e.g. "Region" for a
        subscription-level block, or "Zone 1,2,3" for blocked zones), or
        "VM size not available in region." when the SKU is not listed.
        A restriction means the capability exists (the size is offered) but is
        currently blocked for the subscription regionally and/or zonally; these
        are allowlist gates that require a support case to unblock - unlike
        'Unavailable', where the SKU simply isn't offered.

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
    RIs and Savings Plans discount the COMPUTE portion only - the OS license
    premium is never reduced by a commitment and bills at PAYGO rates. An ACD
    discount, if supplied, still applies to that license portion (because it
    bills at PAYGO), even though the RI/SP commitment does not. Reported Save%
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
    pay-as-you-go rate. It applies to the ENTIRE PAYGO rate, including the
    Windows license premium on Windows rows. RI and SP compute rates are NOT
    adjusted (those are already committed discounts), but the Windows license
    portion added on top of them bills at PAYGO, so ACD discounts it there too.
    Save% values are recalculated against the discounted PAYGO so commitment
    savings reflect your real baseline. Default 0 (list price).

    NOTE: This is a single flat discount applied uniformly to every PAYGO rate.
    It does NOT model SKU-level or product-specific negotiated discounts (e.g. a
    deeper discount on a specific VM family or region) that some customers have.
    Treat the discounted figures as an approximation and confirm SKU-specific
    pricing with your account team.

.PARAMETER InstanceCount
    Multiply all monthly cost columns by this count to project an N-instance
    deployment. Save% values are unaffected (a ratio). Default 1.

.PARAMETER OutputCsv
    Optional path to export results as a CSV file.

.PARAMETER SkipAvailability
    Skip the Microsoft.Compute/skus availability lookup even if Az.Accounts
    and an Azure context are available. Useful for faster pricing-only runs.

.PARAMETER SkipPricing
    Skip the Azure Retail Prices API queries. Produces an availability-only
    matrix (subscription, region, SKU + RegionAvailability/ZoneAvailability/
    Restrictions). All pricing columns (PAYGO, Spot, RI, SP) are omitted from
    output and CSV. Cannot be combined with -SkipAvailability.

.PARAMETER SubscriptionId
    One or more subscription IDs (GUIDs) to evaluate. SKU availability and
    restrictions are subscription-scoped, so each sub gets its own row. IDs are
    required (rather than display names) because names are not guaranteed unique
    across tenants. When omitted, the current Az context subscription is used.
    Pricing data is public (Retail API) and identical across subs, so it is
    queried once per region and reused.

.PARAMETER SubscriptionIdCsv
    Path to a CSV file listing subscription IDs (GUIDs) to evaluate. Values may
    be comma-separated on one line, one per line, or a mix, with or without a
    header row (a leading SubscriptionId/Subscription/Id header is ignored).
    Values are merged with any inline -SubscriptionId values and de-duplicated.

.PARAMETER Currency
    ISO currency code for pricing (e.g. USD, EUR, GBP, AUD). Passed to the Azure
    Retail Prices API. Default USD. All monetary columns are expressed in this
    currency.

.PARAMETER PassThru
    Emit the result rows as objects to the pipeline (in addition to the console
    table) so they can be filtered, sorted, or exported by the caller.

.PARAMETER ThrottleLimit
    Max parallel availability queries (per-region or per-subscription calls).
    Default 5. Backoff on HTTP 429/503 self-regulates the effective rate, so
    this can be raised for large multi-subscription runs.

.PARAMETER CollapseRegionThreshold
    Availability lookups query Microsoft.Compute/skus per (subscription x region)
    by default, which is fastest for a handful of regions. When the number of
    requested regions is >= this value, the script instead issues ONE unfiltered
    call per subscription (all regions) and filters client-side - trading a
    larger payload for far fewer calls, which avoids ARM read throttling when
    fanning out across many subscriptions. Default 8. Set very high to always
    use per-region calls, or to 1 to always collapse.

.EXAMPLE
    .\Get-ComputeAvailability.ps1 -Region australiaeast,eastus -VmSize Standard_D2s_v5,Standard_D4s_v5

.EXAMPLE
    .\Get-ComputeAvailability.ps1 -Region eastus -VmSize Standard_E8s_v5 -IncludeSpot -OutputCsv .\vm-prices.csv

.EXAMPLE
    .\Get-ComputeAvailability.ps1 -RegionCsv .\regions.csv -VmSizeCsv .\skus.csv -SubscriptionIdCsv .\subs.csv

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
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string[]]$SubscriptionId  = @(),
    [string]$SubscriptionIdCsv = '',
    [ValidateRange(1, [int]::MaxValue)]
    [int]$ThrottleLimit      = 5,
    [ValidateRange(1, [int]::MaxValue)]
    [int]$CollapseRegionThreshold = 8
)

Set-StrictMode -Version 1

$Currency = $Currency.ToUpperInvariant()

if ($SkipAvailability -and $SkipPricing) {
    throw 'Cannot specify both -SkipAvailability and -SkipPricing; at least one data source is required.'
}

# ----- CSV-sourced VM sizes / subscriptions --------------------------------
# Read SKU names and/or subscription identifiers from CSV files and merge them
# with any inline -VmSize / -SubscriptionId values. Values are trimmed, blanks
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
if ($SubscriptionIdCsv) {
    $csvSubs        = Import-CsvValues -Path $SubscriptionIdCsv -Header @('SubscriptionId','Subscription','Id')
    $SubscriptionId = @($SubscriptionId + $csvSubs | Where-Object { $_ } | Select-Object -Unique)
}

# Remove duplicate subscription IDs (case-insensitive) up front - Select-Object
# -Unique is case-SENSITIVE and inline -SubscriptionId values aren't otherwise
# de-duplicated, so repeated IDs would inflate the run-summary header and spawn
# duplicate availability work.
if ($SubscriptionId.Count -gt 1) {
    $seenSub        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $beforeSubCount = $SubscriptionId.Count
    $SubscriptionId = @($SubscriptionId | Where-Object { $_ -and $seenSub.Add($_.Trim()) } | ForEach-Object { $_.Trim() })
    $removedSubs    = $beforeSubCount - $SubscriptionId.Count
    if ($removedSubs -gt 0) {
        # Surface this so a bulk-list caller doesn't mistake collapsed duplicates
        # for "missing" output rows.
        Write-Host "Note: removed $removedSubs duplicate subscription ID(s)." -ForegroundColor Yellow
    }
}

# Remove duplicate VM sizes (case-insensitive) up front. Regions are already
# de-duplicated during region validation, but SKUs never were, so repeated
# -VmSize values would produce duplicate rows. First-seen casing is preserved
# because the ARM/Retail SKU filters are case-sensitive.
if ($VmSize.Count -gt 1) {
    $seenSku      = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $beforeSkuCnt = $VmSize.Count
    $VmSize       = @($VmSize | Where-Object { $_ -and $seenSku.Add($_.Trim()) } | ForEach-Object { $_.Trim() })
    $removedSkus  = $beforeSkuCnt - $VmSize.Count
    if ($removedSkus -gt 0) {
        Write-Host "Note: removed $removedSkus duplicate VM size(s)." -ForegroundColor Yellow
    }
}

# Remove duplicate regions (case-insensitive) up front. Region validation later
# normalizes survivors to Azure's canonical casing, but doing it here lets us
# report collapsed duplicates alongside subscriptions and VM sizes.
if ($Region.Count -gt 1) {
    $seenRegion  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $beforeRegCnt = $Region.Count
    $Region      = @($Region | Where-Object { $_ -and $seenRegion.Add($_.Trim()) } | ForEach-Object { $_.Trim() })
    $removedRegs = $beforeRegCnt - $Region.Count
    if ($removedRegs -gt 0) {
        Write-Host "Note: removed $removedRegs duplicate region(s)." -ForegroundColor Yellow
    }
}

if ($VmSize.Count -eq 0) {
    throw 'No VM sizes specified. Provide -VmSize and/or -VmSizeCsv.'
}
if ($Region.Count -eq 0) {
    throw 'No regions specified. Provide -Region and/or -RegionCsv.'
}

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

function Resolve-VmSizeExistence {
    # Region-agnostic existence probe: query the public Retail Prices API for the
    # given VM sizes with NO region filter. Any armSkuName that comes back is a
    # real Azure VM size (offered/priced somewhere), which lets callers tell a
    # genuine typo from a valid size that simply isn't in the selected regions.
    param(
        [Parameter(Mandatory)][string[]]$Sku,
        [Parameter(Mandatory)][string]$Currency
    )
    $existing = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    if ($Sku.Count -eq 0) { return $existing }
    $skuClause = ($Sku | ForEach-Object { "armSkuName eq '$_'" }) -join ' or '
    $filter    = "serviceName eq 'Virtual Machines' and priceType eq 'Consumption' and ($skuClause)"
    $uri       = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=$Currency&`$filter=$([Uri]::EscapeDataString($filter))"
    try {
        do {
            $page = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
            if ($page.Items) {
                foreach ($it in $page.Items) { [void]$existing.Add($it.armSkuName) }
            }
            $uri = if ($page.PSObject.Properties['NextPageLink'] -and $page.NextPageLink) { $page.NextPageLink } else { $null }
        } while ($uri)
    } catch {
        Write-Verbose "VM size existence probe failed: $($_.Exception.Message)"
    }
    # Unary comma keeps PowerShell from unrolling the set into the pipeline
    # (which would turn an empty set into $null and a populated one into a
    # bare string/array), so the caller always gets the HashSet object back.
    return ,$existing
}

function Test-RetailRegionHasVm {
    # Anonymous existence check: does this region publish ANY Virtual Machines
    # consumption pricing? Every real Azure region does; an invalid region name
    # returns nothing. Lets us tell a typo'd region from a valid region that
    # merely has no matching sizes, when Az-based region validation is
    # unavailable (e.g. signed out). On error we assume valid to avoid false
    # "invalid region" claims.
    param(
        [Parameter(Mandatory)][string]$Region,
        [Parameter(Mandatory)][string]$Currency
    )
    $filter = "serviceName eq 'Virtual Machines' and armRegionName eq '$Region' and priceType eq 'Consumption'"
    $uri    = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=$Currency&`$filter=$([Uri]::EscapeDataString($filter))"
    try {
        $page = Invoke-RestMethod -Uri $uri -Method Get -ErrorAction Stop
        return [bool]($page.Items -and $page.Items.Count -gt 0)
    } catch {
        Write-Verbose "Region existence probe failed for '$Region': $($_.Exception.Message)"
        return $true
    }
}

function Get-ArmAccessToken {
    # Returns a plain-string ARM bearer token, handling both the SecureString
    # (Az.Accounts >= 2.20) and legacy plain-string shapes. Interactive user
    # contexts refresh silently, so calling this again mid-run yields a fresh
    # token without re-prompting - which lets long, multi-thousand-subscription
    # runs outlive the ~60-90 min token lifetime.
    $tr = Get-AzAccessToken -ResourceUrl 'https://management.azure.com/' -ErrorAction Stop
    if ($tr.Token -is [System.Security.SecureString]) {
        [System.Net.NetworkCredential]::new('', $tr.Token).Password
    } else {
        [string]$tr.Token
    }
}

# ----- Subscription resolution + SKU availability lookup -------------------
# Resolve target subscriptions:
#   - If -SubscriptionId was supplied, look each up by Id (IDs are globally
#     unique, so this is unambiguous - unlike display names)
#   - Else use current Az context (or a single empty placeholder if Az is
#     unavailable, so the script still produces pricing-only rows)
# Each emitted row carries SubscriptionName/Id so multi-sub diffs are visible.
#
# Availability is the ONLY subscription-scoped data. When -SkipAvailability is
# set, pricing is identical across subscriptions, so any -SubscriptionId input is
# ignored and we collapse to a single subscription (current context, or a
# placeholder) to avoid emitting duplicate pricing rows.
$subs = [System.Collections.Generic.List[hashtable]]::new()
$azAvailable = $false
try {
    $null = Get-Command Get-AzContext -ErrorAction Stop
    $azAvailable = $true
} catch {
    Write-Verbose "Az.Accounts not available: $($_.Exception.Message)"
}

if ($SkipAvailability -and $SubscriptionId.Count -gt 0) {
    Write-Warning "-SubscriptionId is ignored with -SkipAvailability (subscription scope only affects availability); pricing is identical across subscriptions, so a single row set is produced."
}

if ($SubscriptionId.Count -gt 0 -and -not $SkipAvailability) {
    if (-not $azAvailable) {
        Write-Warning "-SubscriptionId specified but Az module not available. Install Az.Accounts and Connect-AzAccount."
    } else {
        foreach ($id in $SubscriptionId) {
            if ($subs | Where-Object { $_.Id -eq $id }) { continue }   # skip duplicate ids
            $resolved = $null
            try { $resolved = Get-AzSubscription -SubscriptionId $id -ErrorAction Stop }
            catch { Write-Verbose "No subscription matched by id '$id': $($_.Exception.Message)" }
            if ($resolved) {
                $subs.Add(@{ Name = $resolved.Name; Id = $resolved.Id })
            } else {
                Write-Warning "Subscription not found / not accessible: $id"
            }
        }
    }
}

if ($subs.Count -eq 0) {
    # Explicit -SubscriptionId was supplied but none resolved: never silently
    # fall back to the current context, which would attribute subscription-scoped
    # availability data to the wrong subscription. Fail loudly instead.
    if ($SubscriptionId.Count -gt 0 -and -not $SkipAvailability) {
        throw "None of the specified subscription IDs could be resolved or accessed: $($SubscriptionId -join ', '). Check the IDs and your Az login (Connect-AzAccount)."
    }
    # No -SubscriptionId specified: fall back to current context, or a single
    # empty placeholder (so pricing-only runs still produce rows).
    if ($azAvailable) {
        try {
            $ctx = Get-AzContext -ErrorAction Stop
            if ($ctx -and $ctx.Subscription) {
                $subs.Add(@{ Name = $ctx.Subscription.Name; Id = $ctx.Subscription.Id })
            }
        } catch {
            Write-Verbose "Could not read current Az context: $($_.Exception.Message)"
        }
    }
    if ($subs.Count -eq 0) { $subs.Add(@{ Name = ''; Id = '' }) }
}

# ----- Pre-flight: validate region names against Azure ---------------------
# Get-AzLocation returns regions the current context can see. Pruning invalid
# region names here avoids wasted Retail API calls and confusing downstream
# warnings. If Az is unavailable, this step is silently skipped and bad regions
# will surface later via empty Retail API results.
#
# $regionsValidated records whether we authoritatively confirmed the region
# names against the Azure catalog. Post-run diagnostics use it to decide whether
# an empty region means a bad region name or simply no matching VM sizes.
$regionsValidated = $false
if ($azAvailable -and ($subs[0].Id -ne '')) {
    # Fetch the region catalog on its own so a Get-AzLocation failure (e.g. the
    # known Az.Accounts "Value cannot be null. (Parameter 'g')" when the context
    # is in a bad state) degrades to a warning and skips validation, rather than
    # aborting the run. Bad region names then surface later as empty results.
    $validRegions = $null
    try {
        $validRegions = (Get-AzLocation -ErrorAction Stop).Location
    } catch {
        Write-Warning "Region validation skipped: $($_.Exception.Message)"
    }

    if ($validRegions) {
        # Build case-insensitive canonical-name map: input -> canonical
        $canonMap = [System.Collections.Generic.Dictionary[string,string]]::new(
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

        # Fatal only when the catalog loaded but pruned every requested region.
        if ($Region.Count -eq 0) {
            throw 'No valid regions remain after validation. Use Get-AzLocation to see available region names.'
        }
        $regionsValidated = $true
    }
}

# Availability map keyed "subId|region|sku" ->
#   @{ PhysicalZones; RegionBlocked; RegionReason; RestrictedZones; ZoneReason }
# Parallelized across (sub x region) work items via ARM REST. We acquire a
# single Bearer token up front and reuse it in every parallel runspace, which
# avoids per-sub Set-AzContext serialization and gives the same ThrottleLimit
# concurrency the pricing block enjoys.
$availMap        = @{}
$availAvailable  = $false
# Sub/region pairs whose availability lookup failed (e.g. 401). Rows for these
# render '?' (unknown) instead of a misleading 'Unavailable'. Defined at main
# scope so the pricing loop can consume it even when availability is skipped.
$availFailed        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
# Shown-once guard: the first 401 suggests Connect-AzAccount (likely a stale
# token); repeat 401s are treated as a genuine scope-authorization problem and
# do NOT re-suggest reconnecting.
$reconnectHintShown = $false
if (-not $SkipAvailability) {
    try {
        if (-not $azAvailable) { throw 'Az.Accounts not available; run Connect-AzAccount.' }
        $ctx = Get-AzContext -ErrorAction Stop
        if ($null -eq $ctx -or -not $ctx.Subscription) { throw 'No active Azure context.' }

        # Acquire the initial ARM token. On long multi-thousand-subscription
        # runs the token is refreshed between work chunks (below) so it can't
        # expire mid-run; interactive user contexts refresh silently.
        $armToken      = Get-ArmAccessToken
        $tokenAcquired = [datetime]::UtcNow

        # Decide the query shape (see -CollapseRegionThreshold):
        #   per-region -> one filtered call per (sub x region); small payloads,
        #                 fastest for a few regions.
        #   collapsed  -> one unfiltered call per sub (all regions), filtered
        #                 client-side; far fewer calls, best when many regions
        #                 are requested across many subscriptions.
        $collapseRegions = ($Region.Count -ge $CollapseRegionThreshold)
        if ($collapseRegions) {
            $workItems = @(foreach ($sub in $subs) {
                if (-not $sub.Id) { continue }
                @{ SubId = $sub.Id; SubName = $sub.Name; Region = $null }
            })
        } else {
            $workItems = @(foreach ($sub in $subs) {
                if (-not $sub.Id) { continue }   # placeholder sub, skip availability
                foreach ($r in $Region) {
                    @{ SubId = $sub.Id; SubName = $sub.Name; Region = $r }
                }
            })
        }

        if ($workItems.Count -gt 0) {
            $shapeDesc = if ($collapseRegions) {
                "$($workItems.Count) subscription(s), all regions per call"
            } else {
                "$($workItems.Count) subscription/region pair(s)"
            }
            Write-Progress -Activity 'SKU availability lookup' -Status "$shapeDesc..."
            $availResults  = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
            $availFailures = [System.Collections.Concurrent.ConcurrentBag[hashtable]]::new()
            $vmSizeSet     = [System.Collections.Generic.HashSet[string]]::new(
                [string[]]$VmSize, [System.StringComparer]::OrdinalIgnoreCase)
            $reqRegions    = [string[]]$Region

            # Process work in chunks so the ARM token can be refreshed between
            # chunks (guards against token expiry on long runs) without having
            # to share a mutable secret across parallel runspaces.
            $chunkSize          = [Math]::Max($ThrottleLimit * 20, 250)
            $refreshIntervalMin = 40
            $done               = 0
            for ($i = 0; $i -lt $workItems.Count; $i += $chunkSize) {
                if (([datetime]::UtcNow - $tokenAcquired).TotalMinutes -ge $refreshIntervalMin) {
                    try {
                        $armToken      = Get-ArmAccessToken
                        $tokenAcquired = [datetime]::UtcNow
                    } catch {
                        Write-Warning "ARM token refresh failed; continuing with the existing token: $($_.Exception.Message)"
                    }
                }
                $end   = [Math]::Min($i + $chunkSize - 1, $workItems.Count - 1)
                $chunk = @($workItems[$i..$end])

                $chunk | ForEach-Object -Parallel {
                    $item     = $_
                    $token    = $using:armToken
                    $skuSet   = $using:vmSizeSet
                    $bag      = $using:availResults
                    $failBag  = $using:availFailures
                    $reqRegs  = $using:reqRegions

                    if ($item.Region) {
                        $filter = "location eq '$($item.Region)'"
                        $uri    = "https://management.azure.com/subscriptions/$($item.SubId)/providers/Microsoft.Compute/skus?api-version=2021-07-01&`$filter=$([Uri]::EscapeDataString($filter))"
                    } else {
                        # Collapsed mode: all regions in one call, filter client-side.
                        $uri    = "https://management.azure.com/subscriptions/$($item.SubId)/providers/Microsoft.Compute/skus?api-version=2021-07-01"
                    }
                    $headers    = @{ Authorization = "Bearer $token" }
                    $allItems   = [System.Collections.Generic.List[object]]::new()
                    $maxRetries = 6
                    try {
                        do {
                            $attempt = 0
                            $resp    = $null
                            while ($true) {
                                try {
                                    $resp = Invoke-RestMethod -Uri $uri -Headers $headers -Method Get -ErrorAction Stop
                                    break
                                } catch {
                                    # Retry ARM throttling (429) and transient 503s
                                    # with exponential backoff + jitter, honoring a
                                    # Retry-After header when the service supplies one.
                                    $st = 0; $retryAfter = 0
                                    if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                                        $r = $_.Exception.Response
                                        try { $st = [int]$r.StatusCode } catch { $st = 0 }
                                        try {
                                            if ($r.Headers -and $r.Headers.RetryAfter) {
                                                $rc = $r.Headers.RetryAfter
                                                if ($rc.Delta -and $rc.Delta.HasValue) {
                                                    $retryAfter = [int]$rc.Delta.Value.TotalSeconds
                                                } elseif ($rc.Date -and $rc.Date.HasValue) {
                                                    $retryAfter = [int]($rc.Date.Value.UtcDateTime - [datetime]::UtcNow).TotalSeconds
                                                }
                                            }
                                        } catch { $retryAfter = 0 }
                                    }
                                    if (($st -eq 429 -or $st -eq 503) -and $attempt -lt $maxRetries) {
                                        $attempt++
                                        $delay = if ($retryAfter -gt 0) { [double]$retryAfter } else { [Math]::Min([Math]::Pow(2, $attempt), 30) }
                                        $delay += (Get-Random -Minimum 0 -Maximum 1000) / 1000.0
                                        Start-Sleep -Seconds $delay
                                        continue
                                    }
                                    throw
                                }
                            }
                            if ($resp.value) { $allItems.AddRange([object[]]$resp.value) }
                            $uri = if ($resp.PSObject.Properties['nextLink'] -and $resp.nextLink) { $resp.nextLink } else { $null }
                        } while ($uri)
                    } catch {
                        # Capture the HTTP status (if any) so the main thread can
                        # apply the reconnect-once rule; parallel runspaces can't
                        # coordinate a shared 'already warned' flag deterministically.
                        $status = 0
                        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
                            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
                        }
                        $failBag.Add(@{
                            SubId   = $item.SubId
                            SubName = $item.SubName
                            Region  = if ($item.Region) { $item.Region } else { '(all)' }
                            Status  = $status
                            Message = $_.Exception.Message
                        })
                        return
                    }

                    # Target regions for this response: the single filtered region,
                    # or the requested set (collapsed mode).
                    $targets = if ($item.Region) { @($item.Region) } else { $reqRegs }

                    foreach ($s in $allItems) {
                        if ($s.resourceType -ne 'virtualMachines') { continue }
                        if (-not $skuSet.Contains($s.name))        { continue }

                        foreach ($tRegion in $targets) {
                            # locationInfo entry for this region (a single SKU item
                            # can carry many regions in collapsed responses).
                            $li = $null
                            if ($s.locationInfo) {
                                foreach ($x in $s.locationInfo) {
                                    if ($x.location -and ($x.location -ieq $tRegion)) { $li = $x; break }
                                }
                            }
                            if (-not $li -and $item.Region -and $s.locationInfo) { $li = $s.locationInfo[0] }
                            # Not offered in this region -> nothing to record.
                            if (-not $li) { continue }

                            # Physical zones the SKU is offered in for this region
                            # (raw locationInfo, NOT reduced by restrictions).
                            $physicalZones = @()
                            if ($li.zones) { $physicalZones = @($li.zones | Sort-Object) }

                            # Restrictions are kept separate from physical
                            # availability and matched to THIS region (collapsed
                            # responses carry restrictions for many regions):
                            #   Location -> whole SKU unavailable to the sub here
                            #   Zone     -> specific zones unavailable to the sub
                            $regionBlocked   = $false
                            $regionReason    = ''
                            $restrictedZones = @()
                            $zoneReason      = ''
                            if ($s.restrictions) {
                                foreach ($rest in $s.restrictions) {
                                    $applies = $false
                                    if ($rest.restrictionInfo -and $rest.restrictionInfo.locations) {
                                        foreach ($rl in $rest.restrictionInfo.locations) {
                                            if ($rl -ieq $tRegion) { $applies = $true; break }
                                        }
                                    } elseif ($rest.PSObject.Properties['values'] -and $rest.values) {
                                        foreach ($rv in $rest.values) {
                                            if ($rv -ieq $tRegion) { $applies = $true; break }
                                        }
                                    } elseif ($item.Region) {
                                        # Region-filtered response: the restriction
                                        # is already scoped to the queried region.
                                        $applies = $true
                                    }
                                    if (-not $applies) { continue }
                                    switch ($rest.type) {
                                        'Location' {
                                            $regionBlocked = $true
                                            if ($rest.reasonCode) { $regionReason = $rest.reasonCode }
                                        }
                                        'Zone'     {
                                            if ($rest.restrictionInfo -and $rest.restrictionInfo.zones) {
                                                $restrictedZones += @($rest.restrictionInfo.zones)
                                            }
                                            if ($rest.reasonCode) { $zoneReason = $rest.reasonCode }
                                        }
                                    }
                                }
                            }
                            $restrictedZones = @($restrictedZones | Sort-Object -Unique)
                            $bag.Add(@{
                                Key             = "$($item.SubId)|$tRegion|$($s.name)"
                                PhysicalZones   = $physicalZones
                                RegionBlocked   = $regionBlocked
                                RegionReason    = $regionReason
                                RestrictedZones = $restrictedZones
                                ZoneReason      = $zoneReason
                            })
                        }
                    }
                } -ThrottleLimit $ThrottleLimit

                $done += $chunk.Count
                Write-Progress -Activity 'SKU availability lookup' `
                    -Status "$done / $($workItems.Count) processed" `
                    -PercentComplete ([Math]::Min(100, [int](100 * $done / $workItems.Count)))
            }

            foreach ($entry in $availResults) {
                $availMap[$entry.Key] = @{
                    PhysicalZones   = $entry.PhysicalZones
                    RegionBlocked   = $entry.RegionBlocked
                    RegionReason    = $entry.RegionReason
                    RestrictedZones = $entry.RestrictedZones
                    ZoneReason      = $entry.ZoneReason
                }
            }

            # Surface lookup failures from the main thread so the reconnect hint
            # fires only on the first 401. Every failed pair is recorded so its
            # rows render '?' rather than a false 'Unavailable'.
            foreach ($f in $availFailures) { [void]$availFailed.Add("$($f.SubId)|$($f.Region)") }
            if ($availFailures.Count -gt 0) {
                $auth401 = @($availFailures | Where-Object { $_.Status -eq 401 })
                $other   = @($availFailures | Where-Object { $_.Status -ne 401 })
                foreach ($f in $auth401) {
                    $scope = "sub: $($f.SubName), region: $($f.Region)"
                    if (-not $reconnectHintShown) {
                        Write-Warning "Availability lookup returned 401 Unauthorized ($scope). Your Azure token may be stale - run Connect-AzAccount to refresh, then retry."
                        $reconnectHintShown = $true
                    } else {
                        Write-Warning "Availability lookup returned 401 Unauthorized ($scope) - your account is not authorized for this scope; skipping."
                    }
                }
                foreach ($f in $other) {
                    Write-Warning "Availability lookup failed (sub: $($f.SubName), region: $($f.Region)): $($f.Message)"
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
# (armSkuName eq 'standard_d2s_v5' returns zero rows), so a valid size typed in
# the wrong case would silently return no pricing. Normalize user input to
# canonical case from the best source available, in order:
#   1. ARM availability data we already fetched (free);
#   2. a one-shot ARM catalog call (needs a usable Azure context);
#   3. the ANONYMOUS Retail catalog (works signed-out, so casing is fixed even
#      with no Azure login / a broken token).
$skuCanonMap = [System.Collections.Generic.Dictionary[string,string]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)

# 1. From ARM availability data.
if ($availMap.Count -gt 0) {
    foreach ($key in $availMap.Keys) {
        $name = $key.Split('|', 3)[2]
        if (-not $skuCanonMap.ContainsKey($name)) { $skuCanonMap[$name] = $name }
    }
}

# 2. One-shot ARM catalog call (requires a usable Azure context).
if ($skuCanonMap.Count -eq 0 -and -not $SkipPricing -and $azAvailable -and ($subs[0].Id -ne '')) {
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
        $status = 0
        if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) {
            try { $status = [int]$_.Exception.Response.StatusCode } catch { $status = 0 }
        }
        if ($status -eq 401) {
            if (-not $reconnectHintShown) {
                Write-Warning "SKU name canonicalization returned 401 Unauthorized. Your Azure token may be stale - run Connect-AzAccount to refresh, then retry."
                $reconnectHintShown = $true
            } else {
                Write-Warning "SKU name canonicalization returned 401 Unauthorized - your account is not authorized for this scope; skipping."
            }
        } else {
            Write-Warning "SKU name canonicalization skipped: $($_.Exception.Message)"
        }
    }
}

# 3. Anonymous Retail catalog fallback (no Azure login required). Pull the VM
#    consumption catalog for the first region that returns data and use it to
#    fix casing. Bounded page count so a bad filter can't loop unbounded.
if ($skuCanonMap.Count -eq 0 -and -not $SkipPricing) {
    foreach ($probeRegion in $Region) {
        try {
            $catFilter = "serviceName eq 'Virtual Machines' and armRegionName eq '$probeRegion' and priceType eq 'Consumption'"
            $catUri    = "https://prices.azure.com/api/retail/prices?api-version=2023-01-01-preview&currencyCode=$Currency&`$filter=$([Uri]::EscapeDataString($catFilter))"
            $catPages  = 0
            do {
                $catPage = Invoke-RestMethod -Uri $catUri -Method Get -ErrorAction Stop
                if ($catPage.Items) {
                    foreach ($ci in $catPage.Items) {
                        if ($ci.armSkuName -and -not $skuCanonMap.ContainsKey($ci.armSkuName)) {
                            $skuCanonMap[$ci.armSkuName] = $ci.armSkuName
                        }
                    }
                }
                $catUri = if ($catPage.PSObject.Properties['NextPageLink'] -and $catPage.NextPageLink) { $catPage.NextPageLink } else { $null }
                $catPages++
            } while ($catUri -and $catPages -lt 25)
        } catch {
            Write-Warning "SKU name canonicalization skipped (Retail catalog for '$probeRegion'): $($_.Exception.Message)"
        }
        if ($skuCanonMap.Count -gt 0) { break }
    }
}

# Apply canonical casing to the requested sizes.
if ($skuCanonMap.Count -gt 0) {
    $VmSize = @($VmSize | ForEach-Object {
        if ($skuCanonMap.ContainsKey($_)) { $skuCanonMap[$_] } else { $_ }
    })
}

# ----- Run summary header --------------------------------------------------
# Printed here (after region validation + SKU canonicalization) so the Regions
# and VM Sizes lines reflect the normalized/canonical casing actually queried,
# not the raw case the caller typed.
Write-Host ''
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host '  Azure Virtual Machine Availability + Price Comparison' -ForegroundColor Cyan
Write-Host "  Regions        : $($Region -join ', ')" -ForegroundColor Cyan
Write-Host "  VM Sizes       : $($VmSize -join ', ')" -ForegroundColor Cyan
if ($SubscriptionId -and -not $SkipAvailability) {
    # Long subscription lists (dozens+) would swamp the header, so show only the
    # first few and summarize the remainder with a count.
    $subPreviewMax = 5
    if ($SubscriptionId.Count -le $subPreviewMax) {
        Write-Host "  Subscriptions  : $($SubscriptionId -join ', ')" -ForegroundColor Cyan
    } else {
        $shown  = ($SubscriptionId | Select-Object -First $subPreviewMax) -join ', '
        $more   = $SubscriptionId.Count - $subPreviewMax
        Write-Host "  Subscriptions  : $shown, ... (+$more more; $($SubscriptionId.Count) total)" -ForegroundColor Cyan
    }
}
# Spot / license / hours / discount / instance options only affect pricing
# output; hide the whole group when pricing is skipped.
if (-not $SkipPricing) {
    Write-Host "  Spot           : $(if ($IncludeSpot) { 'included' } else { 'excluded' })" -ForegroundColor Cyan
    Write-Host "  WindowsLicense : $(if ($IncludeWindows) { 'included (license bundled)' } else { 'excluded' })" -ForegroundColor Cyan
    Write-Host "  Hours/Mo       : $HoursPerMonth" -ForegroundColor Cyan
    Write-Host "  Currency       : $Currency" -ForegroundColor Cyan
    if ($ACD -gt 0) { Write-Host "  ACD            : -$ACD% applied to PAYGO" -ForegroundColor Cyan }
    if ($InstanceCount -gt 1) { Write-Host "  Instances      : x$InstanceCount" -ForegroundColor Cyan }
}
# Run-mode status is unrelated to the pricing inputs above; keep it at the bottom.
if ($SkipPricing)      { Write-Host '  Pricing        : skipped (availability-only)' -ForegroundColor Cyan }
if ($SkipAvailability) { Write-Host '  Availability   : skipped (pricing-only)' -ForegroundColor Cyan }
# Licensing NOTE sits below the main block so the run summary stays compact.
if (-not $SkipPricing) {
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
Write-Host '================================================================' -ForegroundColor Cyan
Write-Host ''

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
    $availFailedSet = $using:availFailed
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
            # Linux product line). A commitment discounts COMPUTE ONLY - the Windows
            # license premium is never reduced by RI/SP and bills at PAYGO. So for
            # Windows rows we reuse the Linux RI/SP compute rate and add the Windows
            # license delta (= Windows_PAYGO - Linux_PAYGO) on top. That license
            # portion bills at PAYGO, so ACD (a PAYGO discount) DOES apply to it,
            # even though the RI/SP commitment does not.
            $baseRiPayg = if ($os -eq 'Windows') { $consIndex["$sku|Linux|PAYGO"] } else { $payg }
            $ri1Total   = $riIndex["$sku|Linux|1 Year"]
            $ri3Total   = $riIndex["$sku|Linux|3 Years"]
            $licenseDeltaHr = if ($os -eq 'Windows' -and $baseRiPayg) { $payg.Rate - $baseRiPayg.Rate } else { 0 }
            $licenseMo      = $licenseDeltaHr * $hoursPerMo * $acdMult * $instCount   # license bills at PAYGO; ACD applies, RI/SP do not

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
        $regionAvail   = '?'
        $zoneAvail     = '?'
        $restriction   = '?'
        $regionBlocked = $false
        if ($availOn -and $sub.Id) {
          if ($availFailedSet.Contains("$($sub.Id)|$region")) {
            # The availability lookup for this subscription/region failed (e.g.
            # 401 Unauthorized), so we genuinely don't know - report unknown ('?')
            # rather than asserting a false 'Unavailable'.
            $regionAvail = '?'
            $zoneAvail   = '?'
            $restriction = 'Availability lookup failed.'
          } else {
            $info = $availMap["$($sub.Id)|$region|$sku"]
            if ($info) {
                # Column 1: the SKU is listed (offered) in the region.
                $regionAvail   = 'Available'
                $regionBlocked = [bool]$info.RegionBlocked

                # Column 2: zones the SKU is physically present in (unreduced).
                $zoneAvail     = if ($info.PhysicalZones.Count -eq 0) { 'N/A' }
                                 else { ($info.PhysicalZones -join ',') }

                # Column 3: restriction detail (region and/or zone).
                $parts = @()
                if ($regionBlocked) {
                    $parts += 'Region'
                }
                if ($info.RestrictedZones.Count -gt 0) {
                    $parts += "Zone $($info.RestrictedZones -join ',')"
                }
                $restriction = if ($parts.Count -gt 0) { $parts -join '; ' } else { 'None' }
            } else {
                # SKU is not listed (offered) in the region for this subscription.
                $regionAvail = 'Unavailable'
                $zoneAvail   = 'Unavailable'
                $restriction = 'VM size not available in region.'
            }
          }
        }

        $rowsBag.Add([pscustomobject]@{
            SubscriptionName = $sub.Name
            SubscriptionId   = $sub.Id
            Region          = $region
            VmSize          = $sku
            RegionAvailability = $regionAvail
            ZoneAvailability   = $zoneAvail
            Restrictions       = $restriction
            RegionBlocked      = $regionBlocked
            OS              = $os
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

# ----- Post-run diagnostics: region + VM size coverage ---------------------
# Index what actually came back so we can explain any gaps precisely.
$regionsWithData = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$received        = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($r in $rows) {
    [void]$regionsWithData.Add($r.Region)
    [void]$received.Add("$($r.Region)|$($r.VmSize)")
}

# Region-level "no data" is only actionable when we could NOT pre-validate the
# region names. When regions were validated against the Azure catalog, an empty
# region just means none of the requested VM sizes matched there - which the
# VM-size diagnostics below explain - so we don't blame the (valid) region.
if ($regionsValidated) {
    # Names already confirmed against the Azure catalog upstream.
    $badRegions = @()
} else {
    # Az validation was unavailable (e.g. signed out). A no-data region is
    # either an invalid name or a valid region whose requested sizes aren't
    # offered. Use the anonymous Retail catalog to tell them apart, and only
    # exclude genuinely-invalid names - valid-but-empty regions stay in the set
    # so the VM-size diagnostics below can explain them instead of blaming the
    # region.
    $noDataRegions = @($Region | Where-Object { -not $regionsWithData.Contains($_) })
    $badRegions    = @($noDataRegions | Where-Object { -not (Test-RetailRegionHasVm -Region $_ -Currency $Currency) })
    if ($badRegions) {
        Write-Warning "Unknown or invalid region name(s): $($badRegions -join ', ')"
    }
}

# Regions we actually queried and trust (drop any flagged as bad above).
$queryRegions = @($Region | Where-Object { $_ -notin $badRegions })

# For each requested VM size, list the queried regions it is MISSING from.
$skuMissingIn = @{}
foreach ($s in $VmSize) {
    $missing = @($queryRegions | Where-Object { -not $received.Contains("$_|$s") })
    if ($missing.Count -gt 0) { $skuMissingIn[$s] = $missing }
}

# ARM subscription-level availability (Microsoft.Compute/skus) is authoritative
# for whether a size is REAL, independent of Retail pricing. Brand-new / preview
# SKUs are often offered (and visible here) before their pricing meters
# propagate to the Retail API, so this map rescues them from being mislabeled as
# typos. Keyed sku -> set of queried regions where ARM reports it. Empty under
# -SkipAvailability (no ARM lookup ran).
$availSkuRegions = [System.Collections.Generic.Dictionary[string,System.Collections.Generic.HashSet[string]]]::new(
    [System.StringComparer]::OrdinalIgnoreCase)
foreach ($k in $availMap.Keys) {
    $parts = $k.Split('|', 3)
    if ($parts.Count -lt 3) { continue }
    $kRegion = $parts[1]; $kSku = $parts[2]
    if (-not $availSkuRegions.ContainsKey($kSku)) {
        $availSkuRegions[$kSku] = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
    }
    [void]$availSkuRegions[$kSku].Add($kRegion)
}

# VM sizes absent from EVERY queried region are ambiguous: a genuine typo, or a
# real size that simply isn't offered in the chosen regions (e.g. a specialty
# GPU SKU that only lives in hero regions). Disambiguate with a region-agnostic
# Retail existence probe so we report the right thing. Only meaningful in
# pricing mode - an availability-only run already shows 'Unavailable' per region.
$noDataSkus = @($skuMissingIn.Keys | Where-Object {
    $queryRegions.Count -gt 0 -and $skuMissingIn[$_].Count -eq $queryRegions.Count })
$existsGlobally = if ($noDataSkus.Count -gt 0 -and -not $SkipPricing) {
    Resolve-VmSizeExistence -Sku $noDataSkus -Currency $Currency
} else {
    [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
}

$unknownSkus = [System.Collections.Generic.List[string]]::new()
foreach ($s in $VmSize) {
    if (-not $skuMissingIn.ContainsKey($s)) { continue }   # present in every queried region
    $missing = $skuMissingIn[$s]
    if ($queryRegions.Count -gt 0 -and $missing.Count -eq $queryRegions.Count) {
        # Missing everywhere we queried. Rank the evidence: ARM availability is
        # the strongest signal a size is real (covers new/preview SKUs whose
        # pricing meters haven't propagated), then a global Retail hit, then typo.
        $availHere = if ($availSkuRegions.ContainsKey($s)) {
            @($queryRegions | Where-Object { $availSkuRegions[$s].Contains($_) })
        } else { @() }

        if ($availHere.Count -gt 0) {
            Write-Warning "VM size '$s' is available in region(s): $($availHere -join ', ') but has no published pricing yet - likely a new/preview SKU whose meters have not propagated to the Retail API."
        } elseif ($existsGlobally.Contains($s)) {
            Write-Warning "VM size '$s' is a valid Azure size but is not offered in the selected region(s): $($missing -join ', '). Pick a region where it is available."
        } elseif ($availSkuRegions.ContainsKey($s)) {
            # ARM knows the size but not in the specific queried regions - still real, not a typo.
            Write-Warning "VM size '$s' is a valid Azure size but is not offered / priced in the selected region(s): $($missing -join ', ')."
        } elseif (-not $SkipPricing) {
            Write-Warning "Unknown VM size (not found in the Azure retail catalog): $s - check for typos (e.g. Standard_D2s_v5)."
            $unknownSkus.Add($s)
        } else {
            Write-Warning "VM size '$s' returned no availability data in the selected region(s): $($missing -join ', ')."
        }
    } else {
        # Present in some regions, missing in others: a regional availability gap.
        Write-Warning "VM size '$s' not offered in region(s): $($missing -join ', ')"
    }
}

# Mirror the all-regions-invalid behavior: if EVERY requested VM size is an
# unknown name, stop hard rather than exiting quietly with an empty table.
if ($queryRegions.Count -gt 0 -and $VmSize.Count -gt 0 -and $unknownSkus.Count -eq $VmSize.Count) {
    throw "None of the specified VM sizes are valid Azure VM size names: $($unknownSkus -join ', '). Check for typos (e.g. Standard_D2s_v5)."
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

# Show sub columns when we have a real sub (resolved Az context or explicit
# -SubscriptionId). Skip them in the pricing-only fallback where no sub identity
# was resolved, and always under -SkipAvailability (where subscription scope is
# irrelevant and collapsed to a single row set).
$showSubCols = (-not $SkipAvailability) -and (($subs.Count -gt 1) -or ($subs[0].Id -ne ''))

# Property list for the CSV export - kept in lock-step with the console columns
# below so the file only contains fields the user actually sees (raw values,
# not the display-formatted strings). OS is grouped with the pricing fields.
$csvProps = @()
if ($showSubCols) { $csvProps += 'SubscriptionName', 'SubscriptionId' }
$csvProps += 'Region', 'VmSize'
if (-not $SkipAvailability) {
    $csvProps += 'RegionAvailability', 'ZoneAvailability', 'Restrictions'
}
if (-not $SkipPricing) {
    if ($IncludeWindows) { $csvProps += 'OS' }
    $csvProps += 'PAYGO_PerMonth'
    if ($IncludeSpot) { $csvProps += 'Spot_PerMonth', 'Spot_Saving_Pct' }
    $csvProps += 'RI_1Yr_PerMonth', 'RI_1Yr_Save_Pct',
                 'RI_3Yr_PerMonth', 'RI_3Yr_Save_Pct',
                 'SP_1Yr_PerMonth', 'SP_1Yr_Save_Pct',
                 'SP_3Yr_PerMonth', 'SP_3Yr_Save_Pct'
    # Run-level pricing context - not shown as table columns, but captured in the
    # CSV so the export is self-describing (currency, whether spot/Windows-license
    # figures were requested, and the hours/month used for Savings Plan math).
    $csvProps += @{Name='Currency';               Expression={ $Currency }},
                 @{Name='SpotIncluded';           Expression={ [bool]$IncludeSpot }},
                 @{Name='WindowsLicenseIncluded'; Expression={ [bool]$IncludeWindows }},
                 @{Name='HoursPerMonth';          Expression={ $HoursPerMonth }}
}

if ($sorted.Count -eq 0) {
    Write-Host 'No pricing data returned. Check region names and SKU names (e.g. Standard_D2s_v5) and try again.' -ForegroundColor Red
} else {
    # Show sub columns when we have a real sub (resolved Az context or
    # explicit -SubscriptionId). Skip them in the pricing-only fallback where no
    # sub identity was resolved, and always under -SkipAvailability (where
    # subscription scope is irrelevant and collapsed to a single row set).
    $cols = @()
    if ($showSubCols) {
        $cols += @{n='SubscriptionName'; e={ $_.SubscriptionName }}
        $cols += @{n='SubscriptionId';   e={ $_.SubscriptionId }}
    }
    $cols += @('Region', 'VmSize')
    if (-not $SkipAvailability) {
        $cols += @{n='RegionAvailability'; e={ $_.RegionAvailability }}
        $cols += @{n='ZoneAvailability';   e={ $_.ZoneAvailability }}
        $cols += @{n='Restrictions';       e={ $_.Restrictions }}
    }
    if (-not $SkipPricing) {
        if ($IncludeWindows) { $cols += @{n='OS'; e={ $_.OS }} }
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
    $sorted | Select-Object $csvProps | Export-Csv -Path $OutputCsv -NoTypeInformation -Encoding UTF8
    Write-Host "`n  Exported: $OutputCsv" -ForegroundColor Green
}

if ($PassThru) { $sorted }
