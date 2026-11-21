## What it changes

<!-- One topic. What it does for the owner, then the cause. -->

## Checks

- [ ] `powershell -NoProfile -ExecutionPolicy Bypass -File check.ps1` prints no FAILED line.
- [ ] A changed queue rule has a test and its doc in this pull request.
- [ ] The base names no environment; Windows PowerShell 5.1 syntax; OS-specific code only in platform.ps1 or tasks.ps1; no new dependency.
- [ ] A change to the plugin contract has an issue: #
