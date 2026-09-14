# EDMS — Power Automate Flow Specifications
## مواصفات تدفقات العمل الآلية

> **Licensing rule that governs every design decision below:** flows that use only
> SharePoint, Outlook, Teams, Approvals and Office 365 Users connectors run on the
> **seeded Power Automate rights inside Microsoft 365** — no extra licence.
> The moment a flow touches HTTP, a custom connector, Azure, or SQL it becomes
> **premium**. Therefore premium capability is isolated into **exactly two flows**,
> both owned by a single service account carrying one **Power Automate Process**
> licence ($150/bot/month), rather than licensing 200 users at $15/month each.

---

## FLOW 01 — `EDMS-Nightly-StatusEngine`
**The single most important flow in the system.**

### Why it exists
SharePoint **calculated columns cannot use `[Today]`**. A formula such as
`=ExpiryDate-Today()` freezes at the value it had when the item was last written.
Every hand-built SharePoint expiry tracker fails this way, silently, and the
failure is invisible until a licence lapses. `DaysToExpire`, `DocStatus` and
`RiskBand` are therefore **stamped by this flow**, never calculated.

| Property | Value |
|---|---|
| Trigger | Recurrence — daily, 02:00 Asia/Riyadh |
| Connectors | SharePoint (standard) |
| Licence | Seeded |
| Target runtime | < 4 min for 5,000 items |
| Idempotent | Yes — safe to re-run any number of times per day |

### Logic

```
1. Initialize variable  varToday        (string) = utcNow('yyyy-MM-dd')
2. Initialize variable  varProcessed    (integer) = 0
3. Get items  — EDMS_DocumentRegistry
      Filter Query : DocStatus ne 'Archived' and IsPerpetual ne 1
      Top Count    : 5000
      Pagination   : ON, threshold 100000
      ⚠ Order by ID asc — required for stable pagination
4. Apply to each  (Concurrency ON, degree 20)
   4a. Compose varDays =
       div(
         sub(
           ticks(formatDateTime(item()?['ExpiryDate'],'yyyy-MM-dd')),
           ticks(variables('varToday'))
         ),
         864000000000
       )
   4b. Compose varStatus =
       if(less(outputs('varDays'), 0),          'Expired',
       if(lessOrEquals(outputs('varDays'), 30),  'Expiring Soon',
       if(equals(item()?['DocStatus'],'Under Renewal'), 'Under Renewal',
                                                 'Valid')))
   4c. Compose varRisk =
       if(less(outputs('varDays'), 0),           'Black',
       if(lessOrEquals(outputs('varDays'), 30),  'Red',
       if(lessOrEquals(outputs('varDays'), 90),  'Amber',
                                                 'Green')))
   4d. Condition — WRITE ONLY IF CHANGED
       @or(
         not(equals(item()?['DaysToExpire'], outputs('varDays'))),
         not(equals(item()?['DocStatus'],    outputs('varStatus')))
       )
       ➜ TRUE: Update item (DaysToExpire, DocStatus, RiskBand)
       ➜ FALSE: skip
5. Post summary adaptive card to Teams #document-compliance
```

### Engineering notes
- **Step 4d is not an optimisation, it is a correctness requirement.** Writing
  every item every night burns `Modified`/`Modified By`, destroys the audit
  signal, and generates 5,000 version-history entries per day (1.8M/year) which
  will breach the 50,000-version-per-item ceiling and bloat storage.
- Concurrency 20 is the sweet spot. Above 25, SPO returns HTTP 429 and the
  effective throughput *drops*.
- `ticks()` arithmetic is used rather than `dateDifference()` because
  `dateDifference` returns an ISO-8601 duration string that needs re-parsing.

---

## FLOW 02 — `EDMS-Tiered-Notifications`
### Trigger & licensing
| Property | Value |
|---|---|
| Trigger | Recurrence — daily, 06:00 Asia/Riyadh (after Flow 01) |
| Connectors | SharePoint, Outlook, Teams (all standard) |
| Licence | Seeded |

### The reminder ladder
Tiers are **not hard-coded**. They are read per document type from
`EDMS_DocumentTypes.ReminderTiers` (CSV of day offsets), so Compliance can
retune the cadence without touching the flow. Defaults:

| Document class | Ladder (days before expiry) | Escalation |
|---|---|---|
| GOSI / Saudization (90-day validity) | 30, 14, 7, 3, 1 | Dept owner → manager at 7 |
| CR / Municipality / Insurance | 90, 60, 30, 14, 7, 1 | Manager at 30, Exec at 7 |
| ISO certificates (3-yr validity) | 180, 120, 90, 60, 30, 14 | Manager at 30 |
| Contracts / Bank guarantees | 180, 120, 90, 60, 30 | Exec at 30 |
| **Overdue (all types)** | Daily until resolved | Exec + CEO digest weekly |

### Idempotency — the part most implementations get wrong
A recurrence flow *will* double-fire (service retry, manual re-run, DST-adjacent
edge). Without a guard, 200 people receive the same alert twice and stop trusting
the system. Before every send:

