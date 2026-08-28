# Get-ComputeAvailability

> **Disclaimer:** This script was created in my personal time and is provided as-is, without
> warranty of any kind. It is not an official Microsoft product and does not represent
> the views or recommendations of Microsoft. Use it at your own discretion.

A PowerShell script that reports Azure Virtual Machine SKU **availability**
(regions, zones, and subscription-level restrictions) alongside **monthly
pricing** across PAYGO, Spot, Reserved Instance, and Savings Plan options, for
one or more subscriptions, regions, and VM sizes.

## What it reports

| Dimension | Detail | Data source |
|---|---|---|
| Region availability | `Available` (SKU listed/offered in the region) or `Unavailable` (not listed) | `Microsoft.Compute/skus` (ARM) |
| Zone availability | Zones the SKU is offered in (e.g. `1,2,3`), `N/A` (non-zonal), or `Unavailable` (not listed) | `Microsoft.Compute/skus` (ARM) |
| Restrictions | Region/zone restriction detail (`Region` and/or `Zone 1,2,3`) — the size is offered but blocked for your subscription; needs a support case | `Microsoft.Compute/skus` (ARM) |
| PAYGO | Pay-as-you-go monthly compute cost | Azure Retail Prices API |
| Spot | Current published Spot monthly rate + saving vs PAYGO | Azure Retail Prices API |
| Reserved Instance | 1-year and 3-year monthly cost + saving vs PAYGO | Azure Retail Prices API |
| Savings Plan | 1-year and 3-year monthly cost + saving vs PAYGO | Azure Retail Prices API |

> **Note:** Pricing is **Linux compute** by default. SQL / Red Hat / other ISV
> license premiums are never included. Pass `-IncludeWindows` to add Windows
> rows (which bundle the Windows Server license premium). Reserved Instances and
> Savings Plans only discount the **compute** portion — the OS license is always
> billed at PAYGO rates.

## How the two data sources combine

- **Pricing** comes from the **Azure Retail Prices API** — public, no auth
  required. Prices are identical across subscriptions, so each region is queried
  once and reused.
- **Availability** comes from **`Microsoft.Compute/skus`** via ARM REST, which
  requires an authenticated Azure context (`Connect-AzAccount`). Because SKU
  restrictions are subscription-scoped, each subscription is queried separately.

If the availability lookup is unavailable (no Az context, or `-SkipAvailability`),
the script still returns pricing data and the availability columns show `?`.

### Availability vs. restrictions

These two concepts are reported separately and mean different things:

- **Availability** (`RegionAvailability` / `ZoneAvailability` = `Available`)
  means the VM size is **present** — Azure offers (lists) the SKU in that
  region/zone. `Unavailable` means the SKU simply isn't offered there and no
  action will change that (you must pick a different region or VM size).
- **Restrictions** means the capability **exists** but is currently **blocked**
  for your subscription (regionally and/or zonally). These are allowlist gates
  which require a support case to unblock. Note this is about whether the size
  is *offered* to you — it does not guarantee underlying capacity (a region/zone and VM combination
  may still be out of capacity at allocation time).

## Requirements

- **PowerShell 7.0** or later
- **Az.Accounts** module (only needed for availability lookups and region/SKU validation)

```powershell
Install-Module Az.Accounts -Scope CurrentUser
```

- An authenticated Azure session with at least **Reader** access on the target
  subscriptions (for availability). Pricing works with **no** authentication.

```powershell
Connect-AzAccount
```

## Usage

At least one VM size and one region are required (supplied inline and/or via
CSV); all other parameters are optional.

