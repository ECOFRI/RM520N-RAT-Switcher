# Changelog

All notable changes are documented in this file.

## [1.1.1] - 2026-09-02

### Fixed

- Materialized the dynamic preset collection with `List<object>.ToArray()`.
  This avoids the Windows PowerShell 5.1 `Argument types do not match` error
  raised by `@($genericList)` while the GUI initializes.

## [1.1.0] - 2026-09-02

### Added

- Dynamic RAT list built from the modem's supported data-class mask.
- Presets for Automatic, LTE, 5G NSA, 5G SA, 3G/HSPA, 2G, and CDMA.
- Individual advanced data-class selection.
- Responsive GUI worker process with live progress reporting.
- Quick LTE and LTE + 5G NSA selection controls.
- Windows PowerShell parser checks and GitHub Actions validation.
- English project documentation.

### Changed

- Generalized the switch engine to accept any safe, supported standard mask.
- Improved verification messages for both 5G and legacy RAT selections.
- Reduced unsupported `netsh mbn set acstate` retries.
- Refreshed the WinForms layout, typography, colors, status presentation, and
  DPI behavior.

### Safety

- 5G NSA cannot be selected without its LTE anchor.
- Unsupported bits and the OEM Custom data-class bit are rejected.
- The GUI cannot be closed while radio recovery is in progress.

## [1.0.7] - 2026-09-01

- Verified asynchronous software-radio ON completion.
- Retried ON requests and added final radio recovery on errors.
- Displayed hardware and software radio state.

## [1.0.6] - 2026-09-01

- Treated unsupported auto-connect state commands as non-fatal.
- Retried registration after Windows reconnected cellular data.

## [1.0.5] - 2026-09-01

- Fixed WinForms event-scope errors involving missing `Text` properties.

## [1.0.3] - 2026-09-01

- Corrected 5G NSA from the invalid `0x21` attempt to LTE + NSA `0x60`.
- Added cellular-radio cycling to force NSA re-registration.
