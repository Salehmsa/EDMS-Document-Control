<#
================================================================================
 EDMS — the Company Enterprise Document Management System
 نظام إدارة الوثائق الرسمية المؤسسي
--------------------------------------------------------------------------------
 Script 01 : Provision site, lists, content types, columns, indexes, views
 Platform  : SharePoint Online + PnP.PowerShell 2.x
 Author    : System design — Saleh Mahbub
 Version   : 1.0
--------------------------------------------------------------------------------
 PREREQUISITES
   Install-Module PnP.PowerShell -Scope CurrentUser -MinimumVersion 2.5.0
   # Entra app registration required since PnP 2.x (no more default app id):
   Register-PnPEntraIDApp -ApplicationName "EDMS-Provisioning" `
        -Tenant <tenant>.onmicrosoft.com -Interactive
--------------------------------------------------------------------------------
 IDEMPOTENCY
   Every Add-* is guarded by a Get-* existence check, so the script can be
   re-run safely against a partially provisioned site. Nothing is destroyed.
================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $SiteUrl,          # https://<tenant>.sharepoint.com/sites/EDMS
    [Parameter(Mandatory)] [string] $ClientId,         # Entra app (client) id
    [Parameter(Mandatory)] [string] $Tenant,           # <tenant>.onmicrosoft.com
    [switch] $WhatIfOnly
)

$ErrorActionPreference = 'Stop'
$script:Log = @()

function Write-Step {
    param([string]$Message, [string]$Level = 'INFO')
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $color = switch ($Level) { 'OK' {'Green'} 'WARN' {'Yellow'} 'ERR' {'Red'} default {'Cyan'} }
    Write-Host "[$ts][$Level] $Message" -ForegroundColor $color
    $script:Log += [pscustomobject]@{ Time = $ts; Level = $Level; Message = $Message }
}

function Ensure-List {
    param([string]$Title, [string]$Template = 'GenericList', [string]$Url, [switch]$EnableVersioning)
    $list = Get-PnPList -Identity $Title -ErrorAction SilentlyContinue
    if ($null -eq $list) {
        $list = New-PnPList -Title $Title -Template $Template -Url $Url -OnQuickLaunch:$false
        Write-Step "Created list '$Title'" 'OK'
    } else {
        Write-Step "List '$Title' already exists — skipping create" 'WARN'
    }
    if ($EnableVersioning) {
        Set-PnPList -Identity $Title -EnableVersioning $true -MajorVersions 500
    }
    return $list
}

function Ensure-Field {
    param(
        [string]$List, [string]$InternalName, [string]$DisplayName,
        [string]$Type = 'Text', [string]$XmlOverride, [switch]$Required,
        [switch]$Indexed, [string]$Group = 'EDMS Columns'
    )
    $existing = Get-PnPField -List $List -Identity $InternalName -ErrorAction SilentlyContinue
    if ($existing) { Write-Step "  · field '$InternalName' exists" 'WARN'; return $existing }

    if ($XmlOverride) {
        $f = Add-PnPFieldFromXml -List $List -FieldXml $XmlOverride
    } else {
        $f = Add-PnPField -List $List -DisplayName $DisplayName -InternalName $InternalName `
                          -Type $Type -Group $Group -AddToDefaultView
    }
    if ($Required) { Set-PnPField -List $List -Identity $InternalName -Values @{ Required = $true } }
    if ($Indexed)  { Set-PnPField -List $List -Identity $InternalName -Values @{ Indexed  = $true } }
    Write-Step "  + field '$InternalName' ($Type)" 'OK'
    return $f
}

# ==============================================================================
# 0. CONNECT
# ==============================================================================
Write-Step "Connecting to $SiteUrl"
Connect-PnPOnline -Url $SiteUrl -ClientId $ClientId -Tenant $Tenant -Interactive
Write-Step "Connected as $((Get-PnPContext).Credentials)" 'OK'

if ($WhatIfOnly) { Write-Step "WhatIfOnly — no changes will be written" 'WARN'; return }


# ==============================================================================
# 1. REFERENCE / LOOKUP LISTS
#    Built FIRST because DocumentRegistry has lookups into all of them.
# ==============================================================================
Write-Step "=== SECTION 1 : Reference lists ==="

# ---- 1.1 Companies (legal entities) -----------------------------------------
Ensure-List -Title 'EDMS_Companies' -Url 'Lists/EDMS_Companies' | Out-Null
Ensure-Field -List 'EDMS_Companies' -InternalName 'CompanyNameAr'   -DisplayName 'Company Name (AR)' -Type Text -Required
Ensure-Field -List 'EDMS_Companies' -InternalName 'CRNumber'        -DisplayName 'CR Number'         -Type Text
Ensure-Field -List 'EDMS_Companies' -InternalName 'TaxID'           -DisplayName 'VAT / Tax ID'      -Type Text
Ensure-Field -List 'EDMS_Companies' -InternalName 'CountryCode'     -DisplayName 'Country'           -Type Text -Indexed
Ensure-Field -List 'EDMS_Companies' -InternalName 'IsActive'        -DisplayName 'Active'            -Type Boolean

