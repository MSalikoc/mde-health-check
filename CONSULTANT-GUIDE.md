# The consultant's guide

What the tooling fills, what the customer answers, and what is left to you — plus the rules for the
judgements you are asked to make.

This replaces `MANUAL-FIELDS.md`. Everything below was measured against a rendered report, not
recalled: a typical report leaves around 380 labelled rows with something still to enter, but only
about 40 of those are decisions. The rest is transcription.

---

## Where the report gets its content

| Source | Fills | Marked |
|---|---|---|
| `MDE-Collect.ps1` → JSON | inventory, configuration compliance, alerts, vulnerabilities, licences, ASR, indicators, device groups | **(REVIEW)** where the renderer wrote prose |
| `New-Survey.ps1` → customer answers | 52 fields no API exposes | **(REVIEW)** and prefixed `Self-reported:` |
| The renderer, derived | maturity levels, both cover KPIs, roadmap horizons, findings due dates, misconfiguration table | **(REVIEW)** |
| **You** | everything below | — |

A **(REVIEW)** mark means a machine wrote it and you have not yet agreed. Click each one to approve.
A `Self-reported:` prefix means the customer asserted it and nothing verified it — that distinction
belongs in the report, so do not remove the prefix when you approve the text.

---

## Your work, in the order you will do it

### 1 · Before the visit

Generate the questionnaire and read it. It is your instrument; if a question does not suit this
customer, edit `survey-questions.psd1` before you send it.

### 2 · After the collection, before writing anything

Read the **Collection Notes** page at the end of the report first. It lists what failed and what was
skipped, and it changes how you read everything else — a section that looks clean because nothing
was collected is not clean. Remove that page before issuing, with the button on it.

Then check three numbers against the console output: onboarding rate, sensor health, and the count of
security recommendations. A zero where the estate clearly has devices means the collection was
scoped out, not that the estate is perfect.

### 3 · The narrative

Nothing writes these for you, and nothing should:

| Field | Section |
|---|---|
| Executive summary, risk statement, strengths | 02 |
| Observation, impact and recommendation on each detailed finding | 17.1 |
| Assessment note under most tables | throughout |
| Next assessment date, metrics to re-measure | Appendix B |
| Sign-off, revision history, contacts | 01, Appendix B |

The renderer drafts an executive summary from the findings. Treat it as a starting sentence, not a
paragraph you can ship — it knows the numbers and nothing about the customer.

### 4 · The judgements

These are yours because a rule cannot make them. The rubrics are in the next section.

- **Severity** on every finding
- **Effort** and **owner** on every finding and every roadmap line — the roadmap generates effort
  from severity, which is an assumption, not a measurement
- **Which roadmap horizon** a line belongs in, when procurement or change control makes the
  generated placement wrong
- **Maturity target and target date** at the top of Section 18

### 5 · The transcription

Fields where the answer exists somewhere but no API returns it. Most are one lookup each:

| Section | What is left | Where to get it |
|---|---|---|
| 04 Onboarding | Onboarding method per platform | Intune, or the customer |
| 05 Sensor health | Required URLs allow-listed, client analyzer results | run the client analyzer |
| 06 Antivirus | cloud block level, sample submission, scan schedule | Intune policy export |
| 07 ASR | per-rule mode where policy is in Group Policy | GPO report |
| 09 TVM | vulnerability trend over months | see the note below |
| 11 Baselines | policy authority, conflicts, drift detection | Intune |
| 12 EDR | MITRE tactic breakdown, alert tuning practice | portal + interview |
| 14 SecOps | MTTD/MTTR targets | the customer's own service level |
| 15 RBAC | role assignments and permissions per role | Entra roles blade |
| 16 Integrations | the remaining advanced-feature switches | Defender portal, Advanced features |
| 17 Compliance | which frameworks the client is actually audited against | the customer |

**The vulnerability trend chart stays manual on purpose.** Advanced Hunting keeps 30 days, so there
is no history to collect — not now and not next month. Fill the series from the customer's own
records, or delete the chart for that engagement.

