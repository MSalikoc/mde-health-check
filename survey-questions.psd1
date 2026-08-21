#     Anket soru bankasi.
#
#     Sorular ELLE yazilir - satir etiketini soru diye sormak ("Data storage region")
#     musteriye ne sorduğumuzu anlatmaz. Her sorunun tam cumle bir metni, ne
#     sorduğunu acan bir info notu ve KAPALI bir cevap kumesi vardir; serbest metin
#     yalnizca gercekten acik uclu olan yerde kullanilir.
#
#     id      : kalici kimlik. Satir etiketi degisse bile BOZULMAZ - eslesme target ile yapilir.
#     text    : musterinin gordugu soru
#     info    : nereye bakacagini/neyi kastettigimizi acan not (bos birakilabilir)
#     type    : radio | text
#     answers : radio icin secenekler. 'value' rapordaki durum hucresine gider:
#               pass / partial / fail / na / '' (bilinmiyor)
#     target  : cevabin dolduracagi rapor satiri - New-Survey.ps1 bunu sablona karsi dogrular
@{
    Questions = @(

        # ---------------------------------------------- Tenant & portal ayarlari
        @{
            id = 'Q-DataRegion'
            text = 'In which geography is your Defender for Endpoint data stored?'
            info = 'Chosen once when the tenant was onboarded and not changeable afterwards. Defender portal, Settings > Endpoints > Data retention.'
            type = 'radio'
            answers = @(
                @{ text = 'European Union'; value = 'pass' }
                @{ text = 'United Kingdom'; value = 'pass' }
                @{ text = 'United States'; value = 'pass' }
                @{ text = 'Another region'; value = 'pass' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Licensing & Tenant Configuration'; table = 'Tenant & Portal Configuration'; row = 'Data storage region' }
        }
        @{
            id = 'Q-Retention'
            text = 'How long is device telemetry retained in the Defender portal?'
            info = 'Settings > Endpoints > Data retention. The default is 180 days; a shorter window limits how far back an investigation can look.'
            type = 'radio'
            answers = @(
                @{ text = '180 days (the maximum)'; value = 'pass' }
                @{ text = 'Between 30 and 179 days'; value = 'partial' }
                @{ text = '30 days'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Licensing & Tenant Configuration'; table = 'Tenant & Portal Configuration'; row = 'Data retention period' }
        }
        @{
            id = 'Q-Preview'
            text = 'Are preview features switched on in the Defender portal?'
            info = 'Settings > Endpoints > Advanced features > Preview features. Useful for early access, but changes can appear without notice.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, deliberately'; value = 'pass' }
                @{ text = 'No'; value = 'pass' }
                @{ text = 'Not sure whether they are on'; value = '' }
            )
            target = @{ section = 'Licensing & Tenant Configuration'; table = 'Tenant & Portal Configuration'; row = 'Preview features enabled' }
        }
        @{
            id = 'Q-AlertMail'
            text = 'Who is notified by email when Defender raises an alert, and for which severities?'
            info = 'Settings > Endpoints > Email notifications. Notifications sent to everyone for every severity are usually ignored within weeks.'
            type = 'radio'
            answers = @(
                @{ text = 'A monitored team mailbox, scoped to high severity or above'; value = 'pass' }
                @{ text = 'A team mailbox, all severities'; value = 'partial' }
                @{ text = 'Individual named people'; value = 'partial' }
                @{ text = 'No email notification rules are configured'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Licensing & Tenant Configuration'; table = 'Tenant & Portal Configuration'; row = 'Alert notification rules' }
        }

        # ---------------------------------------------- Baglanti / proxy
        @{
            id = 'Q-ProxyMethod'
            text = 'How do endpoints reach the Defender cloud service?'
            info = 'A direct route, or through a proxy. This determines which URLs have to be allowed and where a connection can be broken.'
            type = 'radio'
            answers = @(
                @{ text = 'Directly, no proxy'; value = 'pass' }
                @{ text = 'Through a proxy configured for the system (WinHTTP)'; value = 'pass' }
                @{ text = 'Through a proxy discovered automatically (PAC / WPAD)'; value = 'partial' }
                @{ text = 'Through a proxy set per user in the browser'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Sensor Health & Connectivity'; table = 'Connectivity Configuration'; row = 'Proxy / firewall method' }
        }
        @{
            id = 'Q-TlsBypass'
            text = 'Is the Defender service traffic excluded from TLS inspection?'
            info = 'Where a proxy inspects TLS, the Defender endpoints must be excluded or the sensor cannot present its certificate and reporting fails intermittently.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, the Defender URLs bypass inspection'; value = 'pass' }
                @{ text = 'No, they are inspected like everything else'; value = 'fail' }
                @{ text = 'There is no TLS inspection in the environment'; value = 'na' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Sensor Health & Connectivity'; table = 'Connectivity Configuration'; row = 'SSL inspection bypass in place' }
        }

        # ---------------------------------------------- Cihaz kontrolu
        @{
            id = 'Q-UsbControl'
            text = 'Is the use of USB storage on endpoints restricted?'
            info = 'Device control policy in Intune or Group Policy. Removable media remains one of the most common ways malware arrives on an isolated network.'
            type = 'radio'
            answers = @(
                @{ text = 'Blocked entirely, with named exceptions'; value = 'pass' }
                @{ text = 'Read-only'; value = 'pass' }
                @{ text = 'Allowed but audited'; value = 'partial' }
                @{ text = 'No restriction'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Attack Surface: Network, Device, Application'; table = 'Device Control & Peripheral Security'; row = 'Removable storage access control (USB)' }
        }
        @{
            id = 'Q-PrinterProtection'
            text = 'Is printing to unapproved or network printers restricted?'
            info = 'Printer protection in the device control policy. Often overlooked, and a route for data to leave without touching the network.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, restricted to approved printers'; value = 'pass' }
                @{ text = 'No restriction'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Attack Surface: Network, Device, Application'; table = 'Device Control & Peripheral Security'; row = 'Printer protection' }
        }
        @{
            id = 'Q-DeviceInstall'
            text = 'Can users install any device driver or peripheral they connect?'
            info = 'Device installation restrictions, usually an allow-list by hardware ID. Unrestricted installation lets a vulnerable signed driver be introduced deliberately.'
            type = 'radio'
            answers = @(
                @{ text = 'No, only approved hardware IDs may install'; value = 'pass' }
                @{ text = 'Restricted for some device classes only'; value = 'partial' }
                @{ text = 'Yes, anything may be installed'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Attack Surface: Network, Device, Application'; table = 'Device Control & Peripheral Security'; row = 'Device installation restrictions' }
        }

        # ---------------------------------------------- Uygulama / exploit korumasi
        @{
            id = 'Q-AppControl'
            text = 'Is application control (WDAC or AppLocker) enforced on endpoints?'
            info = 'Application control decides which executables may run at all. Audit mode records what would have been blocked but blocks nothing.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, enforced in block mode'; value = 'pass' }
                @{ text = 'Deployed in audit mode only'; value = 'partial' }
                @{ text = 'On a limited set of devices, such as kiosks or servers'; value = 'partial' }
                @{ text = 'Not deployed'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Attack Surface: Network, Device, Application'; table = 'Application & Exploit Protection'; row = 'App Control for Business (WDAC)' }
        }
        @{
            id = 'Q-ExploitProtection'
            text = 'Are exploit protection mitigations configured beyond the Windows defaults?'
            info = 'System and per-application mitigations, usually deployed as an exported XML configuration.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, a reviewed configuration is deployed'; value = 'pass' }
                @{ text = 'Windows defaults only'; value = 'partial' }
                @{ text = 'Mitigations have been turned off for compatibility'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Attack Surface: Network, Device, Application'; table = 'Application & Exploit Protection'; row = 'Exploit protection (system & app mitigations)' }
        }
        @{
            id = 'Q-CredGuard'
            text = 'Is Credential Guard running on the Windows estate?'
            info = 'Credential Guard isolates derived credentials so that stealing them from memory no longer works. Requires virtualisation-based security.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, on all supported devices'; value = 'pass' }
                @{ text = 'On part of the estate'; value = 'partial' }
                @{ text = 'Not enabled'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Attack Surface: Network, Device, Application'; table = 'Application & Exploit Protection'; row = 'Credential Guard / LSA protection' }
        }
        @{
            id = 'Q-Hvci'
            text = 'Is memory integrity (HVCI) enabled?'
            info = 'Also shown as "Core isolation - Memory integrity". It stops unsigned or vulnerable drivers loading into the kernel, and is sometimes disabled for driver compatibility.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, across the estate'; value = 'pass' }
                @{ text = 'On part of the estate'; value = 'partial' }
                @{ text = 'Disabled for compatibility'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Attack Surface: Network, Device, Application'; table = 'Application & Exploit Protection'; row = 'Memory integrity (HVCI)' }
        }

        # ---------------------------------------------- Entegrasyonlar
        @{
            id = 'Q-XdrPortal'
            text = 'Do your analysts work from the unified Microsoft Defender portal?'
            info = 'The unified portal correlates endpoint, identity, mail and cloud app signals into a single incident rather than separate alerts.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, it is the primary console'; value = 'pass' }
                @{ text = 'Sometimes, alongside another console'; value = 'partial' }
                @{ text = 'No, another console is used'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Integrations & Data Flow'; table = 'Advanced Features & Integration Switches'; row = 'Microsoft Defender XDR (unified portal / incidents)' }
        }
        @{
            id = 'Q-Mdi'
            text = 'Is Defender for Identity deployed on your domain controllers?'
            info = 'Without it, lateral movement is only visible from the endpoint side and the identity half of an attack goes unseen.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, on all domain controllers'; value = 'pass' }
                @{ text = 'On some domain controllers'; value = 'partial' }
                @{ text = 'Not deployed'; value = 'fail' }
                @{ text = 'There is no on-premises Active Directory'; value = 'na' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Integrations & Data Flow'; table = 'Advanced Features & Integration Switches'; row = 'Microsoft Defender for Identity integration' }
        }
        @{
            id = 'Q-Mdo'
            text = 'Is Defender for Office 365 in use for mail?'
            info = 'It links the delivered message to what happened on the endpoint, which is what makes a phishing investigation possible end to end.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes'; value = 'pass' }
                @{ text = 'A third-party mail security product is used instead'; value = 'partial' }
                @{ text = 'No'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Integrations & Data Flow'; table = 'Advanced Features & Integration Switches'; row = 'Microsoft Defender for Office 365 integration' }
        }
        @{
            id = 'Q-Sentinel'
            text = 'Are Defender alerts and device tables forwarded to a SIEM?'
            info = 'Alerts alone are not enough to hunt outside the Defender portal; the raw device tables are what make that possible.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, alerts, incidents and the raw device tables'; value = 'pass' }
                @{ text = 'Alerts and incidents only'; value = 'partial' }
                @{ text = 'Nothing is forwarded'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Integrations & Data Flow'; table = 'Advanced Features & Integration Switches'; row = 'Microsoft Sentinel connector' }
        }
        @{
            id = 'Q-ThirdPartyAv'
            text = 'Is any non-Microsoft antivirus or EDR still installed alongside Defender?'
            info = 'Two protection agents on one device degrade both. Where one is present, Defender Antivirus usually falls back to passive mode and stops protecting.'
            type = 'radio'
            answers = @(
                @{ text = 'No, Defender is the only agent'; value = 'pass' }
                @{ text = 'Yes, and the coexistence is documented and deliberate'; value = 'partial' }
                @{ text = 'Yes, left over from a previous product'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Integrations & Data Flow'; table = 'Advanced Features & Integration Switches'; row = 'Non-Microsoft AV / EDR coexistence' }
        }
        @{
            id = 'Q-IngestVolume'
            text = 'What is the daily ingestion volume forwarded to your SIEM?'
            info = 'Only needed if data is forwarded. An approximate figure in GB per day is enough.'
            type = 'text'
            target = @{ section = 'Integrations & Data Flow'; table = 'Telemetry & Data Management'; row = 'Daily ingestion volume' }
        }

        # ---------------------------------------------- Zafiyet yonetimi sureci
        @{
            id = 'Q-VulnSla'
            text = 'Is there an agreed deadline for remediating a critical vulnerability?'
            info = 'A published service level, not an intention. This is what turns a vulnerability list into a work queue.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, agreed and measured'; value = 'pass' }
                @{ text = 'An informal expectation, not measured'; value = 'partial' }
                @{ text = 'No'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Vulnerability Management (TVM)'; table = 'Vulnerability Management Capability Review'; row = 'SLA definition for critical CVEs' }
        }
        @{
            id = 'Q-VulnOwner'
            text = 'When a security recommendation is raised, does it reach the team that patches?'
            info = 'Defender can send a remediation request straight into the Intune work queue. Where it does not, the list is read but rarely worked.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, through the Intune remediation workflow'; value = 'pass' }
                @{ text = 'Yes, but manually, by raising a ticket'; value = 'partial' }
                @{ text = 'No, the recommendations are not routed anywhere'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Vulnerability Management (TVM)'; table = 'Vulnerability Management Capability Review'; row = 'Remediation requests -> Intune workflow' }
        }

        # ---------------------------------------------- Hunting / tespit pratigi
        @{
            id = 'Q-HuntCadence'
            text = 'Is threat hunting performed on a schedule?'
            info = 'Hunting done only after an incident finds what you already know about. A cadence is what turns it into a control.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, on a regular schedule'; value = 'pass' }
                @{ text = 'Occasionally, when time allows'; value = 'partial' }
                @{ text = 'Only in response to an incident'; value = 'fail' }
                @{ text = 'Not at all'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Automation, Hunting & Custom Detections'; table = 'Advanced Hunting & Custom Detection Rules'; row = 'Threat hunting programme & cadence' }
        }
        @{
            id = 'Q-RuleReview'
            text = 'Are custom detection rules reviewed and kept under version control?'
            info = 'Rules accumulate. Without review, a rule that stopped firing months ago still looks like coverage.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, reviewed on a schedule and version-controlled'; value = 'pass' }
                @{ text = 'Version-controlled but not reviewed'; value = 'partial' }
                @{ text = 'Neither'; value = 'fail' }
                @{ text = 'There are no custom rules'; value = 'na' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Automation, Hunting & Custom Detections'; table = 'Advanced Hunting & Custom Detection Rules'; row = 'Custom rules reviewed / version-controlled' }
        }
        @{
            id = 'Q-KqlSkill'
            text = 'How would you describe the ability of the team to write hunting queries?'
            info = 'KQL capability is usually the limiting factor for both hunting and custom detections.'
            type = 'radio'
            answers = @(
                @{ text = 'Several analysts write queries confidently'; value = 'pass' }
                @{ text = 'One person can, and the rest rely on them'; value = 'partial' }
                @{ text = 'The team uses shared queries but does not write them'; value = 'partial' }
                @{ text = 'No KQL capability in the team'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Automation, Hunting & Custom Detections'; table = 'Advanced Hunting & Custom Detection Rules'; row = 'Analyst KQL skill level' }
        }
        @{
            id = 'Q-ThreatAnalytics'
            text = 'Are Threat Analytics reports acted on when they are published?'
            info = 'Each report lists the devices in your tenant that are exposed to that campaign, which makes it a work queue rather than reading material.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, exposed devices are remediated'; value = 'pass' }
                @{ text = 'Reports are read but nothing is tracked'; value = 'partial' }
                @{ text = 'Not used'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Automation, Hunting & Custom Detections'; table = 'Threat Analytics & Threat Intelligence'; row = 'Threat analytics reports reviewed' }
        }
        @{
            id = 'Q-TiFeed'
            text = 'Is external threat intelligence fed into Defender as indicators?'
            info = 'Through the indicator API rather than typed in by hand, so the list can be refreshed and expired.'
            type = 'radio'
            answers = @(
                @{ text = 'Yes, automatically from a feed'; value = 'pass' }
                @{ text = 'Indicators are added manually'; value = 'partial' }
                @{ text = 'No external intelligence is used'; value = 'fail' }
                @{ text = 'Not sure'; value = '' }
            )
            target = @{ section = 'Automation, Hunting & Custom Detections'; table = 'Threat Analytics & Threat Intelligence'; row = 'External TI feed integration' }
        }
    )
}