# ---- 1.2 Departments ---------------------------------------------------------
Ensure-List -Title 'EDMS_Departments' -Url 'Lists/EDMS_Departments' | Out-Null
Ensure-Field -List 'EDMS_Departments' -InternalName 'DeptNameAr'    -DisplayName 'Department (AR)'   -Type Text -Required
Ensure-Field -List 'EDMS_Departments' -InternalName 'DeptOwner'     -DisplayName 'Department Owner'  -Type User -Required
Ensure-Field -List 'EDMS_Departments' -InternalName 'EscalationMgr' -DisplayName 'Escalation Manager' -Type User
Ensure-Field -List 'EDMS_Departments' -InternalName 'ExecSponsor'   -DisplayName 'Executive Sponsor' -Type User
Ensure-Field -List 'EDMS_Departments' -InternalName 'SecurityGroup' -DisplayName 'Entra Security Group' -Type Text
Ensure-Field -List 'EDMS_Departments' -InternalName 'CostCenter'    -DisplayName 'Cost Center'       -Type Text

# ---- 1.3 Issuing Authorities -------------------------------------------------
Ensure-List -Title 'EDMS_IssuingAuthorities' -Url 'Lists/EDMS_IssuingAuthorities' | Out-Null
Ensure-Field -List 'EDMS_IssuingAuthorities' -InternalName 'AuthorityNameAr' -DisplayName 'Authority (AR)' -Type Text -Required
Ensure-Field -List 'EDMS_IssuingAuthorities' -InternalName 'AuthorityCountry' -DisplayName 'Country'       -Type Text -Indexed
Ensure-Field -List 'EDMS_IssuingAuthorities' -InternalName 'RenewalPortalUrl' -DisplayName 'Renewal Portal' -Type URL
Ensure-Field -List 'EDMS_IssuingAuthorities' -InternalName 'RenewalChannel'   -DisplayName 'Renewal Channel' `
    -XmlOverride "<Field Type='Choice' DisplayName='Renewal Channel' Name='RenewalChannel' StaticName='RenewalChannel' Group='EDMS Columns' Format='Dropdown'><CHOICES><CHOICE>Online Portal</CHOICE><CHOICE>In-Person</CHOICE><CHOICE>Email</CHOICE><CHOICE>Agent / PRO</CHOICE></CHOICES></Field>"
Ensure-Field -List 'EDMS_IssuingAuthorities' -InternalName 'TypicalLeadDays'  -DisplayName 'Typical Processing Days' -Type Number
Ensure-Field -List 'EDMS_IssuingAuthorities' -InternalName 'ContactEmail'     -DisplayName 'Contact Email' -Type Text

# ---- 1.4 Document Types (the policy engine) ----------------------------------
# This list is the heart of the system: it drives validity, mandatory status,
# notification cadence, approval template, and retention class per document type.
Ensure-List -Title 'EDMS_DocumentTypes' -Url 'Lists/EDMS_DocumentTypes' | Out-Null
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'TypeNameAr'       -DisplayName 'Type Name (AR)' -Type Text -Required
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'TypeCategory'     -DisplayName 'Category' `
    -XmlOverride "<Field Type='Choice' DisplayName='Category' Name='TypeCategory' StaticName='TypeCategory' Group='EDMS Columns' Format='Dropdown' Indexed='TRUE'><CHOICES><CHOICE>Certification</CHOICE><CHOICE>License</CHOICE><CHOICE>Contract</CHOICE><CHOICE>Insurance</CHOICE><CHOICE>Registration</CHOICE><CHOICE>Policy</CHOICE><CHOICE>HR Record</CHOICE><CHOICE>Financial</CHOICE></CHOICES></Field>"
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'DefaultValidityMonths' -DisplayName 'Default Validity (months)' -Type Number
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'IsMandatory'      -DisplayName 'Mandatory'      -Type Boolean
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'RenewalLeadDays'  -DisplayName 'Renewal Lead Days' -Type Number
# Tiered reminder ladder, stored as CSV of day offsets — read by the notification flow.
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'ReminderTiers'    -DisplayName 'Reminder Tiers (CSV days)' -Type Text
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'NotifyChannels'   -DisplayName 'Channels' `
    -XmlOverride "<Field Type='MultiChoice' DisplayName='Channels' Name='NotifyChannels' StaticName='NotifyChannels' Group='EDMS Columns'><CHOICES><CHOICE>Email</CHOICE><CHOICE>Teams</CHOICE><CHOICE>SMS</CHOICE><CHOICE>InApp</CHOICE></CHOICES></Field>"
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'ApprovalTemplate' -DisplayName 'Approval Template' `
    -XmlOverride "<Field Type='Choice' DisplayName='Approval Template' Name='ApprovalTemplate' StaticName='ApprovalTemplate' Group='EDMS Columns' Format='Dropdown'><CHOICES><CHOICE>None</CHOICE><CHOICE>Owner Only</CHOICE><CHOICE>Owner + Compliance</CHOICE><CHOICE>Owner + Compliance + Legal</CHOICE><CHOICE>Executive</CHOICE></CHOICES></Field>"
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'RetentionYears'   -DisplayName 'Retention (years after expiry)' -Type Number
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'SensitivityTier'  -DisplayName 'Sensitivity' `
    -XmlOverride "<Field Type='Choice' DisplayName='Sensitivity' Name='SensitivityTier' StaticName='SensitivityTier' Group='EDMS Columns' Format='Dropdown'><CHOICES><CHOICE>Public</CHOICE><CHOICE>Internal</CHOICE><CHOICE>Confidential</CHOICE><CHOICE>Restricted</CHOICE></CHOICES></Field>"
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'RequiredAttachments' -DisplayName 'Required Attachments' -Type Note
Ensure-Field -List 'EDMS_DocumentTypes' -InternalName 'ISOClause'        -DisplayName 'ISO 9001 Clause Ref' -Type Text


# ==============================================================================
# 2. DOCUMENT LIBRARY (the files)
#    Metadata lives in the registry list; binaries live here with their own
#    permission surface. Separating them is what lets "everyone can see that a
#    CR exists" coexist with "only Legal can open the PDF".
# ==============================================================================
Write-Step "=== SECTION 2 : Document library ==="
Ensure-List -Title 'EDMS_Files' -Template 'DocumentLibrary' -Url 'EDMSFiles' -EnableVersioning | Out-Null
Set-PnPList -Identity 'EDMS_Files' `
            -EnableVersioning $true -MajorVersions 500 `
            -EnableMinorVersions $true -MinorVersions 10 `
            -EnableAttachments $false `
            -ForceCheckout $true
Write-Step "Library versioning: 500 major / 10 minor, force check-out ON" 'OK'

Ensure-Field -List 'EDMS_Files' -InternalName 'LinkedDocumentId' -DisplayName 'Registry Item ID' -Type Number -Indexed
Ensure-Field -List 'EDMS_Files' -InternalName 'FilePurpose'      -DisplayName 'File Purpose' `
    -XmlOverride "<Field Type='Choice' DisplayName='File Purpose' Name='FilePurpose' StaticName='FilePurpose' Group='EDMS Columns' Format='Dropdown'><CHOICES><CHOICE>Original Certificate</CHOICE><CHOICE>Scanned Copy</CHOICE><CHOICE>Renewal Receipt</CHOICE><CHOICE>Supporting Evidence</CHOICE><CHOICE>Superseded Version</CHOICE></CHOICES></Field>"


