# Contributing

Contributions that improve Windows MBN compatibility, diagnostics, UI behavior,
or documentation are welcome.

Before opening a pull request:

1. Keep compatibility with Windows PowerShell 5.1.
2. Do not add external module dependencies for the normal runtime.
3. Do not log subscriber identifiers or credentials.
4. Preserve radio-ON recovery in every error path.
5. Run:

   ~~~powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\Static.Tests.ps1
   ~~~

Hardware-test changes that modify registration or radio behavior when possible,
and describe the modem model, connection type, driver version, carrier, and
whether the network uses NSA or SA. Redact subscriber identifiers.
