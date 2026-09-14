# EDMS — Test Plan / خطة الاختبار
**Version 1.0 · 94 test cases across 9 suites**

Legend — **P1** blocks go-live · **P2** blocks phase sign-off · **P3** backlog

---

## Suite A — Data Model & Provisioning (12 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| A01 | Run `01-Provision-EDMS.ps1` on a clean site | All 10 lists + 1 library created, 0 errors in log | P1 |
| A02 | Re-run the same script unchanged | 0 new objects, all steps report "exists", 0 errors (idempotency) | P1 |
| A03 | Inspect indexed columns on `EDMS_DocumentRegistry` | `ExpiryDate`, `DocStatus`, `DaysToExpire`, `DocumentOwner`, `DocumentNumber`, all 3 lookups indexed | P1 |
| A04 | Create a registry item with `ExpiryDate` blank | Accepted; `IsPerpetual` settable; no flow crash downstream | P1 |
| A05 | Create a registry item with no `DocumentOwner` | **Rejected** — field is required | P1 |
| A06 | Delete a referenced `DocumentType` row | Blocked or cascades per configured lookup behaviour — must not orphan registry rows | P1 |
| A07 | Load 6,000 registry items, open "All Items" | View threshold error **or** clean render — confirm every production view is filtered on an indexed column | P1 |
| A08 | Load 6,000 items, open "Expiring — 30 Days" | Renders in < 3 s, no threshold error | P1 |
| A09 | Create a document type with `ReminderTiers` = `"90,60,30"` | Flow 02 reads exactly 3 tiers | P2 |
| A10 | Enter Arabic text in `Title` and `TypeNameAr` | Stored and retrieved without mojibake; sorts correctly in Arabic locale | P1 |
| A11 | Attach a 260 MB file to the library | Accepted (limit is 250 GB in a library, not 250 MB — that cap is list *attachments*, which are disabled by design) | P2 |
| A12 | Check versioning settings on `EDMS_Files` | 500 major / 10 minor, force check-out ON | P2 |

---

## Suite B — Migration (10 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| B01 | `-DryRun` against production "Official Documents" | Exception CSV produced, **zero rows written** to target | P1 |
| B02 | Source row with date `13/09/2027` | Parsed as 13 Sep 2027, stored as `2027-09-13T12:00:00Z` | P1 |
| B03 | Source row with expiry **before** issue date | Flagged `ERROR` in exception report, not silently imported | P1 |
| B04 | Source row with empty Document Name | Skipped, logged as `ERROR` | P1 |
| B05 | Run migration twice | Second run skips every already-migrated row (duplicate key guard) | P1 |
| B06 | Source Company value not in `EDMS_Companies` | Auto-created, flagged `INFO` "REVIEW REQUIRED" | P2 |
| B07 | Verify record count | `source rows = migrated + skipped + errored` — must balance exactly | P1 |
| B08 | Spot-check 20 random migrated rows against source | 100% field-for-field match including Arabic names | P1 |
| B09 | Simulate HTTP 429 mid-migration | Exponential back-off engages, migration completes, no data loss | P2 |
| B10 | Verify `DocumentUID` uniqueness across all rows | Zero duplicates | P1 |

---

## Suite C — Status Engine (Flow 01) (11 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| C01 | Doc expiring in exactly 31 days | `DaysToExpire=31`, `DocStatus='Valid'`, `RiskBand='Amber'` | P1 |
| C02 | Doc expiring in exactly 30 days | `DocStatus='Expiring Soon'`, `RiskBand='Red'` (boundary) | P1 |
| C03 | Doc expiring **today** | `DaysToExpire=0`, `DocStatus='Expiring Soon'`, not yet Expired | P1 |
| C04 | Doc expired yesterday | `DaysToExpire=-1`, `DocStatus='Expired'`, `RiskBand='Black'` | P1 |
| C05 | Doc with `IsPerpetual=true` | Excluded from the query; `DocStatus` untouched | P1 |
| C06 | Doc already `Archived` | Excluded from the query | P1 |
| C07 | Run the flow twice in one day | Second run updates **0 items** (change-detection guard works) | P1 |
| C08 | Inspect version history after 7 nightly runs | Version count grows only for items that genuinely changed band | P1 |
| C09 | 5,000-item registry | Completes in < 4 min, no 429 errors | P1 |
| C10 | Crossing 31 Dec → 1 Jan | Day maths correct across the year boundary | P2 |
| C11 | Compare `DaysToExpire` column vs. Power BI DAX recalculation | Identical for 100% of rows; any drift raises `Flow Health` alarm | P1 |

