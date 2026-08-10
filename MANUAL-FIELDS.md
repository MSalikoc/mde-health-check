# Manual fields — what goes in them, and on what basis

A rendered report contains two kinds of incomplete field, and they are not the same thing:

| | What it means | What you do |
|---|---|---|
| Yellow **(REVIEW)** mark | The renderer generated this from collected data | Read it, correct it if wrong, click to approve |
| Empty grey field | No data source exists for it | Fill it using this document |

A typical report has around 770 empty fields, but only about 40 distinct decisions — the rest are
repeating cells in the findings, roadmap and checklist tables. This document covers the decisions.

**Sections 1 and 2 below are now generated** and arrive with a (REVIEW) mark. They are documented
here because you are approving a number, not reading one off a screen: if you cannot defend the
formula, do not approve the figure.

**The rule that overrides everything else:** never invent a number. If a field cannot be sourced,
leave it blank and say in the surrounding text why it could not be assessed. A blank is a finding;
a guess is a liability.

---

## 1 · Control Compliance (cover)

```
Control Compliance = Compliant ÷ Assessed
```

where **Assessed** counts only Appendix A rows whose status is `Compliant`, `Partial` or
`Non-compliant`. Rows left `Not assessed` and rows marked `N/A` are excluded from both sides.

`Partial` counts as **zero**, not as half. Half credit is a second arbitrary decision you would have
to defend in the room; instead state the partial count next to the percentage.

The description line under the KPI must always carry the denominator:

> 14 of 31 assessed controls compliant (6 partial, 11 non-compliant) · 79 of 110 not assessed

That example is the August 2026 test tenant: 45% by this formula.

**Do not divide by 110.** On the August 2026 test tenant only 31 of the 110 rows were determinable;
dividing by 110 yields 13% and tells the customer their estate is catastrophic when the truth is
that four fifths of the checklist was never measured. That single choice is the difference between
an assessment and an accusation.

---

## 2 · Maturity

The template names the five levels but has never defined them. These are the definitions.

| Level | Name | Meaning | Domain score |
|---|---|---|---|
| 1 | Initial | Capability present but unconfigured or unmeasured; no standard exists | 0–29 |
| 2 | Defined | A standard exists on paper; applied to part of the estate, unevenly | 30–59 |
| 3 | Managed | Standard applied to most of the estate; gaps are known and tracked | 60–84 |
| 4 | Integrated | Applied nearly everywhere; deviations monitored, exceptions approved | 85–94 |
| 5 | Optimised | Sustained coverage; drift detected automatically and tested regularly | 95–100 |

The 95 and 60 boundaries are deliberately the same thresholds the checklist already uses for
`Compliant` and `Partial`, so a domain cannot be "Managed" while its underlying controls read
non-compliant.

These bands live in one place in code — the `Level` function in [`MDE-Render.ps1`](MDE-Render.ps1).
The chart, the Section 18 table and the cover KPI all read it. Do not compute a level anywhere else;
if the three drift apart the report contradicts itself in front of the client.

### Overall maturity

```
Overall = floor(mean of the domains that have a score)
capped at 3 if any core domain sits at level 1
```

Core domains are deployment, next-generation protection, attack surface reduction, vulnerability
management and EDR. The cap exists because an estate cannot honestly be called "Managed overall"
while an entire control family is at Initial — on the test tenant, ASR is compliant on 0% of
devices, and an unweighted mean would still have returned 2 to 3.

Domains with no score are excluded from the mean; they are not counted as zero. State in the text
which domains were assessed.

### Where the domain scores come from

| Domain | Source | Automatic |
|---|---|---|
| Deployment & onboarding | `Onboarding Rate` KPI | yes |
| Next-generation protection | mean compliance of `secureConfiguration` rows, subcategory `Antivirus` | yes |
| Attack surface reduction | same, subcategory `Attack Surface Reduction` | yes |
| Vulnerability management | `Secure score for devices` KPI | yes |
| EDR & automation | same, subcategory `EDR` | yes |
| Security operations | resolved alerts ÷ total alerts (90 d) | yes, but see below |
| Threat hunting & intelligence | — | manual |
| Integration & SIEM | — | manual |
| Governance & RBAC | — | manual |

**Suppress the security-operations score when the alert count is below 20.** On the test tenant a
single alert, unresolved, produced a domain score of 0 — a number with no statistical meaning that
nonetheless drags the overall figure down. With too few alerts, leave the domain blank and say so.

