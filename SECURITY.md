# Security and privacy

## Reporting a problem

Open a GitHub issue for reproducible functional problems that do not contain
sensitive subscriber information. For a potential security vulnerability,
contact the repository owner privately instead of posting exploit details in a
public issue.

## Diagnostic data

`Diagnostics.cmd` is designed not to collect IMEI, IMSI, phone number, SIM
identifiers, APN credentials, or account data. It reports:

- Windows and PowerShell versions
- Quectel adapter and driver metadata
- MBN interface, registration, data-class, and radio state
- recent switch logs

Review diagnostic text before publishing it if you have modified the script or
added local logging.

## Privilege boundary

RAT changes require elevation because they disconnect mobile broadband and can
cycle the cellular software radio. Status and diagnostics modes do not request
elevation. The project does not bypass OEM, carrier, QDU, or AT-command access
controls.