# ==============================================================================
# 3. DOCUMENT REGISTRY — the master list
#    Deliberately mirrors the existing "Official Documents" column set so that
#    migration is a field-map, not a re-key.
# ==============================================================================
Write-Step "=== SECTION 3 : DocumentRegistry ==="
Ensure-List -Title 'EDMS_DocumentRegistry' -Url 'Lists/EDMS_DocumentRegistry' -EnableVersioning | Out-Null
Set-PnPList -Identity 'EDMS_DocumentRegistry' -EnableVersioning $true -MajorVersions 500 -EnableAttachments $false

$reg = 'EDMS_DocumentRegistry'

# --- identity -----------------------------------------------------------------
# Title is reused as DocumentName (AR) to keep the built-in link-to-item behaviour.
Set-PnPField -List $reg -Identity 'Title' -Values @{ Title = 'Document Name'; Required = $true }
Ensure-Field -List $reg -InternalName 'DocumentNameEn'  -DisplayName 'Document Name (EN)' -Type Text
Ensure-Field -List $reg -InternalName 'DocumentNumber'  -DisplayName 'Document Number'    -Type Text -Indexed
Ensure-Field -List $reg -InternalName 'DocumentUID'     -DisplayName 'System UID'         -Type Text -Indexed   # EDMS-2026-00417

