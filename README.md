# Microsoft Defender for Endpoint — Health Check

Collects read-only data from an MDE tenant, compares it against best practice, and produces an editable assessment report. The report is in English; the tooling is PowerShell 7.

Every generated comment is marked **(REVIEW)**. The consultant reads and approves each one individually — when no marks remain, the health check is complete.

| File | Purpose |
|---|---|
| `New-MdeApp.ps1` | **Prerequisite step.** Creates the Entra app registration, permissions and admin consent |
| `MDE-Collect.ps1` | Collects tenant data → `mde-assessment-data.json` |
| `MDE-Render.ps1` | Merges the JSON into the template → populated report |
| `Run-Assessment.ps1` | Runs collection and rendering in a single command |
| `Test-Parse.ps1` | Syntax check (run this first when troubleshooting) |
| `MDE-Health-Assessment-Template.html` | Empty 24-section report template |
| `MDE-Health-Assessment-SAMPLE.html` | Version filled with sample data (fictional Northwind Holding) |
| `MDE-Health-Assessment-Template.docx` | Word version of the same report |
| `sample-data.json` | For testing the renderer without a tenant |
| `BASLA-WINDOWS.md` | Short command sequence (Turkish) |

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

**Roles required in the tenant:**

| Role | Needed for |
|---|---|
| **Security Reader** | Defender data: alerts, incidents, Secure Score, TVM, Advanced Hunting |
| **Global Reader** | Licences, directory roles, PIM, Conditional Access, Intune policies |
| **Global Administrator** | Only for the app registration and consent in Step 3 (one time) |

> If **Defender RBAC** is enabled in the tenant, the account must be assigned to a role with access to all device groups. Otherwise inventory and vulnerability counts come back partial even when the permissions are correct.

## Step 1 · Get the files

```powershell
git clone https://github.com/MSalikoc/mde-health-check.git
```

```powershell
cd mde-health-check
```

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

You should see `OK` for all five scripts. If it reports `HATA`, it prints the line and column — share that output.

## Step 3 · Entra app registration (one time)

The default ClientId (Azure CLI) is only authorised for directory reads and **has no Defender permissions**. Running with it returns the tenant name and licences, and `403` for everything else.

```powershell
.\New-MdeApp.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6
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

## Step 4 · Collect the data and produce the report

One command — collects, renders and opens the report in the browser. You do not need `-ClientId`; `.mde-app.json` is read automatically:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -Logo microsoft
```

A device code appears again; this time sign in with the account holding **Security Reader + Global Reader** (it can be the same account).

**Start with a narrow scope on the first run** — it finishes in a minute or two and surfaces permission problems immediately:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -GraphOnly -AlertDays 7 -EventDays 7
```

### Running the steps separately

```powershell
.\MDE-Collect.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -RawDumpPath .\raw -Verbose
```

```powershell
.\MDE-Render.ps1 -DataFile .\mde-assessment-data.json -Template .\MDE-Health-Assessment-Template.html -ClientName "Contoso A.S." -Logo microsoft
```

## Step 5 · Finish the report

The folder will contain:

- `mde-assessment-data.json` — the collected raw data (**editable by hand**)
- `raw\` — raw output of every API/KQL call (troubleshooting)
- `<Client>-MDE-Assessment-<date>.html` — the report

Open the report in a browser:

1. The counter in the toolbar shows how many **(REVIEW)** drafts remain
2. Read each draft; if it is correct, **click the (REVIEW) tag** (or `Alt+click` anywhere in the text) — the mark disappears, the text stays
3. If it is wrong, click the text, correct it, then clear the tag
4. Grey italic placeholders are fields that could not be filled automatically — write them yourself
5. When the counter reaches zero: **Ctrl+P → Save as PDF** (margins: none, background graphics: on)

> There is deliberately no "clear all" button. Every draft is meant to be read individually.

To correct the JSON by hand and re-render the report:

```powershell
.\Run-Assessment.ps1 -TenantId af80ebe6-b601-49c4-89b9-381499b97ba6 -SkipCollect
```

---

# Parameters

### Run-Assessment.ps1

| Parameter | Description |
|---|---|
| `-TenantId` | Tenant GUID or `xxx.onmicrosoft.com` (required) |
| `-ClientId` | App registration ID (read from `.mde-app.json` when omitted) |
| `-ClientName "Contoso A.S."` | Client name on the cover (tenant name when omitted) |
| `-Logo microsoft` | Cover logo: `template` / `microsoft` / `none` |
| `-CreateApp` | Create the app registration in the same run (Step 3 + 4 together) |
| `-GraphOnly` | Skip `api.securitycenter.microsoft.com` calls |
| `-AlertDays 90` / `-EventDays 30` | Telemetry windows |
| `-SkipCollect` | Skip collection and re-render from the existing JSON |
| `-Template <path>` | Use a different template file |

### MDE-Collect.ps1 (additional)

| Parameter | Description |
|---|---|
| `-RawDumpPath .\raw` | Write raw API/KQL output to disk |
| `-OutFile` | JSON output path |
| `-Verbose` | Detailed progress |

### MDE-Render.ps1 (additional)

| Parameter | Description |
|---|---|
| `-HideDataTables` | Start with chart data tables hidden (cleaner for delivery) |
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
