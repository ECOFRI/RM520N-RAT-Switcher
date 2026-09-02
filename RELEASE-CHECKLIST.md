# Release checklist

- [ ] Choose and add a `LICENSE` file. This repository intentionally does not
      assume redistribution terms on behalf of its owner.
- [ ] Run `tests/Static.Tests.ps1` on Windows PowerShell 5.1.
- [ ] Test LTE only, LTE + 5G NSA, Automatic, and every legacy-RAT preset that
      the test modem reports.
- [ ] Confirm `Radio: hardware On / software On` after forced re-registration.
- [ ] Verify that the GUI title and diagnostics show version `1.1.1`.
- [ ] Review `README.md`, `README-KO.md`, and `CHANGELOG.md`.
- [ ] Create a signed or annotated `v1.1.1` tag.
- [ ] Attach the Windows release ZIP and its SHA-256 checksum to the GitHub
      release.