# --- classification (lookups) --------------------------------------------------
# Lookups are created from field XML, not Add-PnPField: the cmdlet cannot bind a
# lookup to its source list, so the target list's GUID has to go into List='{...}'
# directly. Indexing is set inline because a lookup cannot be indexed after the
# list passes the 5,000-item threshold.
$lookups = @(
    @{ Name='DocumentTypeLookup'; Display='Document Type';     Source='EDMS_DocumentTypes';       Show='Title'; Indexed=$true  },
    @{ Name='CompanyLookup';      Display='Company';           Source='EDMS_Companies';           Show='Title'; Indexed=$true  },
    @{ Name='DepartmentLookup';   Display='Department';        Source='EDMS_Departments';         Show='Title'; Indexed=$true  },
    @{ Name='AuthorityLookup';    Display='Issuing Authority'; Source='EDMS_IssuingAuthorities';  Show='Title'; Indexed=$false }
)
foreach ($lk in $lookups) {
    if (Get-PnPField -List $reg -Identity $lk.Name -ErrorAction SilentlyContinue) {
        Write-Step "  · lookup '$($lk.Name)' exists" 'WARN'; continue
    }
    $srcList = Get-PnPList -Identity $lk.Source
    $idx = if ($lk.Indexed) { "Indexed='TRUE'" } else { "" }
    $xml = "<Field Type='Lookup' DisplayName='$($lk.Display)' Name='$($lk.Name)' StaticName='$($lk.Name)' " +
           "List='{$($srcList.Id)}' ShowField='$($lk.Show)' Group='EDMS Columns' $idx />"
    Add-PnPFieldFromXml -List $reg -FieldXml $xml | Out-Null
    Write-Step "  + lookup '$($lk.Name)' -> $($lk.Source)" 'OK'
}

# --- lifecycle dates -----------------------------------------------------------
Ensure-Field -List $reg -InternalName 'IssueDate'   -DisplayName 'Issue Date'   -Type DateTime -Required
Ensure-Field -List $reg -InternalName 'ExpiryDate'  -DisplayName 'Expiry Date'  -Type DateTime -Indexed
Ensure-Field -List $reg -InternalName 'ReminderDate' -DisplayName 'Reminder Date' -Type DateTime
Ensure-Field -List $reg -InternalName 'IsPerpetual' -DisplayName 'No Expiry'    -Type Boolean
Ensure-Field -List $reg -InternalName 'LastRenewedOn' -DisplayName 'Last Renewed On' -Type DateTime

# --- ownership -----------------------------------------------------------------
Ensure-Field -List $reg -InternalName 'DocumentOwner'   -DisplayName 'Document Owner'   -Type User -Required -Indexed
Ensure-Field -List $reg -InternalName 'BackupOwner'     -DisplayName 'Backup Owner'     -Type User
Ensure-Field -List $reg -InternalName 'ComplianceOwner' -DisplayName 'Compliance Owner' -Type User

# --- state machine --------------------------------------------------------------
# NOTE: Status and DaysToExpire are STAMPED BY FLOW, not calculated columns.
# SharePoint calculated columns cannot use [Today] reliably — the value freezes
# at the moment of the last item write. This is the single most common defect in
# home-grown SharePoint expiry trackers. See Script 03.
Ensure-Field -List $reg -InternalName 'DocStatus' -DisplayName 'Status' `
    -XmlOverride "<Field Type='Choice' DisplayName='Status' Name='DocStatus' StaticName='DocStatus' Group='EDMS Columns' Format='Dropdown' Indexed='TRUE'><CHOICES><CHOICE>Draft</CHOICE><CHOICE>Pending Approval</CHOICE><CHOICE>Valid</CHOICE><CHOICE>Expiring Soon</CHOICE><CHOICE>Expired</CHOICE><CHOICE>Under Renewal</CHOICE><CHOICE>Superseded</CHOICE><CHOICE>Archived</CHOICE></CHOICES><Default>Draft</Default></Field>"
Ensure-Field -List $reg -InternalName 'DaysToExpire'  -DisplayName 'Days to Expire' -Type Number -Indexed
Ensure-Field -List $reg -InternalName 'RiskBand'      -DisplayName 'Risk Band' `
    -XmlOverride "<Field Type='Choice' DisplayName='Risk Band' Name='RiskBand' StaticName='RiskBand' Group='EDMS Columns' Format='Dropdown'><CHOICES><CHOICE>Green</CHOICE><CHOICE>Amber</CHOICE><CHOICE>Red</CHOICE><CHOICE>Black</CHOICE></CHOICES></Field>"
Ensure-Field -List $reg -InternalName 'IsMandatoryDoc' -DisplayName 'Mandatory?' -Type Boolean -Indexed