---

## Suite D — Notifications (Flow 02) (14 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| D01 | Doc hits a tier day (e.g. 30) | Exactly one email per recipient, `NotificationLog` row written | P1 |
| D02 | **Re-run the flow manually the same day** | **Zero duplicate sends** — idempotency key blocks it | P1 |
| D03 | Doc hits a day that is **not** a configured tier | No notification | P1 |
| D04 | Expired mandatory document | Daily notification until resolved | P1 |
| D05 | Tier ≤ 30 | `Department.EscalationMgr` added to recipients | P1 |
| D06 | Tier ≤ 7 | `Department.ExecSponsor` added | P1 |
| D07 | Owner has an **active** delegation | Delegate added, **owner retained** on the thread | P1 |
| D08 | Owner has an **expired** delegation | Delegate **not** added | P1 |
| D09 | Owner has a **revoked** delegation | Delegate **not** added | P1 |
| D10 | Invalid recipient address | Flow does not fail; `SendStatus='Failed'` + `ErrorDetail` logged; other recipients still receive | P1 |
| D11 | Arabic subject + body | Renders RTL correctly in Outlook desktop, OWA, and iOS Mail | P1 |
| D12 | Deep link in the email | Opens the exact registry item, respects the recipient's permissions | P1 |
| D13 | 200 documents hit a tier on the same day | All sent within the run window, no throttling failure | P2 |
| D14 | Disable Flow 02, wait 26 h | Watchdog flow raises an alert to `#edms-alerts` | P1 |

---

## Suite E — Approvals & Renewal (Flows 03/04) (12 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| E01 | Set `DocStatus='Pending Approval'`, template "Owner + Compliance" | Two sequential approvals created in the right order | P1 |
| E02 | Approver rejects at step 1 | Chain terminates, `DocStatus='Draft'`, step 2 never created | P1 |
| E03 | Approver rejects at step 2 | Step 1 approval preserved in `ApprovalSteps`; status reverts | P1 |
| E04 | All steps approved | `DocStatus='Valid'`, `VersionLabel` incremented, prior version `Superseded` | P1 |
| E05 | Approval untouched for 7 days | Auto-escalation to delegate, then manager | P2 |
| E06 | Start renewal when one is already open | Second request **blocked** (duplicate guard) | P1 |
| E07 | Renewal reaches `TargetDate` unfinished | `SLABreached=true`, escalation fires | P1 |
| E08 | Renewal completed | Registry `ExpiryDate` updated, `LastRenewedOn` stamped, status → `Valid` | P1 |
| E09 | Cancel a renewal mid-flight | Registry status returns to its prior value, no orphan Planner task | P2 |
| E10 | Approver leaves the company (account disabled) | Approval reassigns to the manager rather than hanging forever | P1 |
| E11 | Supersession chain | `SupersedesDocId` / `SupersededByDocId` form a valid, non-circular chain | P2 |
| E12 | Restore a superseded version from history | Prior metadata restored; file version restored from the library | P1 |

---

