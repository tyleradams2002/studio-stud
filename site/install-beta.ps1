<#
  Studio Stud — beta channel installer.
  One-liner: irm https://tyleradams2002.github.io/studio-stud/install-beta.ps1 | iex
  Prompts for beta channel password, decrypts inline, launches the installer.
#>
$ErrorActionPreference = 'Stop'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}
$script = Invoke-RestMethod 'https://tyleradams2002.github.io/studio-stud/install.ps1'
& ([scriptblock]::Create($script)) -Channel beta