# --- content ---------------------------------------------------------------------
Ensure-Field -List $reg -InternalName 'CountryCode'   -DisplayName 'Country'   -Type Text -Indexed
Ensure-Field -List $reg -InternalName 'DocNotes'      -DisplayName 'Notes'     -Type Note
Ensure-Field -List $reg -InternalName 'PrimaryFileUrl' -DisplayName 'Primary File' -Type URL
Ensure-Field -List $reg -InternalName 'SensitivityLabel' -DisplayName 'Sensitivity' `
    -XmlOverride "<Field Type='Choice' DisplayName='Sensitivity' Name='SensitivityLabel' StaticName='SensitivityLabel' Group='EDMS Columns' Format='Dropdown'><CHOICES><CHOICE>Public</CHOICE><CHOICE>Internal</CHOICE><CHOICE>Confidential</CHOICE><CHOICE>Restricted</CHOICE></CHOICES><Default>Internal</Default></Field>"

# --- versioning / supersession ------------------------------------------------
Ensure-Field -List $reg -InternalName 'VersionLabel'    -DisplayName 'Version'        -Type Text
Ensure-Field -List $reg -InternalName 'SupersedesDocId' -DisplayName 'Supersedes ID'  -Type Number
Ensure-Field -List $reg -InternalName 'SupersededByDocId' -DisplayName 'Superseded By ID' -Type Number

# --- governance ------------------------------------------------------------------
Ensure-Field -List $reg -InternalName 'RetentionClass'  -DisplayName 'Retention Class' -Type Text
Ensure-Field -List $reg -InternalName 'DisposalDate'    -DisplayName 'Scheduled Disposal' -Type DateTime
Ensure-Field -List $reg -InternalName 'LastReviewedOn'  -DisplayName 'Last Reviewed On'  -Type DateTime
Ensure-Field -List $reg -InternalName 'LastReviewedBy'  -DisplayName 'Last Reviewed By'  -Type User


# ==============================================================================
# 4. OPERATIONAL LISTS
# ==============================================================================
Write-Step "=== SECTION 4 : Operational lists ==="

# ---- 4.1 Renewal Requests (workflow instances) --------------------------------
Ensure-List -Title 'EDMS_RenewalRequests' -Url 'Lists/EDMS_RenewalRequests' | Out-Null
Ensure-Field -List 'EDMS_RenewalRequests' -InternalName 'RegistryItemId' -DisplayName 'Registry Item ID' -Type Number -Required -Indexed
Ensure-Field -List 'EDMS_RenewalRequests' -InternalName 'RequestStage' -DisplayName 'Stage' `
    -XmlOverride "<Field Type='Choice' DisplayName='Stage' Name='RequestStage' StaticName='RequestStage' Group='EDMS Columns' Format='Dropdown' Indexed='TRUE'><CHOICES><CHOICE>Initiated</CHOICE><CHOICE>Documents Gathering</CHOICE><CHOICE>Submitted to Authority</CHOICE><CHOICE>Awaiting Approval</CHOICE><CHOICE>Received</CHOICE><CHOICE>Registered</CHOICE><CHOICE>Cancelled</CHOICE></CHOICES></Field>"
Ensure-Field -List 'EDMS_RenewalRequests' -InternalName 'AssignedTo'    -DisplayName 'Assigned To' -Type User -Indexed
Ensure-Field -List 'EDMS_RenewalRequests' -InternalName 'TargetDate'    -DisplayName 'Target Completion' -Type DateTime
Ensure-Field -List 'EDMS_RenewalRequests' -InternalName 'EstimatedCost' -DisplayName 'Estimated Cost (SAR)' -Type Currency
Ensure-Field -List 'EDMS_RenewalRequests' -InternalName 'SLABreached'   -DisplayName 'SLA Breached' -Type Boolean