## Suite F — Security & RBAC (13 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| F01 | **Reader** attempts to edit a registry item | Denied | P1 |
| F02 | **Reader** attempts to open a `Confidential` file | Denied (file-level permission, even though metadata is visible) | P1 |
| F03 | **Document Owner** edits a doc in **another** department | Denied | P1 |
| F04 | **Compliance Officer** attempts to delete a registry item | **Denied** — "Contribute No Delete" role definition | P1 |
| F05 | **Compliance Officer** attempts to delete a version | Denied | P1 |
| F06 | **System Admin** full CRUD | Allowed, every action lands in the audit log | P1 |
| F07 | Delegate acts during the valid window | Allowed | P1 |
| F08 | Delegate acts **after** `ValidUntil` | Denied | P1 |
| F09 | External guest user attempts access | Blocked by the tenant sharing policy for this site | P1 |
| F10 | Download a `Restricted` file on an unmanaged device | Blocked by Conditional Access | P1 |
| F11 | Attempt to share a `Confidential` file externally | Blocked by DLP policy; policy tip shown | P1 |
| F12 | Power BI RLS — dept user opens the dashboard | Sees only their department's rows; verify with "View as role" | P1 |
| F13 | Power BI RLS — Compliance role | Sees all rows | P1 |

---

## Suite G — Audit & Compliance (10 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| G01 | Change a document owner | `AuditLog` row with before/after JSON, actor UPN, UTC timestamp | P1 |
| G02 | Status transition Valid → Expired | Logged with `EventType='StatusChange:Expired'` | P1 |
| G03 | Approval decision | Logged with approver, outcome, comment, timestamp | P1 |
| G04 | Attempt to edit an `AuditLog` row as Compliance Officer | Denied (list is write-once by flow identity only) | P1 |
| G05 | Search the Purview Unified Audit Log for a file download | Event present within 30 min | P1 |
| G06 | Export a full audit trail for one document | Complete chronological history, exportable to Excel/PDF | P1 |
| G07 | Apply a Purview retention label to a document type | Label applied to all matching items | P2 |
| G08 | Attempt to delete an item under a retention label | Blocked by Purview | P1 |
| G09 | PDPL data subject request — export all data for one person | Produced within the regulatory window, complete | P1 |
| G10 | Simulated breach → 72-hour notification runbook | Runbook executed end-to-end in a tabletop exercise | P1 |

---

## Suite H — Backup & Recovery (7 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| H01 | Delete a registry item, restore from recycle bin | Restored with all metadata intact, < 15 min | P1 |
| H02 | Delete after 93 days (second-stage bin purged) | **Recoverable only from the backup product** — this is the test that proves native retention is insufficient | P1 |
| H03 | Full-site restore drill | Meets RTO ≤ 4 h | P1 |
| H04 | Point-in-time restore to 24 h ago | Meets RPO ≤ 1 h | P1 |
| H05 | Restore a single file to a prior version | Correct version restored | P1 |
| H06 | Ransomware simulation — mass encryption of the library | Detected by Defender; restore drill succeeds | P2 |
| H07 | Verify backup job success alerting | A failed backup raises an alert within 1 h | P1 |

---

## Suite I — Performance, UAT & Accessibility (5 cases)

| # | Test | Expected | Pri |
|---|---|---|---|
| I01 | Registry list loads with 10,000 items | Filtered views < 3 s; measure on a throttled 3G profile too | P1 |
| I02 | Power BI dashboard refresh | Completes in < 10 min | P2 |
| I03 | Mobile — SharePoint app, Arabic UI | Views readable, RTL correct, actions usable | P2 |
| I04 | Screen-reader pass on the main views and forms | Status pills expose text, not colour alone (WCAG 1.4.1) | P2 |
| I05 | 15 real users, 5 business days of shadow running against the legacy list | Zero missed expiries; user satisfaction ≥ 4/5 | P1 |

---

## Go / No-Go criteria

| Gate | Threshold |
|---|---|
| P1 pass rate | **100%** |
| P2 pass rate | ≥ 90% |
| Migration exceptions at `ERROR` severity | **0** |
| Shadow-run missed expiries | **0** |
| Rollback plan rehearsed | Yes, signed off |
| DPO / Compliance sign-off (PDPL) | Obtained in writing |

> **Shadow run is non-negotiable.** Run EDMS in parallel with the existing
> "Official Documents" list for two full weeks before decommissioning it. The
> cost of an extra fortnight is trivial; the cost of a lapsed Commercial
> Registration discovered by a client is not.