```
Compose varIdemKey =
  concat(item()?['ID'], '|', outputs('varTier'), '|', variables('varToday'))

Get items — EDMS_NotificationLog
  Filter Query: IdempotencyKey eq '@{outputs('varIdemKey')}'

Condition: @equals(length(body('Get_items')?['value']), 0)
  TRUE  ➜ send, then Create item in EDMS_NotificationLog
  FALSE ➜ terminate branch (Succeeded)
```

Create the log entry **after** a successful send, and write `SendStatus='Failed'`
plus `ErrorDetail` on the failure path via **Configure run after → has failed**.
That makes "which alerts did we actually deliver?" an auditable question.

### Recipient resolution (with active delegation)
```
Base recipients = DocumentOwner + BackupOwner
               + Department.DeptOwner
Tier <= 30      + Department.EscalationMgr
Tier <= 7       + Department.ExecSponsor
Always CC       + EDMS Compliance Officers group

THEN substitute any recipient who has an active delegation:
  Get items — EDMS_Delegations
    Filter: Delegator/EMail eq '<upn>'
        and ValidFrom le '<today>'
        and ValidUntil ge '<today>'
        and IsRevoked ne 1
  If found ➜ add Delegate to recipients (do NOT remove Delegator — the
              accountable owner must retain visibility)
```

### Email body — Adaptive Card in Outlook, bilingual
Use **Send an email (V2)** with an HTML body rendered right-to-left for the
Arabic block. Every mail carries: document name (AR + EN), number, type, expiry
date, days remaining, owner, a **direct deep link to the item**, and an
**"Start Renewal"** button that posts to Flow 03 via an HTTP-triggered
child flow (or, licence-free alternative, a hyperlink to a SharePoint
new-item form with query-string prefill).

---

## FLOW 03 — `EDMS-Renewal-Workflow`
| Property | Value |
|---|---|
| Trigger | (a) automatic when `DaysToExpire = RenewalLeadDays`, (b) manual "Start Renewal" |
| Connectors | SharePoint, Approvals, Teams, Planner (all standard) |
| Licence | Seeded |

```
1. Read EDMS_DocumentTypes for the item's type ➜ RenewalLeadDays, ApprovalTemplate
2. Guard: does an open EDMS_RenewalRequests row already exist for this doc?
     RegistryItemId eq <id> and RequestStage ne 'Registered' and RequestStage ne 'Cancelled'
     ➜ if yes, terminate (prevents duplicate renewal threads)
3. Create EDMS_RenewalRequests  (Stage = 'Initiated',
                                  AssignedTo = DocumentOwner,
                                  TargetDate = ExpiryDate - 7 days)
4. Update registry item: DocStatus = 'Under Renewal'
5. Create a Planner task in the department's plan, due TargetDate
6. Post an actionable Adaptive Card to the owner in Teams
7. Wait loop (Do Until Stage = 'Received' OR TargetDate passed)
     — daily nudge if Stage unchanged for 5 days
     — set SLABreached = true when now > TargetDate
8. On 'Received':  branch into the approval chain (Flow 04)
```

**Stage → SLA mapping** (feeds the Power BI cycle-time measure):

| Stage | SLA | Owner |
|---|---|---|
| Initiated → Documents Gathering | 3 business days | Document Owner |
| Documents Gathering → Submitted | 5 business days | Document Owner |
| Submitted → Received | Authority `TypicalLeadDays` | Authority (external) |
| Received → Registered | 2 business days | Compliance |

---

## FLOW 04 — `EDMS-Approval-Chain`
| Property | Value |
|---|---|
| Trigger | Registry item `DocStatus` changes to `Pending Approval` |
| Connectors | SharePoint, Approvals, Outlook, Teams |
| Licence | Seeded |

Sequential chain driven by `DocumentTypes.ApprovalTemplate`:

```
switch(ApprovalTemplate)
  'Owner Only'                      ➜ [DocumentOwner]
  'Owner + Compliance'              ➜ [DocumentOwner] → [ComplianceOwner]
  'Owner + Compliance + Legal'      ➜ [DocumentOwner] → [ComplianceOwner] → [Legal group]
  'Executive'                       ➜ [DocumentOwner] → [ComplianceOwner] → [ExecSponsor]

For each step:
  Create EDMS_ApprovalSteps row (Outcome='Pending', StepOrder=n)
  Start and wait for an approval — "Approve/Reject – First to respond"
    Reminder  : every 2 days
    Timeout   : 7 days ➜ auto-escalate to the delegate, then the manager
  Write back Outcome, RespondedOn, Comments
  If Rejected ➜ DocStatus='Draft', notify submitter with the rejection comment,
                 terminate the chain (no partial approvals left dangling)
All approved ➜ DocStatus='Valid', VersionLabel incremented,
                previous version marked 'Superseded',
                write an AuditLog entry
```

### Digital signature
Two options, decided by budget:

| Option | Cost | Notes |
|---|---|---|
| **Microsoft SharePoint eSignature** (Syntex) | pay-as-you-go, ~$2/envelope | Native, stays in tenant, KSA data residency inherits from M365 tenant |
| **Adobe Acrobat Sign / DocuSign connector** | premium connector + vendor licence | Stronger legal standing for external counterparties; needs the Process licence |

