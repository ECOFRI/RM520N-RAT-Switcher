# Quectel RM520N RAT Switcher for Windows

A small Windows utility for selecting the preferred radio access technologies
(RATs) exposed by a Quectel RM520N mobile-broadband adapter.

[한국어 문서](README-KO.md)

## Highlights

- Uses the Windows Mobile Broadband (MBN) API; no serial AT port is required.
- Detects the data classes reported by the modem and builds the selection UI
  dynamically.
- Includes safe presets for Automatic, LTE only, LTE + 5G NSA, 5G SA, 3G/HSPA,
  2G, and CDMA when the corresponding classes are supported.
- Allows advanced users to combine individual supported data classes.
- Keeps the WinForms UI responsive by running long registration operations in
  a separate elevated PowerShell worker.
- Verifies asynchronous cellular-radio OFF/ON transitions and retries radio
  recovery before reporting a failure.
- Does not read or log IMEI, IMSI, phone number, APN credentials, or SIM data.

## Tested configuration

- Lenovo ThinkPad X1 Carbon Gen 13
- Quectel RM520N-GL connected through PCIe/MHI
- Windows 11 with the Lenovo/Quectel OEM mobile-broadband driver
- SK Telecom 5G NSA

Other Quectel RM520N configurations can work when they expose the standard
Windows MBN interfaces, but have not been hardware-tested by this project.

## Quick start

1. Download and extract the release ZIP. Do not run it from inside the ZIP.
2. Run `RM520N-RAT.cmd`.
3. Accept the UAC prompt.
4. Choose a preset or select individual supported RATs.
5. Select **Apply selection** and keep the window open until radio recovery
   finishes.

The window remains interactive during the switch and shows live progress from
the background worker.

For one-click shortcuts, use:

- `LTE-only.cmd`
- `5G-Auto.cmd`
- `Diagnostics.cmd`

## RAT masks

The utility submits a bitmask of standard MBIM/MBN data classes:

| Data class | Mask |
| --- | ---: |
| GPRS | `0x00000001` |
| EDGE | `0x00000002` |
| UMTS | `0x00000004` |
| HSDPA | `0x00000008` |
| HSUPA | `0x00000010` |
| LTE | `0x00000020` |
| 5G NSA | `0x00000040` |
| 5G SA | `0x00000080` |

For 5G NSA, the UI requires LTE as the anchor, producing `0x60`. The OEM
`Custom` class is shown in diagnostics but cannot be selected because it
requires a vendor-specific data-class string.

Only RATs reported in the modem's `SupportedDataClasses` mask are offered.

## How it works

1. Finds the Quectel network adapter and matching Windows MBN interface.
2. Disconnects the active packet-data connection.
3. Calls `IMbnRegistration::SetRegisterMode` with automatic provider selection
   and the chosen preferred-data-class mask.
4. When 5G is selected, or when explicitly requested, cycles only the cellular
   software radio to force a fresh network registration.
5. Confirms that both hardware and software radio states are ON.
6. Polls `CurrentDataClass` and `AvailableDataClasses` to report the result.

The request is a Windows/driver preference, not an undocumented Quectel NVM
lock. Network policy can still choose a fallback RAT when the requested class
is unavailable.

## Result meanings

- **RAT change confirmed**: the current data class matches the requested set.
- **RAT enabled; waiting on network selection**: a requested 5G class is
  available, but the current connection has not moved to it.
- **Request completed but was not confirmed**: Windows accepted the request,
  but the requested class was not observed before the verification timeout.
- `Radio: hardware On / software On`: radio recovery was confirmed.

## Safety and privacy

- Changing RAT temporarily disconnects cellular data.
- A forced re-registration briefly turns off only the cellular software radio.
- The worker retries radio ON and performs a final recovery attempt on errors.
- APN, bands, SIM state, firmware, and Quectel NVM are not modified.
- Logs contain timestamps, masks, Windows request IDs, and result states only.
  They are written to `%ProgramData%\RM520N-RAT\switch.log`.

If a switch fails, run `Diagnostics.cmd` and attach its complete output to an
issue. Review it before posting if you have added any local modifications.

## Development

The runtime target is Windows PowerShell 5.1. No third-party PowerShell module
is required.

~~~powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Static.Tests.ps1
~~~

Before publishing a release, follow [RELEASE-CHECKLIST.md](RELEASE-CHECKLIST.md).
The repository owner must choose the license; this project does not assume one.

## References

- [Microsoft MBIMEx 2.0 – 5G NSA support](https://learn.microsoft.com/windows-hardware/drivers/network/mbimex-2.0-5g-nsa-support)
- [IMbnRegistration::SetRegisterMode](https://learn.microsoft.com/windows/win32/api/mbnapi/nf-mbnapi-imbnregistration-setregistermode)
- [IMbnRadio::SetSoftwareRadioState](https://learn.microsoft.com/windows/win32/api/mbnapi/nf-mbnapi-imbnradio-setsoftwareradiostate)
- [netsh mbn](https://learn.microsoft.com/windows-server/administration/windows-commands/netsh-mbn)

This project is not affiliated with Lenovo, Quectel, Microsoft, or SK Telecom.