# ---- 4.2 Approval Steps --------------------------------------------------------
Ensure-List -Title 'EDMS_ApprovalSteps' -Url 'Lists/EDMS_ApprovalSteps' | Out-Null
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'ParentEntity'  -DisplayName 'Parent Entity' -Type Text -Indexed  # Registry | Renewal
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'ParentItemId'  -DisplayName 'Parent Item ID' -Type Number -Indexed
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'StepOrder'     -DisplayName 'Step #' -Type Number
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'Approver'      -DisplayName 'Approver' -Type User -Indexed
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'StepOutcome'   -DisplayName 'Outcome' `
    -XmlOverride "<Field Type='Choice' DisplayName='Outcome' Name='StepOutcome' StaticName='StepOutcome' Group='EDMS Columns' Format='Dropdown'><CHOICES><CHOICE>Pending</CHOICE><CHOICE>Approved</CHOICE><CHOICE>Rejected</CHOICE><CHOICE>Delegated</CHOICE><CHOICE>Expired</CHOICE></CHOICES></Field>"
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'RespondedOn'   -DisplayName 'Responded On' -Type DateTime
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'Comments'      -DisplayName 'Comments' -Type Note
Ensure-Field -List 'EDMS_ApprovalSteps' -InternalName 'SignatureRef'  -DisplayName 'e-Signature Ref' -Type Text

# ---- 4.3 Notification Log (idempotency guard + audit) --------------------------
# Composite natural key: RegistryItemId + TierDays + SendDateKey.
# The notification flow checks this BEFORE sending, which is what stops a retried
# or double-triggered flow run from spamming 200 people twice.
Ensure-List -Title 'EDMS_NotificationLog' -Url 'Lists/EDMS_NotificationLog' | Out-Null
Ensure-Field -List 'EDMS_NotificationLog' -InternalName 'IdempotencyKey' -DisplayName 'Idempotency Key' -Type Text -Required -Indexed
Ensure-Field -List 'EDMS_NotificationLog' -InternalName 'RegistryItemId' -DisplayName 'Registry Item ID' -Type Number -Indexed
Ensure-Field -List 'EDMS_NotificationLog' -InternalName 'TierDays'       -DisplayName 'Tier (days out)' -Type Number
Ensure-Field -List 'EDMS_NotificationLog' -InternalName 'Channel'        -DisplayName 'Channel' -Type Text
Ensure-Field -List 'EDMS_NotificationLog' -InternalName 'Recipients'     -DisplayName 'Recipients' -Type Note
Ensure-Field -List 'EDMS_NotificationLog' -InternalName 'SendStatus'     -DisplayName 'Send Status' -Type Text
Ensure-Field -List 'EDMS_NotificationLog' -InternalName 'ErrorDetail'    -DisplayName 'Error Detail' -Type Note

# ---- 4.4 Audit Log (business events beyond SharePoint version history) ---------
Ensure-List -Title 'EDMS_AuditLog' -Url 'Lists/EDMS_AuditLog' | Out-Null
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'EventUtc'     -DisplayName 'Event (UTC)'  -Type DateTime -Indexed
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'ActorUpn'     -DisplayName 'Actor UPN'    -Type Text -Indexed
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'EventType'    -DisplayName 'Event Type'   -Type Text -Indexed
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'EntityName'   -DisplayName 'Entity'       -Type Text
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'EntityItemId' -DisplayName 'Entity Item ID' -Type Number -Indexed
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'BeforeJson'   -DisplayName 'Before (JSON)' -Type Note
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'AfterJson'    -DisplayName 'After (JSON)'  -Type Note
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'ClientIp'     -DisplayName 'Client IP'     -Type Text
Ensure-Field -List 'EDMS_AuditLog' -InternalName 'CorrelationId' -DisplayName 'Correlation ID' -Type Text

# ---- 4.5 Delegations (temporary authority transfer) ----------------------------
Ensure-List -Title 'EDMS_Delegations' -Url 'Lists/EDMS_Delegations' | Out-Null
Ensure-Field -List 'EDMS_Delegations' -InternalName 'Delegator'   -DisplayName 'Delegator'  -Type User -Required -Indexed
Ensure-Field -List 'EDMS_Delegations' -InternalName 'Delegate'    -DisplayName 'Delegate'   -Type User -Required -Indexed
Ensure-Field -List 'EDMS_Delegations' -InternalName 'ScopeDept'   -DisplayName 'Scope: Department' -Type Text
Ensure-Field -List 'EDMS_Delegations' -InternalName 'ValidFrom'   -DisplayName 'Valid From' -Type DateTime -Required
Ensure-Field -List 'EDMS_Delegations' -InternalName 'ValidUntil'  -DisplayName 'Valid Until' -Type DateTime -Required -Indexed
Ensure-Field -List 'EDMS_Delegations' -InternalName 'DelegationReason' -DisplayName 'Reason' -Type Note
Ensure-Field -List 'EDMS_Delegations' -InternalName 'IsRevoked'   -DisplayName 'Revoked' -Type Boolean

# ---- 4.6 System Config (single-row settings, avoids hard-coding in flows) ------
Ensure-List -Title 'EDMS_Config' -Url 'Lists/EDMS_Config' | Out-Null
Ensure-Field -List 'EDMS_Config' -InternalName 'ConfigValue' -DisplayName 'Value' -Type Note
Ensure-Field -List 'EDMS_Config' -InternalName 'ConfigScope' -DisplayName 'Scope' -Type Text


# ==============================================================================
# 5. VIEWS
#    Every view is filtered + sorted on an INDEXED column so it stays under the
#    5,000-item list view threshold as the registry grows.
# ==============================================================================
Write-Step "=== SECTION 5 : Views ==="

$viewFields = 'Title','DocumentNumber','DocumentTypeLookup','CompanyLookup','DepartmentLookup',
              'IssueDate','ExpiryDate','DaysToExpire','DocStatus','DocumentOwner','RiskBand'

function Ensure-View {
    param([string]$List, [string]$Title, [string]$Query, [string[]]$Fields, [int]$RowLimit = 100)
    if (Get-PnPView -List $List -Identity $Title -ErrorAction SilentlyContinue) {
        Write-Step "  · view '$Title' exists" 'WARN'; return
    }
    Add-PnPView -List $List -Title $Title -Fields $Fields -Query $Query -RowLimit $RowLimit | Out-Null
    Write-Step "  + view '$Title'" 'OK'
}

Ensure-View -List $reg -Title 'Expiring — 30 Days' -Fields $viewFields -Query @"
<Where><And>
  <And>
    <Geq><FieldRef Name='DaysToExpire'/><Value Type='Number'>0</Value></Geq>
    <Leq><FieldRef Name='DaysToExpire'/><Value Type='Number'>30</Value></Leq>
  </And>
  <Neq><FieldRef Name='DocStatus'/><Value Type='Text'>Archived</Value></Neq>
</And></Where>
<OrderBy><FieldRef Name='DaysToExpire' Ascending='TRUE'/></OrderBy>
"@

Ensure-View -List $reg -Title 'Expiring — 90 Days' -Fields $viewFields -Query @"
<Where><And>
  <And>
    <Geq><FieldRef Name='DaysToExpire'/><Value Type='Number'>0</Value></Geq>
    <Leq><FieldRef Name='DaysToExpire'/><Value Type='Number'>90</Value></Leq>
  </And>
  <Neq><FieldRef Name='DocStatus'/><Value Type='Text'>Archived</Value></Neq>
</And></Where>
<OrderBy><FieldRef Name='DaysToExpire' Ascending='TRUE'/></OrderBy>
"@

Ensure-View -List $reg -Title 'Expired — Action Required' -Fields $viewFields -Query @"
<Where><Eq><FieldRef Name='DocStatus'/><Value Type='Text'>Expired</Value></Eq></Where>
<OrderBy><FieldRef Name='DaysToExpire' Ascending='TRUE'/></OrderBy>
"@

Ensure-View -List $reg -Title 'Mandatory Documents' -Fields $viewFields -Query @"
<Where><Eq><FieldRef Name='IsMandatoryDoc'/><Value Type='Boolean'>1</Value></Eq></Where>
<OrderBy><FieldRef Name='ExpiryDate' Ascending='TRUE'/></OrderBy>
"@

Ensure-View -List $reg -Title 'My Documents' -Fields $viewFields -Query @"
<Where><Eq><FieldRef Name='DocumentOwner'/><Value Type='Integer'><UserID Type='Integer'/></Value></Eq></Where>
<OrderBy><FieldRef Name='ExpiryDate' Ascending='TRUE'/></OrderBy>
"@

Ensure-View -List $reg -Title 'Pending Approval' -Fields $viewFields -Query @"
<Where><Eq><FieldRef Name='DocStatus'/><Value Type='Text'>Pending Approval</Value></Eq></Where>
"@


# ==============================================================================
# 6. SECURITY GROUPS
# ==============================================================================
Write-Step "=== SECTION 6 : Security groups ==="
$groups = @(
    @{ Name = 'EDMS System Administrators'; Role = 'Full Control' },
    @{ Name = 'EDMS Compliance Officers';   Role = 'Contribute'   },
    @{ Name = 'EDMS Document Owners';       Role = 'Contribute'   },
    @{ Name = 'EDMS Approvers';             Role = 'Read'         },
    @{ Name = 'EDMS Readers';               Role = 'Read'         }
)
foreach ($g in $groups) {
    if (-not (Get-PnPGroup -Identity $g.Name -ErrorAction SilentlyContinue)) {
        New-PnPGroup -Title $g.Name -ErrorAction SilentlyContinue | Out-Null
        Write-Step "  + group '$($g.Name)'" 'OK'
    } else { Write-Step "  · group '$($g.Name)' exists" 'WARN' }
}

# Compliance Officers must not be able to hard-delete evidence.
# Create a custom role definition = Contribute minus DeleteListItems.
if (-not (Get-PnPRoleDefinition -Identity 'EDMS Contribute No Delete' -ErrorAction SilentlyContinue)) {
    Add-PnPRoleDefinition -RoleName 'EDMS Contribute No Delete' `
        -Clone 'Contribute' -Exclude DeleteListItems, DeleteVersions `
        -Description 'Contribute without delete — preserves the evidence trail for audit.' | Out-Null
    Write-Step "  + role definition 'EDMS Contribute No Delete'" 'OK'
}


# ==============================================================================
# 7. SEED DATA — document types matching the existing Official Documents list
# ==============================================================================
Write-Step "=== SECTION 7 : Seed data ==="
$seedTypes = @(
    @{ T='Commercial Registration'; Ar='السجل التجاري';               Cat='Registration';   Val=12; Mand=$true;  Lead=60; Tiers='120,90,60,30,14,7,1'; Appr='Owner + Compliance + Legal'; Ret=10; Sens='Internal';     ISO='7.5.3' },
    @{ T='Chamber of Commerce';     Ar='الاشتراك بالغرفة التجارية';   Cat='Registration';   Val=12; Mand=$true;  Lead=45; Tiers='90,60,30,14,7,1';     Appr='Owner + Compliance';         Ret=7;  Sens='Internal';     ISO='7.5.3' },
    @{ T='ISO 9001 Certificate';    Ar='شهادة الأيزو 9001';            Cat='Certification';  Val=36; Mand=$true;  Lead=120;Tiers='180,120,90,60,30,14'; Appr='Owner + Compliance';         Ret=10; Sens='Public';       ISO='7.5.3' },
    @{ T='Zakat & Tax Certificate'; Ar='شهادة الزكاة والضريبة';        Cat='Certification';  Val=12; Mand=$true;  Lead=30; Tiers='90,60,30,14,7,1';     Appr='Owner + Compliance';         Ret=10; Sens='Confidential'; ISO='7.5.3' },
    @{ T='GOSI Certificate';        Ar='شهادة التأمينات الاجتماعية';   Cat='Certification';  Val=3;  Mand=$true;  Lead=14; Tiers='30,14,7,3,1';         Appr='Owner Only';                 Ret=7;  Sens='Confidential'; ISO='7.5.3' },
    @{ T='Saudization Certificate'; Ar='شهادة السعودة (نطاقات)';       Cat='Certification';  Val=3;  Mand=$true;  Lead=14; Tiers='30,14,7,3,1';         Appr='Owner Only';                 Ret=7;  Sens='Internal';     ISO='7.5.3' },
    @{ T='Municipality License';    Ar='رخصة البلدية';                 Cat='License';        Val=12; Mand=$true;  Lead=45; Tiers='90,60,30,14,7,1';     Appr='Owner + Compliance';         Ret=7;  Sens='Internal';     ISO='7.5.3' },
    @{ T='Client Contract';         Ar='عقد عميل';                     Cat='Contract';       Val=0;  Mand=$false; Lead=90; Tiers='180,120,90,60,30';    Appr='Owner + Compliance + Legal'; Ret=10; Sens='Confidential'; ISO='7.5.3' },
    @{ T='Insurance Policy';        Ar='وثيقة تأمين';                  Cat='Insurance';      Val=12; Mand=$true;  Lead=45; Tiers='90,60,30,14,7,1';     Appr='Owner + Compliance';         Ret=7;  Sens='Confidential'; ISO='7.5.3' },
    @{ T='Bank Guarantee';          Ar='ضمان بنكي';                    Cat='Financial';      Val=0;  Mand=$false; Lead=60; Tiers='120,90,60,30,14,7,1'; Appr='Executive';                  Ret=10; Sens='Restricted';   ISO='7.5.3' }
)

foreach ($t in $seedTypes) {
    $exists = Get-PnPListItem -List 'EDMS_DocumentTypes' -Query `
        "<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>$($t.T)</Value></Eq></Where></Query></View>"
    if ($exists.Count -gt 0) { Write-Step "  · type '$($t.T)' exists" 'WARN'; continue }
    Add-PnPListItem -List 'EDMS_DocumentTypes' -Values @{
        Title                 = $t.T
        TypeNameAr            = $t.Ar
        TypeCategory          = $t.Cat
        DefaultValidityMonths = $t.Val
        IsMandatory           = $t.Mand
        RenewalLeadDays       = $t.Lead
        ReminderTiers         = $t.Tiers
        NotifyChannels        = @('Email','Teams','InApp')
        ApprovalTemplate      = $t.Appr
        RetentionYears        = $t.Ret
        SensitivityTier       = $t.Sens
        ISOClause             = $t.ISO
    } | Out-Null
    Write-Step "  + document type '$($t.T)'" 'OK'
}