---

## Scoring rules

### Control Compliance (cover)

```
Compliant ÷ Assessed
```

`Assessed` counts only Appendix A rows whose status is Compliant, Partial or Non-compliant. Rows left
`Not assessed` and rows marked `N/A` are excluded from both sides. `Partial` counts as zero, and its
count is stated separately.

**Never divide by 110.** On a tenant where 31 of the 110 rows were determinable, dividing by 110 gives
13% and tells the customer their estate is catastrophic when four fifths of the checklist was simply
never measured. That single choice is the difference between an assessment and an accusation.

This is generated now, with the denominator printed beneath it. You are approving a number, not
reading one off a screen: if you cannot defend the formula, do not approve the figure.

### Maturity levels

| Level | Name | Meaning | Domain score |
|---|---|---|---|
| 1 | Initial | No standard; controls unconfigured or unmeasured | 0–29 |
| 2 | Defined | A standard exists on paper, applied unevenly | 30–59 |
| 3 | Managed | Applied to most of the estate; gaps known and tracked | 60–84 |
| 4 | Integrated | Applied nearly everywhere; deviations monitored, exceptions approved | 85–94 |
| 5 | Optimised | Sustained; drift detected automatically and tested | 95–100 |

The 95 and 60 boundaries are the same thresholds the checklist uses for Compliant and Partial, so a
domain cannot read "Managed" while its underlying controls read non-compliant. The bands live in one
place in code — the `Level` function — shared by the chart, the Section 18 table and the cover.

**Overall** is the mean of the domains that have a score, rounded down, capped at 3 if any core domain
sits at level 1. An estate cannot honestly be called Managed while an entire control family is at
Initial.

Three domains — threat hunting, integration, governance — have no measurable source and stay blank
unless you score them yourself.

**A level is an average, and an average hides things.** Where the mean conceals a control that matters
more than the rest, the key action column names it. Read that before reading the level.

### Severity

Take the highest row that applies. These match the definitions printed in Section 01, so the report
does not contradict itself.

| Severity | Applies when | Remediate |
|---|---|---|
| Critical | Exploitable now with no compensating control, or protection absent on production systems | immediately |
| High | Significant exposure with a realistic attack path; a compensating control may exist but is partial | 30 days |
| Medium | Moderate risk, or a control operating below its intended effectiveness | 90 days |
| Low | Hardening or optimisation with limited immediate risk | routine work |

Severity is about the exposure the gap creates, never about how hard it is to fix. Effort is a
separate column precisely so the two cannot contaminate each other.

### Effort

Low ≤ 1 day · Medium ≤ 2 weeks · High > 2 weeks, or needs budget or a new capability.

The roadmap derives effort from severity — Critical becomes Low, High becomes Medium — which asserts
that every critical finding is cheap to fix. Re-set it. Until you do, the Effort vs Impact matrix
plots severity against itself and cannot tell you anything the register did not.

---

## Rules that keep the report honest

**Never invent a number.** If a field cannot be sourced, leave it blank and say in the surrounding
text why it could not be assessed. A blank is a finding; a guess is a liability.

**Keep `Self-reported:` on customer answers.** An assertion and an observation are different claims.

**Say what was not measured.** "Not assessed" on 79 checklist rows is a legitimate result and belongs
in the report as plainly as the 31 that were.

**Where the data contradicts the customer, say both.** A tenant reporting tamper protection compliant
on 11% of devices while the customer believes it is enforced everywhere is one of the most useful
findings a health check can produce.

---

## Issuing it

1. Approve every **(REVIEW)** mark — the toolbar counter shows how many remain.
2. Fill the blanks above.
3. Remove the **Collection Notes** page with its own button.
4. **Save final** — a locked copy: no editing, no scripts, charts baked in.
5. PDF: Ctrl+P, margins none, **Background graphics** ticked.

**Save working copy** is the other button, and it stays editable. That one is for you.