For **internal** approvals, the Approvals connector plus the immutable
`EDMS_ApprovalSteps` record and the Purview audit log already satisfy ISO 9001
clause 7.5.3 "approval before issue". A cryptographic signature is only required
where an **external party** must rely on it.

---

## FLOW 05 — `EDMS-Weekly-Digest`
| Property | Value |
|---|---|
| Trigger | Recurrence — Sunday 07:00 Asia/Riyadh (KSA work week starts Sunday) |
| Connectors | SharePoint, Outlook, Teams |
| Licence | Seeded |

One consolidated mail per department owner, one executive roll-up:

- Expiring in 30 / 60 / 90 days (counts + table)
- Currently expired (red block at the top)
- Renewals in flight with SLA status
- Documents with no owner assigned *(governance gap)*
- Documents not reviewed in > 12 months *(ISO 9001 "review and update")*

**Why a digest matters:** per-document mails train people to filter the sender.
A single weekly mail with an unavoidable red block at the top does not get
filtered.

---

## FLOW 06 — `EDMS-Audit-Capture`
| Property | Value |
|---|---|
| Trigger | SharePoint — When an item is created or modified (registry + renewal lists) |
| Connectors | SharePoint |
| Licence | Seeded |
| Concurrency | **OFF** (ordering matters for the audit trail) |

Writes a `EDMS_AuditLog` row per business event with before/after JSON. Uses
`triggerOutputs()?['body/{VersionNumber}']` to detect whether it is a create
(`1.0`) or an update, and `Get item version` is **not** used — instead the flow
stores the previous state itself, because SPO's version API is slow and rate
limited at volume.

> **Scope discipline:** this flow captures *business* events (status transitions,
> owner changes, approval outcomes). Infrastructure events — logins, permission
> changes, file downloads, sharing — come from the **Purview Unified Audit Log**,
> not from here. Do not reimplement what the platform already records.

---

## FLOW 07 — `EDMS-SMS-Gateway` ⚠ PREMIUM
| Property | Value |
|---|---|
| Trigger | HTTP request (called as a child flow by Flow 02) |
| Connectors | HTTP (**premium**) |
| Licence | **Power Automate Process, $150/bot/month** — one licence covers all callers |
| Owner | `svc-edms-automation@company.com` |

```
POST https://el.cloud.unifonic.com/rest/SMS/messages
Headers: Content-Type: application/x-www-form-urlencoded
Body:    AppSid=@{...}&SenderID=COMPANY&Recipient=@{...}&Body=@{...}
```

**KSA-specific requirements — do not skip:**
1. The alphanumeric **Sender ID must be pre-registered with the CITC** through
   the operator. Unregistered sender IDs are silently dropped by STC/Mobily/Zain.
2. Arabic SMS is UCS-2 encoded → **70 characters per segment**, not 160. Keep
   alerts to one segment or costs triple.
3. Store `AppSid` in **Azure Key Vault** and read it via the Key Vault connector
   — never as a plain-text value in the flow definition, which is visible to
   anyone with edit rights on the flow.
4. SMS is reserved for **tier ≤ 7 days and expired-mandatory** documents only.
   Using it for everything destroys its signal value and is the fastest way to
   get the sender ID blocked for spam.

---

## FLOW 08 — `EDMS-Retention-Disposition`
| Property | Value |
|---|---|
| Trigger | Recurrence — monthly, 1st at 03:00 |
| Connectors | SharePoint |
| Licence | Seeded |

```
For each item where DocStatus = 'Expired'
    and ExpiryDate + DocumentTypes.RetentionYears <= today
  1. Set DisposalDate = today + Config.DisposalReviewLeadDays
  2. Raise an approval to the Compliance Officer: "Approve disposition"
  3. On approval ➜ DocStatus = 'Archived', move file to the Archive library,
                    write AuditLog(EventType='Disposition')
  4. On rejection ➜ extend retention, record the reason
```

> **Never auto-delete.** Disposition is a reviewed, approved, logged act.
> Automatic deletion of a record that later turns out to be under legal hold is
> an unrecoverable compliance failure. Purview **retention labels** should be
> applied in parallel as the authoritative control — this flow manages the
> *business* lifecycle, Purview enforces the *legal* one.

---

## Error handling standard (applies to every flow)

Every flow implements the same three-part pattern:

1. **Scope: Try** — the business logic.
2. **Scope: Catch** — `Configure run after: has failed, is skipped, has timed out`.
   Posts the failure to Teams `#edms-alerts` with `workflow()?['run']?['name']`
   as the correlation id, and writes an `EDMS_AuditLog` row with
   `EventType='FlowFailure'`.
3. **Scope: Finally** — writes the run summary (items processed, notifications
   sent, errors) to `EDMS_AuditLog`.

**Never let a flow fail silently.** A disabled or erroring notification flow is
functionally identical to having no system at all, and nobody notices for weeks.
Add a **watchdog**: a second flow that checks daily whether Flow 01 and Flow 02
each wrote a run-summary row in the last 26 hours, and escalates if not.