# Config defaults
$configDefaults = @(
    @{ K='NotificationSenderMailbox'; V='documents@company.com';        S='Global' },
    @{ K='EscalationTierDays';        V='30';                          S='Global' },
    @{ K='ExecEscalationTierDays';    V='7';                           S='Global' },
    @{ K='SmsGatewayEndpoint';        V='https://el.cloud.unifonic.com/rest/SMS/messages'; S='Global' },
    @{ K='SmsEnabled';                V='false';                       S='Global' },
    @{ K='TimeZone';                  V='Asia/Riyadh';                 S='Global' },
    @{ K='WeeklyDigestDay';           V='Sunday';                      S='Global' },
    @{ K='DisposalReviewLeadDays';    V='90';                          S='Global' }
)
foreach ($c in $configDefaults) {
    $e = Get-PnPListItem -List 'EDMS_Config' -Query "<View><Query><Where><Eq><FieldRef Name='Title'/><Value Type='Text'>$($c.K)</Value></Eq></Where></Query></View>"
    if ($e.Count -eq 0) {
        Add-PnPListItem -List 'EDMS_Config' -Values @{ Title=$c.K; ConfigValue=$c.V; ConfigScope=$c.S } | Out-Null
        Write-Step "  + config '$($c.K)'" 'OK'
    }
}


# ==============================================================================
# 8. SUMMARY
# ==============================================================================
Write-Step "=== PROVISIONING COMPLETE ===" 'OK'
$script:Log | Group-Object Level | ForEach-Object { Write-Host ("  {0,-5} : {1}" -f $_.Name, $_.Count) }
$logPath = Join-Path $PSScriptRoot ("EDMS-Provision-{0:yyyyMMdd-HHmmss}.csv" -f (Get-Date))
$script:Log | Export-Csv -Path $logPath -NoTypeInformation -Encoding UTF8
Write-Step "Log written to $logPath" 'OK'

Disconnect-PnPOnline
