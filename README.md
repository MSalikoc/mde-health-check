# Microsoft Defender for Endpoint — Health Check

Collects read-only data from an MDE tenant, compares it against best practice, and produces an editable assessment report. The report is in English; the tooling is PowerShell 7.

Every generated comment is marked **(REVIEW)**. The consultant reads and approves each one individually — when no marks remain, the health check is complete.

The customer-side scripts live in a separate **public** repository,
[`MSalikoc/mde-data-collector`](https://github.com/MSalikoc/mde-data-collector) — that is the only
copy of them, so there is never a second, older collector to run by mistake.

| File | Purpose |
|---|---|
| `New-MdeApp.ps1` | **Prerequisite step**, in the collector repo. Creates the Entra app registration, permissions and admin consent |
| `MDE-Collect.ps1` | **Runs at the customer**, in the collector repo. Collects tenant data → JSON only |
| `MDE-Render.ps1` | **Runs at your end.** Merges the JSON into the template → report |
| `Test-Parse.ps1` | Syntax check (run this first when troubleshooting) |
| `MDE-Health-Assessment-Template.html` | Empty 24-section report template |
| `MDE-Health-Assessment-SAMPLE.html` | Version filled with sample data (fictional Contoso) |
| `MDE-Health-Assessment-Template.docx` | Word version of the same report |
| `sample-data.json` | For testing the renderer without a tenant |
| `MANUAL-FIELDS.md` | **What goes in every blank field, and on what basis** — scoring rubrics, portal lookups |
| `New-Survey.ps1` | Builds the customer questionnaire for the fields no API exposes |
| `survey-questions.psd1` | The questions themselves — edit here, not in the generator |
| `BASLA-WINDOWS.md` | Short command sequence (Turkish) |

---

## Which file goes where

Three artefacts move between two machines, and mixing them up is the usual cause of a half-empty
report.

| Artefact | Produced by | Where | Comes back as |
|---|---|---|---|
| `mde-survey-form.html` | `New-Survey.ps1` on **your** machine | handed to the customer | — |
| `mde-data-<tenant>-<date>.json` | `MDE-Collect.ps1` at the **customer** | customer environment | the collected data |
| `mde-survey-<tenant>-<date>.json` | the customer pressing **Download answers** | customer environment | the questionnaire answers |

Both JSON files return to you and both are inputs to the same render. The questionnaire is optional:
leave `-SurveyFile` off and the report is produced exactly as before, with those fields blank for you
to fill by hand.

**Generate the questionnaire before the visit.** It comes from the template, needs no tenant access,
and handing it over during the collection session is what removes the second meeting.

---

# Step by step (PowerShell)

## Step 0 · Prerequisites

**PowerShell 7+ is required.** The "Windows PowerShell 5.1" that ships with Windows (blue icon) cannot run these scripts.

```powershell
winget install --id Microsoft.PowerShell --source winget
```

After installation open a **new PowerShell 7 window** (black icon, `pwsh`) and verify:

```powershell
$PSVersionTable.PSVersion
```

`Major` must be 7 or above.

> In every command below, replace `YOUR-TENANT-ID` with your own tenant GUID or
> `contoso.onmicrosoft.com` domain. Do not wrap it in `< >` — in a shell those are
> redirection operators and the command will fail before it starts.

**Roles required in the tenant:**

| Role | Needed for |
|---|---|
| **Security Reader** | Defender data: alerts, incidents, Secure Score, TVM, Advanced Hunting |
| **Global Reader** | Licences, directory roles, PIM, Conditional Access, Intune policies |
| **Global Administrator** | Only for the app registration and consent in Step 3 (one time) |

> If **Defender RBAC** is enabled in the tenant, the account must be assigned to a role with access to all device groups. Otherwise inventory and vulnerability counts come back partial even when the permissions are correct.

## Step 1 · Get the files

Steps 2–4 run at the customer and use the **collector** repository:

```powershell
git clone https://github.com/MSalikoc/mde-data-collector.git
```

```powershell
cd mde-data-collector
```

Step 5 runs at your end and uses this repository instead — clone it on your own machine only.

Windows blocks `.ps1` files downloaded from the internet (Mark-of-the-Web):

```powershell
Get-ChildItem *.ps1 | Unblock-File
```

If the execution policy is restricted, relax it **for this session only** (no permanent change):

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
```

## Step 2 · Syntax check (30 seconds)

Before running anything, confirm the files arrived intact:

```powershell
.\Test-Parse.ps1
```

It parses every `.ps1` in the folder. If it reports `HATA`, it prints the line and column — share that output.

## Step 3 · Entra app registration (one time)

The default ClientId (Azure CLI) is only authorised for directory reads and **has no Defender permissions**. Running with it returns the tenant name and licences, and `403` for everything else.

```powershell
.\New-MdeApp.ps1 -TenantId YOUR-TENANT-ID
```

A device code appears — sign in at <https://microsoft.com/devicelogin> with a **Global Administrator** account.

The script then:

1. Creates an app registration named `MDE Health Check Collector`
2. Turns on *Allow public client flows* (required for device code)
3. Adds 10 Microsoft Graph and 6 WindowsDefenderATP delegated permissions (permission GUIDs are resolved dynamically from the service principal)
4. Creates the service principal and **grants admin consent**
5. Writes the client ID to `.mde-app.json`

It is idempotent: run it again and it finds the existing registration and fills in any missing permissions.

> Consent can take a minute or two to propagate. If you still get 403 immediately afterwards, try once more.

## Step 4 · Collect the data (customer environment)

This is the only script that runs at the customer. It produces **a single JSON file** and nothing else — no report is generated and no browser is opened, so the customer never sees an unreviewed draft.

```powershell
.\MDE-Collect.ps1 -TenantId YOUR-TENANT-ID
```

A device code appears; sign in with the account holding **Security Reader + Global Reader**.

Output: `mde-data-<tenant>-<date>.json`. The console prints how many KPIs, charts and tables were collected plus any warnings, so you can confirm the collection worked without producing a report.

**Start with a narrow scope on the first run** — it finishes in a minute or two and surfaces permission problems immediately:

```powershell
.\MDE-Collect.ps1 -TenantId YOUR-TENANT-ID -GraphOnly -AlertDays 7 -EventDays 7
```

Add `-RawDumpPath .\raw` only while troubleshooting: it writes the raw output of every API and KQL call to disk, including device and user names.

Take the JSON file with you. It is the only artefact needed for the report.

## Step 4b · Questionnaire (optional, same visit)

Some fields have no API behind them: tenant and portal settings, the advanced-feature switches,
device control, application control, and the practice questions around hunting and vulnerability
management. Rather than going back to the customer after the render, hand them the questionnaire
during the collection visit:

```powershell
.\New-Survey.ps1 -ClientName "Contoso A.S."
```

That writes `mde-survey-form.html` and opens it in your browser so you can look it over before it
goes out — one self-contained file, no install, works offline, nothing transmitted anywhere. Add
`-NoOpen` to skip opening it.

**The customer** opens it in any browser, answers what they know, and presses **Download answers**,
which saves `mde-survey-<tenant>-<date>.json` on their machine. They send that back alongside the
collected JSON.

26 questions across 9 groups today, in the same order as the report:

| Group | Asks about |
|---|---|
| Tenant & Portal Configuration | storage region, retention, preview features, alert notifications |
| Connectivity Configuration | proxy method, TLS inspection bypass |
| Application & Exploit Protection | WDAC/AppLocker, exploit protection, Credential Guard, HVCI |
| Device Control & Peripheral Security | USB, printers, device installation |
| Vulnerability Management Capability | remediation SLA, whether recommendations reach the patching team |
| Advanced Hunting & Custom Detections | hunting cadence, rule review, KQL capability |
| Threat Analytics & Threat Intelligence | whether reports are acted on, external TI feeds |
| Advanced Features & Integration Switches | XDR portal, MDI, MDO, SIEM forwarding, third-party AV |
| Telemetry & Data Management | daily ingestion volume |

Every question is written out in full with a note explaining what is being asked, and the answers are
a closed set rather than free text, so they merge cleanly and mean the same thing every engagement.
"Not sure" is always an option and is more useful than a guess.

The generator checks each question against the template and refuses to invent: a question whose
target row no longer exists is reported, and so is the number of blank fields that have no question
yet (`-ShowUnasked` lists them). The questions live in `survey-questions.psd1`; add to that file, not
to the generator.

## Step 5 · Produce the report (your environment)

Switch to a clone of **this** repository and bring the JSON file with you:

```powershell
.\MDE-Render.ps1 -DataFile .\mde-data-contoso-20260807.json -ClientName "Contoso A.S."
```

With questionnaire answers:

```powershell
.\MDE-Render.ps1 -DataFile .\mde-data-contoso-20260807.json -SurveyFile .\mde-survey-contoso-20260813.json -ClientName "Contoso A.S."
```

### How the two are merged

The questionnaire runs **last**, after every other source has had its turn, and obeys three rules:

1. **Collected data always wins.** An answer only ever fills a cell nothing else could. Where the
   customer answered something the collection already measured, the answer is discarded.
2. **Answers are labelled `Self-reported:`** in the cell. A customer assertion and a measurement are
   different claims and the report should not blur them. They carry the usual **(REVIEW)** mark too,
   so you still approve each one.
3. **An answer matching no row is reported, not ignored** — that means the template moved and the
   question bank needs updating.

The console prints all three counts:

```
Anket: 26 alan dolduruldu
       4 cevap kullanilmadi - o hucreleri toplanan veri zaten doldurmustu
```

The template is picked up automatically from the script folder; use `-Template` only to point at a different one. The report is written next to the JSON and opened in your browser.

The JSON is plain text and editable — correct anything the collector got wrong, or fill in values it could not reach, then run the same command again.

## Step 6 · Finish the report

1. The counter in the toolbar shows how many **(REVIEW)** drafts remain
2. Read each draft; if it is correct, **click the (REVIEW) tag** (or `Alt+click` anywhere in the text) — the mark disappears, the text stays
3. If it is wrong, click the text, correct it, then clear the tag
4. Grey italic placeholders are fields that could not be filled automatically — write them yourself
5. When the counter reaches zero: **Ctrl+P → Save as PDF** (margins: none, background graphics: on)

> There is deliberately no "clear all" button. Every draft is meant to be read individually.

---

# Parameters

### MDE-Collect.ps1

Lives in the collector repo; that repo's README is the authoritative list.

| Parameter | Description |
|---|---|
| `-TenantId` | Tenant GUID or `xxx.onmicrosoft.com` (required) |
| `-ClientId` | App registration ID (read from `.mde-app.json` when omitted) |
| `-GraphOnly` | Skip `api.securitycenter.microsoft.com` calls |
| `-AlertDays 90` / `-EventDays 30` | Telemetry windows |
| `-RawDumpPath .\raw` | Write raw API/KQL output to disk (troubleshooting only) |
| `-OutFile` | JSON output path |
| `-Verbose` | Detailed progress |

### MDE-Render.ps1

| Parameter | Description |
|---|---|
| `-DataFile` | Collected JSON (required) |
| `-ClientName "Contoso A.S."` | Client name on the cover (tenant name when omitted) |
| `-Template <path>` | Template file (auto-detected when omitted) |
| `-HideDataTables` | Start with chart data tables hidden (cleaner for delivery) |
| `-Logo template\|microsoft\|none` | Cover logo (default `template`) |
| `-OutFile` | Report file name |

---

# Permissions

All **delegated** and **read-only**. `New-MdeApp.ps1` adds them and grants consent automatically.

**Microsoft Graph:** `ThreatHunting.Read.All`, `SecurityEvents.Read.All`, `SecurityAlert.Read.All`, `SecurityIncident.Read.All`, `CustomDetection.Read.All`, `DeviceManagementConfiguration.Read.All`, `Directory.Read.All`, `Organization.Read.All`, `Policy.Read.All`, `RoleManagement.Read.Directory`

**WindowsDefenderATP:** `Vulnerability.Read`, `SecurityRecommendation.Read`, `Score.Read`, `Ti.Read`, `Machine.Read`, `AdvancedQuery.Read`

The scripts make no write calls. Any section that fails is skipped and recorded as a warning on the report's "Automated Collection Notes" page.

---

# What is filled automatically

| Report area | Source |
|---|---|
| Device inventory, onboarding rate, platform breakdown | AH `DeviceInfo` |
| Sensor health (active / inactive / impaired) | AH `DeviceInfo.SensorHealthState` |
| AV / ASR / baseline configuration compliance | AH `DeviceTvmSecureConfigurationAssessment` |
| ASR rule modes | Intune `configurationPolicies` + AH `DeviceEvents` |
| Vulnerability breakdown, top software, software inventory | AH `DeviceTvmSoftwareVulnerabilities` |
| Exposure score, security recommendations, indicators | MDE API |
| Secure Score and category breakdown | Graph `security/secureScores` |
| Alert/incident volume, severity, tactic, MTTD/MTTR | Graph `security/alerts_v2`, `incidents` |
| Custom detection rules | Graph `security/rules/detectionRules` |
| Licence inventory | Graph `subscribedSkus` |
| Intune policies, antivirus exclusions | Graph `deviceManagement/configurationPolicies` |
| Privileged roles, PIM, Conditional Access | Graph `directoryRoles`, `conditionalAccess/policies` |
| **Draft findings** | Threshold rules (coverage, tamper, ASR, CVEs, exposure, CA, GA count) |
| **Narrative text** | Collected data + best practice (39 fields) |
| **Control commentary** | Best-practice library (178 keys, ~183 rows) |

# What stays manual

Verifying the executive summary, adapting the risk statement to the client, deciding finding severity, effort/owner/dates, maturity scoring, the priority matrix, revision history and contact details.

Technically impossible: six-month trends (Advanced Hunting retains 30 days), onboarding method (no such field in `DeviceInfo`), AIR automation rates (no API), Threat Analytics usage (no API).

---

# Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `#Requires -Version 7.0` or syntax errors | You are running Windows PowerShell 5.1 → open `pwsh` |
| `... is not digitally signed` | `Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force` |
| `no such file or directory: <tenant>` | Remove the `< >` characters from the command — they were placeholders |
| `AADSTS65001` / `invalid_client` | No app registration or consent not granted → Step 3 |
| Most calls return `403` | The token has no Defender permissions → Step 3. The script lists the missing permissions up front |
| `403` only on securitycenter calls | Continue with `-GraphOnly`; enter the exposure score manually |
| Advanced Hunting returns nothing | `ThreatHunting.Read.All` consent missing, or Defender RBAC is restricting the account |
| Alert collection takes too long | Use `-AlertDays 30` |
| ASR rules show as "not configured" | Derived from Intune when telemetry has no events; rules managed through Group Policy are invisible |
| Turkish characters look broken | Use Windows Terminal instead of conhost |
| Report looks stale / changes not showing | The browser may be loading its saved copy → `Ctrl+Shift+R` |

# Known limits

- **ASR modes** are derived from Intune policies; rules managed through Group Policy are not visible.
- **The exclusion list** is extracted from Intune policies only; Group Policy and local exclusions require live response or a registry query.
- **Advanced Hunting** retains 30 days of data; longer trends must come from Sentinel.
- **Best-practice commentary** is row-level general guidance ("why this control matters, what the target is"); commentary written against the tenant's own values exists only where data is collected.
- Collected data and generated reports are excluded through `.gitignore`, so client data is never committed by accident.
