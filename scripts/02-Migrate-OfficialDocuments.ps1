<#
================================================================================
 EDMS — Script 02 : Migrate the existing "Official Documents" list
--------------------------------------------------------------------------------
 Reads the legacy list, normalises and validates every row, resolves lookups,
 then writes into EDMS_DocumentRegistry.

 DESIGN NOTES
 -----------
 1. DRY RUN FIRST. -DryRun produces the full exception report without writing a
    single item. Never migrate before the exception count is zero or explicitly
    accepted. Migration defects are permanent; they become "the data was always
    wrong" six months later.
 2. Lookups are auto-provisioned. Any Company / Department / Authority value
    found in the source that does not yet exist in the reference lists is
    created on the fly and flagged in the report for a human to review.
 3. Dates are the #1 failure mode. The legacy list shows dd/MM/yyyy; the SPO
    REST layer wants ISO-8601 UTC. Riyadh is UTC+3 with no DST, so a naive
    local-midnight write lands on the previous day in UTC. We normalise every
    date to 12:00 UTC to make the value date-safe in both directions.
 4. Batch size 100 with throttle back-off. SPO returns HTTP 429 aggressively on
    bulk writes; PnP's built-in retry is not enough at volume.
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SiteUrl,
    [Parameter(Mandatory)] [string] $ClientId,
    [Parameter(Mandatory)] [string] $Tenant,
    [string] $SourceListTitle = 'Official Documents',
    [string] $TargetListTitle = 'EDMS_DocumentRegistry',
    [switch] $DryRun,
    [int]    $BatchSize = 100
)

$ErrorActionPreference = 'Stop'
$exceptions = [System.Collections.Generic.List[object]]::new()
$migrated   = 0
$skipped    = 0

function Add-Exception {
    param($ItemId, $Field, $Value, $Issue, $Severity = 'ERROR')
    $exceptions.Add([pscustomobject]@{
        SourceItemId = $ItemId; Field = $Field; Value = $Value
        Issue = $Issue; Severity = $Severity
    })
}

# ------------------------------------------------------------------------------
# Date normaliser — accepts dd/MM/yyyy, MM/dd/yyyy, ISO, and DateTime objects.
# Returns a UTC DateTime at 12:00 (noon) to avoid timezone day-shift, or $null.
# ------------------------------------------------------------------------------
function ConvertTo-SafeDate {
    param($Raw, $ItemId, $FieldName)
    if ($null -eq $Raw -or "$Raw".Trim() -eq '') { return $null }
    if ($Raw -is [datetime]) { return [datetime]::SpecifyKind($Raw.Date.AddHours(12), 'Utc') }

    $formats = @('dd/MM/yyyy','d/M/yyyy','yyyy-MM-dd','MM/dd/yyyy','dd-MM-yyyy','yyyy-MM-ddTHH:mm:ssZ')
    foreach ($f in $formats) {
        $parsed = [datetime]::MinValue
        if ([datetime]::TryParseExact("$Raw".Trim(), $f,
              [Globalization.CultureInfo]::InvariantCulture,
              [Globalization.DateTimeStyles]::None, [ref]$parsed)) {
            return [datetime]::SpecifyKind($parsed.Date.AddHours(12), 'Utc')
        }
    }
    Add-Exception $ItemId $FieldName $Raw "Unparseable date — row imported with null $FieldName" 'WARN'
    return $null
}