**Two further limits worth stating in the methodology section:** 64 of the 128 `secureConfiguration`
rows carry no subcategory at all, so half the collected controls feed no domain score; and three
different domain lists exist in the tool today — Section 18 names nine domains, the chart plots
eight labels, and the renderer computes eight under different names again. Section 18's list is the
canonical one; the other two should be aligned to it.

---

## 3 · Findings register

| Column | Basis |
|---|---|
| Severity | rubric below — decided by exposure, not by feeling |
| Effort | Low ≤ 1 day of work · Medium ≤ 2 weeks · High > 2 weeks or needs budget |
| Owner | a named team that has agreed to it, never "IT" |
| Due | Critical 30 days · High 90 days · Medium 180 days · Low next review |
| Status | Open at issue; only the customer moves it |

**Severity rubric** — take the highest row that applies:

| Severity | Applies when |
|---|---|
| Critical | A protection control is off or ineffective across the estate, or devices carry no sensor at all — exploitation needs no privilege and nothing would detect it |
| High | A control is missing on a material subset, or a compensating control exists but is unverified |
| Medium | Coverage is broadly in place; gaps are bounded, monitored, or exploitable only with existing access |
| Low | Hygiene, documentation and drift that carry no direct exploitation path |

Severity is about the exposure the gap creates, not about how hard it is to fix. Effort is a
separate column precisely so that the two never contaminate each other.

---

## 4 · Roadmap and priority matrix

The three horizon tables are **generated**, one row per finding, placed by severity: Critical and
High into Quick Wins (30 days), Medium into Short Term (90 days), Low into Strategic (12 months).
Action and expected outcome are written from the finding ID. Every generated cell carries a
(REVIEW) mark.

You still own three things:

| Field | Why it is yours |
|---|---|
| Owner | Never generated — no data source names a team. A roadmap with no owner is a wish |
| Effort | Generated as `Critical → Low`, `High → Medium`, everything else `Medium`. That is an assumption, not a measurement: it asserts every critical finding is cheap to fix. Re-set it against the Low ≤ 1 day / Medium ≤ 2 weeks / High > 2 weeks scale in section 3 |
| Impact | Generated as a copy of severity |

Because effort and impact both derive from severity today, the Effort vs Impact matrix restates
severity on both axes and cannot tell you anything the register did not. It only becomes an
analytical tool once you have re-set the effort column by hand.

**Implementation Phases** and the **Priority Matrix** grid are not generated at all.

Re-placing a row across horizons is legitimate — a High finding that needs procurement belongs in
Strategic — but say why in the surrounding text, because the register will still show it as High.

Every roadmap line must trace to a finding ID in the register. An action with no finding behind it
is an opinion, and the customer will find it.

---

## 5 · Portal-only facts

No API supplies these. Look them up, write down what you saw, and record the date — they are the
fields most likely to be stale by the time the report is issued.

| Field | Where |
|---|---|
| Data storage region | Settings → Endpoints → Data retention |
| Data retention period | same page (30–180 days) |
| Preview features | Settings → Endpoints → Advanced features |
| Alert notification rules | Settings → Endpoints → Email notifications |
| Time zone / portal locale | Settings → Endpoints → General |
| Onboarding method per platform | Settings → Endpoints → Onboarding (Intune / GPO / script) |
| Proxy / firewall method | client analyzer output, not the portal |
| Required URLs allow-listed | client analyzer output |
| Streamlined connectivity | Settings → Endpoints → Onboarding, connectivity type |
| Auto-remediation level per group | Settings → Endpoints → Device groups |
| Network device / IoT discovery | Settings → Device discovery |
| Threat Analytics usage | Threat Analytics blade — no API |
| Sentinel connector health | Azure portal, plus the `Usage` table for ingestion volume |

---

## 6 · Interview-derived fields

The SOC operating model, shift cover, playbook maturity, exercise history, exclusion
justifications and who may run live response cannot be read from any system. They come from the
workshop. Record who said it and when; if a claim could not be corroborated, write that it is
self-reported rather than presenting it as an observation.

---

## 7 · Cover and document control

Consultant, sponsor, version, dates and classification. The revision table is a real record — if
the report goes out twice, both issues belong in it.

Per the working agreement the cover logo is Microsoft and the report carries no other branding.
