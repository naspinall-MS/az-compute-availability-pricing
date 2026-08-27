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
| Region access | `Allowed` or `RESTRICTED` (subscription-level Location restriction) | `Microsoft.Compute/skus` (ARM) |
| Zone access | Zones supported in the region (e.g. `1,2,3`), with subscription-blocked zones removed | `Microsoft.Compute/skus` (ARM) |
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
the script still returns pricing data and the access/zone columns show `?`.

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

`-VmSize` and `-Region` are required; all other parameters are optional.

```powershell
.\Get-ComputeAvailability.ps1 -VmSize <string[]> -Region <string[]> `
    [-VmSizeCsv <string>] [-SubscriptionCsv <string>] `
    [-IncludeSpot] [-IncludeWindows] [-HoursPerMonth <int>] [-ACD <double>] `
    [-InstanceCount <int>] [-OutputCsv <string>] [-SkipAvailability] `
    [-SkipPricing] [-Subscription <string[]>] [-ThrottleLimit <int>]
```

### Parameters

| Parameter | Type | Description |
|---|---|---|
| `-VmSize` | `string[]` | One or more ARM SKU names (e.g. `Standard_D2s_v5`, `Standard_E4s_v5`). Case is normalized automatically. Optional when `-VmSizeCsv` is supplied. |
| `-VmSizeCsv` | `string` | Path to a CSV file of VM SKU names. Reads the first matching column named (case-insensitive) `VmSize`, `SKU`, `Size`, or `Name`; falls back to the first column. Merged with any inline `-VmSize` values. |
| `-Region` | `string[]` | **Required.** One or more ARM region names (e.g. `australiaeast`, `northeurope`, `eastus`). Invalid names are pruned when Az is available. |
| `-IncludeSpot` | `switch` | Include Spot pricing. Spot is highly variable; the API returns the current published rate at query time. |
| `-IncludeWindows` | `switch` | Add Windows-licensed rows alongside Linux. Windows rows bundle the Windows Server license premium (not discounted by RI/SP). |
| `-HoursPerMonth` | `int` | Hours used to project hourly rates into monthly costs. Default `730` (Azure billing convention: 365.25 × 24 / 12). |
| `-ACD` | `double` | All-up customer discount percentage (0–100) applied to the PAYGO rate to reflect EA/MCA negotiated pricing. RI/SP rates are unchanged; Save% is recalculated against the discounted baseline. Default `0`. |
| `-InstanceCount` | `int` | Multiply all monthly cost columns by this count to project an N-instance deployment. Save% is unaffected. Default `1`. |
| `-OutputCsv` | `string` | Optional path to export results as a CSV file. |
| `-SkipAvailability` | `switch` | Skip the `Microsoft.Compute/skus` lookup for a faster pricing-only run. |
| `-SkipPricing` | `switch` | Skip the Retail Prices API for an availability-only matrix. Cannot be combined with `-SkipAvailability`. |
| `-Subscription` | `string[]` | One or more subscription names or IDs. Each gets its own rows (availability is subscription-scoped). Defaults to the current Az context. |
| `-SubscriptionCsv` | `string` | Path to a CSV file of subscription names or IDs. Reads the first matching column named (case-insensitive) `Subscription`, `SubscriptionId`, `SubscriptionName`, `Id`, or `Name`; falls back to the first column. Merged with any inline `-Subscription` values. |
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
    -Subscription 'Prod','Dev' -SkipPricing

# Fast pricing-only run (skip the ARM availability lookup)
.\Get-ComputeAvailability.ps1 -Region eastus -VmSize Standard_D2s_v5 -SkipAvailability

# Read SKUs and subscriptions from CSV files (merged with any inline values)
.\Get-ComputeAvailability.ps1 -Region eastus,westus2 -VmSizeCsv .\skus.csv -SubscriptionCsv .\subs.csv
```

The CSV files use a simple header row. The script looks for a recognized column
(case-insensitive) and falls back to the first column, so a single-column file
works with any header:

```csv
VmSize
Standard_D2s_v5
Standard_E4s_v5
```

```csv
Subscription
Production
00000000-0000-0000-0000-000000000000
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
| `RegionAccess` | `Allowed`, `RESTRICTED`, `not listed`, or `?` (lookup skipped/unavailable). |
| `ZoneAccess` | Supported zones (e.g. `1,2,3`), `none` (no zonal deployment), `-` (region restricted), `not listed`, or `?`. |
| `PAYGO/Mo` | Pay-as-you-go monthly cost. Header shows `(-N%)` when `-ACD` is applied. |
| `Spot/Mo` / `Spot%` | Spot monthly cost and saving vs PAYGO (with `-IncludeSpot`). |
| `RI1Yr/Mo` / `RI1Yr%` | Reserved Instance 1-year monthly cost and saving. |
| `RI3Yr/Mo` / `RI3Yr%` | Reserved Instance 3-year monthly cost and saving. |
| `SP1Yr/Mo` / `SP1Yr%` | Savings Plan 1-year monthly cost and saving. |
| `SP3Yr/Mo` / `SP3Yr%` | Savings Plan 3-year monthly cost and saving. |

Values that are unavailable for a given SKU/region show `N/A`. All costs are
**monthly USD**.

### How the numbers are derived

- **PAYGO/Mo** = hourly rate × `HoursPerMonth` × (1 − ACD) × `InstanceCount`.
- **RI/Mo** = the full-term lump-sum retail price ÷ term months (12 or 36) ×
  `InstanceCount`. (The Retail API reports RI `retailPrice` as the **total term**
  cost despite a `unitOfMeasure` of "1 Hour".)
- **SP/Mo** = Savings Plan hourly commitment × `HoursPerMonth` × `InstanceCount`.
- **Save%** = saving vs the same-OS PAYGO monthly figure (positive = cheaper
  than PAYGO).
- For Windows rows, RI/SP reuse the OS-agnostic Linux compute rate and add the
  Windows license delta at PAYGO rates — matching how Azure actually bills.

### CSV export

When `-OutputCsv` is supplied, all rows are written to that path with the full
column set (including the raw `RegionBlocked` and `RestrictReason` fields), so
the CSV can carry more detail than the console table.

## How it works

- **Regions are queried in parallel** (default up to 5 concurrent threads via
  `-ThrottleLimit`) for both availability and pricing.
- **A single ARM bearer token** is acquired up front and reused across every
  parallel runspace, avoiding per-subscription context serialization.
- **One combined Retail API request per region** fetches both Consumption
  (PAYGO/Spot/Savings Plan) and Reservation records, halving API calls.
- **Region names are validated** against `Get-AzLocation` before querying, and
  invalid names are pruned with a warning (when Az is available).
- **SKU names are canonicalized** to the correct case, because the Retail API's
  `armSkuName` filter is case-sensitive server-side.
- **Post-run diagnostics** warn about regions that returned no data, unknown
  SKUs, per-region availability gaps, and SKUs with no published commitment
  pricing.

## Notes & caveats

- Pricing is **list price** unless `-ACD` is supplied. Even then, only PAYGO is
  discounted — RI/SP are always list.
- **Azure Hybrid Benefit (AHB)** users should ignore Windows rows and use the
  Linux rows plus their own AHB-licensed pricing.
- Spot rates fluctuate; the reported value is a point-in-time snapshot.
- Availability data reflects the **subscription** you're authenticated against —
  restrictions differ between subscriptions.