# ------------------------------------------------------------------------------
# Lookup resolver with auto-provisioning
# ------------------------------------------------------------------------------
$lookupCache = @{}
function Resolve-Lookup {
    param([string]$ListTitle, [string]$Value, $ItemId, [string]$FieldName)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
    $key = "$ListTitle|$($Value.Trim())"
    if ($lookupCache.ContainsKey($key)) { return $lookupCache[$key] }

    $safe = $Value.Trim().Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;')
    $hit = Get-PnPListItem -List $ListTitle -Query `
        "<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>$safe</Value></Eq></Where></Query></View>"

    if ($hit.Count -gt 0) {
        $id = $hit[0].Id
    } elseif ($DryRun) {
        Add-Exception $ItemId $FieldName $Value "Reference value missing in '$ListTitle' — would be auto-created" 'INFO'
        $id = -1
    } else {
        $new = Add-PnPListItem -List $ListTitle -Values @{ Title = $Value.Trim() }
        $id = $new.Id
        Add-Exception $ItemId $FieldName $Value "Auto-created in '$ListTitle' (id $id) — REVIEW REQUIRED" 'INFO'
    }
    $lookupCache[$key] = $id
    return $id
}

# ==============================================================================
Write-Host "`n=== EDMS Migration ===" -ForegroundColor Cyan
Write-Host ("Mode : {0}" -f $(if ($DryRun) { 'DRY RUN (no writes)' } else { 'LIVE' })) `
    -ForegroundColor $(if ($DryRun) { 'Yellow' } else { 'Red' })

Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Tenant $Tenant -Interactive

$source = Get-PnPListItem -List $SourceListTitle -PageSize 500
Write-Host "Source rows: $($source.Count)" -ForegroundColor Cyan

# Pre-load existing UIDs so re-runs are idempotent.
$existingKeys = @{}
Get-PnPListItem -List $TargetListTitle -PageSize 500 -Fields 'DocumentNumber','Title' | ForEach-Object {
    $k = "$($_['DocumentNumber'])|$($_['Title'])"
    $existingKeys[$k] = $_.Id
}

$counter = 0
foreach ($row in $source) {
    $counter++
    $sid = $row.Id

    # ---- read source fields (internal names from the legacy list) ------------
    $docName   = $row['Title']
    $docNumber = "$($row['Document_x0020_Number'])".Trim()
    $docType   = "$($row['Document_x0020_Type'])".Trim()
    $authority = "$($row['Issuing_x0020_Authority'])".Trim()
    $company   = "$($row['Company'])".Trim()
    $country   = "$($row['Country'])".Trim()
    $dept      = "$($row['Department'])".Trim()
    $notes     = $row['Notes']
    $mandatory = [bool]$row['Mantadory_x003f_']          # legacy column has a typo — preserved intentionally
    $deptOwner = $row['Dep_x002e__x0020_Owner']

    # ---- validate ------------------------------------------------------------
    if ([string]::IsNullOrWhiteSpace($docName)) {
        Add-Exception $sid 'Title' '' 'Document Name is empty — row SKIPPED' 'ERROR'
        $skipped++; continue
    }

    $key = "$docNumber|$docName"
    if ($existingKeys.ContainsKey($key)) {
        Add-Exception $sid 'DocumentNumber' $docNumber "Already migrated as target id $($existingKeys[$key]) — SKIPPED" 'INFO'
        $skipped++; continue
    }

    $issueDate  = ConvertTo-SafeDate $row['Issue_x0020_Date']    $sid 'IssueDate'
    $expiryDate = ConvertTo-SafeDate $row['Expiry_x0020_Date']   $sid 'ExpiryDate'
    $reminder   = ConvertTo-SafeDate $row['Reminder_x0020_Date'] $sid 'ReminderDate'

    if ($issueDate -and $expiryDate -and $expiryDate -lt $issueDate) {
        Add-Exception $sid 'ExpiryDate' $expiryDate "Expiry precedes issue date — DATA DEFECT, requires manual fix" 'ERROR'
    }
    if ($null -eq $expiryDate) {
        Add-Exception $sid 'ExpiryDate' '' "No expiry — will be flagged IsPerpetual=true, confirm this is correct" 'WARN'
    }

    # ---- resolve lookups -----------------------------------------------------
    $typeId = Resolve-Lookup 'EDMS_DocumentTypes'      $docType   $sid 'DocumentType'
    $compId = Resolve-Lookup 'EDMS_Companies'          $company   $sid 'Company'
    $deptId = Resolve-Lookup 'EDMS_Departments'        $dept      $sid 'Department'
    $authId = Resolve-Lookup 'EDMS_IssuingAuthorities' $authority $sid 'IssuingAuthority'

    # ---- derive --------------------------------------------------------------
    $uid = "EDMS-{0:yyyy}-{1:D5}" -f (Get-Date), $sid
    $daysToExpire = if ($expiryDate) { [int]($expiryDate.Date - (Get-Date).ToUniversalTime().Date).TotalDays } else { $null }
    $status = if     ($null -eq $expiryDate)  { 'Valid' }
              elseif ($daysToExpire -lt 0)    { 'Expired' }
              elseif ($daysToExpire -le 30)   { 'Expiring Soon' }
              else                            { 'Valid' }
    $risk   = if     ($null -eq $daysToExpire){ 'Green' }
              elseif ($daysToExpire -lt 0)    { 'Black' }
              elseif ($daysToExpire -le 30)   { 'Red' }
              elseif ($daysToExpire -le 90)   { 'Amber' }
              else                            { 'Green' }

    if ($DryRun) { continue }

    # ---- write with throttle back-off ---------------------------------------
    $values = @{
        Title              = $docName
        DocumentNumber     = $docNumber
        DocumentUID        = $uid
        CountryCode        = $country
        DocNotes           = $notes
        IsMandatoryDoc     = $mandatory
        DocStatus          = $status
        RiskBand           = $risk
        IsPerpetual        = ($null -eq $expiryDate)
        SensitivityLabel   = 'Internal'
        VersionLabel       = '1.0'
    }
    if ($issueDate)  { $values['IssueDate']    = $issueDate }
    if ($expiryDate) { $values['ExpiryDate']   = $expiryDate }
    if ($reminder)   { $values['ReminderDate'] = $reminder }
    if ($null -ne $daysToExpire) { $values['DaysToExpire'] = $daysToExpire }
    if ($typeId -gt 0) { $values['DocumentTypeLookup'] = $typeId }
    if ($compId -gt 0) { $values['CompanyLookup']      = $compId }
    if ($deptId -gt 0) { $values['DepartmentLookup']   = $deptId }
    if ($authId -gt 0) { $values['AuthorityLookup']    = $authId }
    if ($deptOwner)    { $values['DocumentOwner']      = $deptOwner.Email }

    $attempt = 0
    while ($attempt -lt 5) {
        try {
            Add-PnPListItem -List $TargetListTitle -Values $values | Out-Null
            $migrated++
            break
        } catch {
            $attempt++
            if ($_.Exception.Message -match '429|throttl') {
                $wait = [math]::Pow(2, $attempt) * 5
                Write-Host "  throttled — backing off ${wait}s" -ForegroundColor Yellow
                Start-Sleep -Seconds $wait
            } else {
                Add-Exception $sid 'WRITE' $docName $_.Exception.Message 'ERROR'
                break
            }
        }
    }

    if ($counter % $BatchSize -eq 0) {
        Write-Host "  ... $counter / $($source.Count) processed" -ForegroundColor DarkGray
        Start-Sleep -Milliseconds 500
    }
}

# ==============================================================================
# REPORT
# ==============================================================================
$stamp    = Get-Date -Format 'yyyyMMdd-HHmmss'
$repPath  = Join-Path $PSScriptRoot "EDMS-Migration-Exceptions-$stamp.csv"
$exceptions | Export-Csv -Path $repPath -NoTypeInformation -Encoding UTF8

Write-Host "`n=== MIGRATION SUMMARY ===" -ForegroundColor Cyan
Write-Host ("  Source rows   : {0}" -f $source.Count)
Write-Host ("  Migrated      : {0}" -f $migrated) -ForegroundColor Green
Write-Host ("  Skipped       : {0}" -f $skipped)  -ForegroundColor Yellow
Write-Host ("  ERROR   count : {0}" -f ($exceptions | Where-Object Severity -eq 'ERROR').Count) -ForegroundColor Red
Write-Host ("  WARN    count : {0}" -f ($exceptions | Where-Object Severity -eq 'WARN').Count)  -ForegroundColor Yellow
Write-Host ("  INFO    count : {0}" -f ($exceptions | Where-Object Severity -eq 'INFO').Count)
Write-Host ("  Exception report: {0}" -f $repPath) -ForegroundColor Cyan

if (($exceptions | Where-Object Severity -eq 'ERROR').Count -gt 0) {
    Write-Host "`n  >> ERRORS PRESENT. Fix the source data and re-run before go-live. <<" -ForegroundColor Red
}

Disconnect-PnPOnline