```powershell
.\Get-ComputeAvailability.ps1 -VmSize <string[]> -Region <string[]> `
    [-VmSizeCsv <string>] [-RegionCsv <string>] [-SubscriptionIdCsv <string>] `
    [-IncludeSpot] [-IncludeWindows] [-HoursPerMonth <int>] [-ACD <double>] `
    [-InstanceCount <int>] [-Currency <string>] [-OutputCsv <string>] [-PassThru] `
    [-SkipAvailability] [-SkipPricing] [-SubscriptionId <string[]>] [-ThrottleLimit <int>]
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-VmSize` | `string[]` | One or more ARM SKU names (e.g. `Standard_D2s_v5`, `Standard_E4s_v5`). Case is normalized automatically. Optional when `-VmSizeCsv` is supplied. |
| `-VmSizeCsv` | `string` | Path to a CSV file of VM SKU names. Values may be comma-separated on one line, one per line, or a mix, with or without a header row (a leading `VmSize`/`SKU`/`Size`/`Name` header is ignored). Merged with any inline `-VmSize` values. |
| `-Region` | `string[]` | One or more ARM region names (e.g. `australiaeast`, `northeurope`, `eastus`). Invalid names are pruned when Az is available. Optional when `-RegionCsv` is supplied. |
| `-RegionCsv` | `string` | Path to a CSV file of ARM region names. Values may be comma-separated on one line, one per line, or a mix, with or without a header row (a leading `Region`/`Location`/`Name` header is ignored). Merged with any inline `-Region` values. |
| `-IncludeSpot` | `switch` | Include Spot pricing. Spot is highly variable; the API returns the current published rate at query time. |
| `-IncludeWindows` | `switch` | Add Windows-licensed rows alongside Linux. Windows rows bundle the Windows Server license premium (not discounted by RI/SP). |
| `-HoursPerMonth` | `int` | Hours used to project hourly rates into monthly costs. Default `730` (Azure billing convention: 365.25 × 24 / 12). |
| `-ACD` | `double` | All-up customer discount percentage (0–100) applied to the PAYGO rate to reflect EA/MCA negotiated pricing. Applies to the entire PAYGO rate, including the Windows license premium. RI/SP compute rates are unchanged, but because the Windows license bills at PAYGO, ACD discounts it there too; Save% is recalculated against the discounted baseline. Default `0`. **Note:** this is a single flat discount applied uniformly — it does not model SKU-level or product-specific negotiated discounts (see [Notes & caveats](#notes--caveats)). |
| `-InstanceCount` | `int` | Multiply all monthly cost columns by this count to project an N-instance deployment. Save% is unaffected. Default `1`. |
| `-Currency` | `string` | ISO currency code (e.g. `USD`, `EUR`, `GBP`, `AUD`) passed to the Retail Prices API. All monetary columns are expressed in this currency. Default `USD`. |
| `-OutputCsv` | `string` | Optional path to export results as a CSV file. |
| `-PassThru` | `switch` | Also emit the result rows as objects to the pipeline (in addition to the console table) for further filtering, sorting, or exporting. |
| `-SkipAvailability` | `switch` | Skip the `Microsoft.Compute/skus` lookup for a faster pricing-only run. |
| `-SkipPricing` | `switch` | Skip the Retail Prices API for an availability-only matrix. Cannot be combined with `-SkipAvailability`. |
| `-SubscriptionId` | `string[]` | One or more subscription IDs (GUIDs). Each gets its own rows (availability is subscription-scoped). IDs are required rather than display names, which aren't guaranteed unique. Defaults to the current Az context. |
| `-SubscriptionIdCsv` | `string` | Path to a CSV file of subscription IDs (GUIDs). Values may be comma-separated on one line, one per line, or a mix, with or without a header row (a leading `SubscriptionId`/`Subscription`/`Id` header is ignored). Merged with any inline `-SubscriptionId` values. |
| `-ThrottleLimit` | `int` | Max parallel region/subscription queries. Default `5`. |

### Examples

```powershell
# Two regions, two SKUs — availability + Linux pricing
.\Get-ComputeAvailability.ps1 -Region australiaeast,eastus -VmSize Standard_D2s_v5,Standard_D4s_v5

# Single region + SKU with Spot pricing, exported to CSV
.\Get-ComputeAvailability.ps1 -Region eastus -VmSize Standard_E8s_v5 -IncludeSpot -OutputCsv .\vm-prices.csv

# Add Windows-licensed rows alongside Linux
.\Get-ComputeAvailability.ps1 -Region westeurope -VmSize Standard_D4s_v5 -IncludeWindows

# Apply a negotiated 15% discount and project a 10-instance deployment
.\Get-ComputeAvailability.ps1 -Region eastus -VmSize Standard_D8s_v5 -ACD 15 -InstanceCount 10

# Availability-only matrix across multiple subscriptions (no pricing)
.\Get-ComputeAvailability.ps1 -Region eastus,westus2 -VmSize Standard_D2s_v5 `
    -SubscriptionId '11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222' -SkipPricing

# Fast pricing-only run (skip the ARM availability lookup)
.\Get-ComputeAvailability.ps1 -Region eastus -VmSize Standard_D2s_v5 -SkipAvailability

# Read regions, SKUs, and subscription IDs from CSV files (merged with any inline values)
.\Get-ComputeAvailability.ps1 -RegionCsv .\regions.csv -VmSizeCsv .\skus.csv -SubscriptionIdCsv .\subs.csv

# Price in euros and pipe the objects on for further filtering
.\Get-ComputeAvailability.ps1 -Region westeurope -VmSize Standard_D2s_v5 -Currency EUR -PassThru |
    Where-Object RI_3Yr_Save_Pct -gt 40 | Sort-Object RI_3Yr_PerMonth
```

The CSV files are parsed layout-agnostically: values may be comma-separated on
one line, one per line, or a mix, with or without a header row. A leading
header token (e.g. `VmSize`, `Region`, `SubscriptionId`) is ignored, so a plain
list works too:

```csv
VmSize
Standard_D2s_v5
Standard_E4s_v5
```

```csv
SubscriptionId
11111111-1111-1111-1111-111111111111
22222222-2222-2222-2222-222222222222
```

## Output

The script prints a run header (regions, SKUs, options), a formatted results
table, and optionally exports the same data to CSV.

### Results table

One row per subscription × region × VM size (× OS when `-IncludeWindows` is set).

| Column | Meaning |
|---|---|
| `SubscriptionName` / `SubscriptionId` | The subscription the row applies to (shown only when a real subscription is resolved). |
| `Region` / `VmSize` | The ARM region and SKU. |
| `OS` | `Linux` or `Windows` (only shown with `-IncludeWindows`). |
| `RegionAvailability` | `Available` (SKU listed/offered in the region) or `Unavailable` (not listed); `?` when the lookup is skipped/unavailable. |
| `ZoneAvailability` | Zones the SKU is offered in for the region (e.g. `1,2,3`). `N/A` for a non-zonal region, `Unavailable` when the SKU is not listed, or `?`. |
| `Restrictions` | `None`, the restriction detail (`Region` for a subscription-level block and/or `Zone 1,2,3` for blocked zones), or `VM size not available in region.` when the SKU is not listed. A restriction means the size is offered but blocked for your subscription; unblock via a support case. `?` when the lookup is unavailable. |
| `PAYGO/Mo` | Pay-as-you-go monthly cost. Header shows `(-N%)` when `-ACD` is applied. |
| `Spot/Mo` / `Spot%` | Spot monthly cost and saving vs PAYGO (with `-IncludeSpot`). |
| `RI1Yr/Mo` / `RI1Yr%` | Reserved Instance 1-year monthly cost and saving. |
| `RI3Yr/Mo` / `RI3Yr%` | Reserved Instance 3-year monthly cost and saving. |
| `SP1Yr/Mo` / `SP1Yr%` | Savings Plan 1-year monthly cost and saving. |
| `SP3Yr/Mo` / `SP3Yr%` | Savings Plan 3-year monthly cost and saving. |

Values that are unavailable for a given SKU/region show `N/A`. All costs are
**monthly** amounts in the selected `-Currency` (default USD), formatted with
thousands separators.

### How the numbers are derived

- **PAYGO/Mo** = hourly rate × `HoursPerMonth` × (1 − ACD) × `InstanceCount`.
- **RI/Mo** = the full-term lump-sum retail price ÷ term months (12 or 36) ×
  `InstanceCount`. (The Retail API reports RI `retailPrice` as the **total term**
  cost despite a `unitOfMeasure` of "1 Hour".)
- **SP/Mo** = Savings Plan hourly commitment × `HoursPerMonth` × `InstanceCount`.
- **Save%** = saving vs the same-OS PAYGO monthly figure (positive = cheaper
  than PAYGO).
- For Windows rows, RI/SP reuse the OS-agnostic Linux compute rate and add the
  Windows license delta on top — a commitment discounts compute only, so the
  license bills at PAYGO. `-ACD`, being a PAYGO discount, therefore reduces that
  license portion too, even though RI/SP do not.

### CSV export

When `-OutputCsv` is supplied, every row is written to that path using the same
columns shown in the console table (as raw, unformatted values), plus a few
run-context fields (`Currency`, `SpotIncluded`, `WindowsLicenseIncluded`,
`HoursPerMonth`) so the export is self-describing.

## How it works

- **Regions are queried in parallel** (default is 5 concurrent threads via
  `-ThrottleLimit`) for both availability and pricing.
- **A single ARM bearer token** is acquired up front and reused across every
  parallel runspace, avoiding per-subscription context serialization.
- **One combined Retail API request per region** fetches both Consumption
  (PAYGO/Spot/Savings Plan) and Reservation records, halving API calls.
- **Region names are validated** against `Get-AzLocation` before querying, and
  invalid names are pruned with a warning (when Az is available).
- **Post-run diagnostics** warn about regions that returned no data, unknown
  SKUs, per-region availability gaps, and SKUs with no published commitment
  pricing.

## Notes & caveats

- Pricing is **list price** unless `-ACD` is supplied. Even then, only PAYGO is
  discounted — RI/SP are always list.
- > **`-ACD` is a single flat discount only.** It applies one uniform percentage
  > to every PAYGO rate in the run. Some customers negotiate **SKU-level or
  > product-specific discounts** (e.g. a deeper discount on a particular VM
  > family or region) that differ from their all-up rate — those are **not**
  > modeled here. Treat ACD output as an approximation and confirm SKU-specific
  > pricing with your account team or via Cost Management in the Azure portal.
- **Azure Hybrid Benefit (AHB)** users should ignore Windows rows and use the
  Linux rows which exclude licensing costs.
- Spot rates fluctuate; the reported value is a point-in-time snapshot.
- Availability and restrictions are **subscription-scoped**. Pass one or more
  `-SubscriptionId` to evaluate specific subscriptions; when omitted the
  current Az context is used. Unresolvable IDs are warned and skipped, and if
  *none* of the specified IDs resolve the run stops with an error rather than
  silently falling back to your current context.
