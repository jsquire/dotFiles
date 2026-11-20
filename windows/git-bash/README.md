# Git for Windows

This directory contains the user-level Git for Windows and Git Bash
configuration. SSH commit and tag signing uses the Windows OpenSSH client and
its `ssh-agent` service. The SSH identity itself is restored separately and is
not stored in this repository.

## Required SSH Identity Files

Restore these files under `$HOME\.ssh` before enabling automatic signing:

* `github_signing`
* `github_signing.pub`
* `allowed_signers`

`allowed_signers` must associate the Git commit email with the public signing
key. The signing key must also be registered with GitHub as a **signing key**.

If the trust file needs to be rebuilt:

```powershell
$Email = "your-verified-github-email@example.com"
$PublicKey = Get-Content -LiteralPath "$HOME\.ssh\github_signing.pub" -Raw
"$Email $($PublicKey.Trim())" |
  Set-Content -LiteralPath "$HOME\.ssh\allowed_signers" -Encoding ascii
ssh-keygen -Y match-principals `
  -I $Email `
  -f "$HOME\.ssh\allowed_signers"
```

Verify the restored public key:

```powershell
ssh-keygen -lf "$HOME\.ssh\github_signing.pub" -E sha256
```

## Install or Verify OpenSSH Client

Open an elevated PowerShell prompt and inspect the Windows OpenSSH capability:

```powershell
Get-WindowsCapability -Online -Name OpenSSH.Client*
```

If it is not installed, add the Windows OpenSSH Client capability:

```powershell
Add-WindowsCapability -Online -Name OpenSSH.Client~~~~0.0.1.0
```

The OpenSSH Server capability and `sshd` service are not required for Git
signing.

## Enable the Windows SSH Agent

From an elevated PowerShell prompt:

```powershell
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service -Name ssh-agent
Get-Service -Name ssh-agent
```

From a normal PowerShell prompt that you opened yourself, load the
passphrase-protected signing key. Do not run this command through Copilot:

```powershell
ssh-add "$HOME\.ssh\github_signing"
ssh-add -l -E sha256
```

If the key is not listed after a reboot or service restart, run `ssh-add`
again.

## Activate the Git Configuration

Copy the tracked home files into the Git Bash home directory, then replace the
email and token placeholders in `.gitconfig`. The template:

* Uses SSH signatures for commits and tags.
* Uses `~/.ssh/github_signing.pub` as the signing identity.
* Uses `~/.ssh/allowed_signers` for local verification.
* Uses the Windows OpenSSH `ssh-keygen.exe` so Git connects to the Windows
  `ssh-agent` service rather than the separate OpenSSH copy bundled with Git
  for Windows.

Git retains the `gpg.*` configuration namespace for all signature formats.
`gpg.format = ssh` selects SSH and does not invoke OpenPGP.

For an existing personalized `.gitconfig`, migrate only the signing settings:

```powershell
git config --global user.signingkey "~/.ssh/github_signing.pub"
git config --global gpg.format ssh
git config --global gpg.ssh.allowedSignersFile "~/.ssh/allowed_signers"
git config --global gpg.ssh.program "C:/Windows/System32/OpenSSH/ssh-keygen.exe"
git config --global commit.gpgsign true
git config --global tag.gpgsign true
git config --global --unset-all gpg.program
git config --global --remove-section gpg.openpgp
```

The final two commands may report that no matching key exists, which is safe
to ignore.

Confirm the effective configuration:

```powershell
git config --global --get user.email
git config --global --get user.signingkey
git config --global --get gpg.format
git config --global --get gpg.ssh.allowedSignersFile
git config --global --get gpg.ssh.program
git config --global --get commit.gpgsign
git config --global --get tag.gpgsign
```

Verify a signed commit and tag in a disposable repository:

```powershell
$TestRepository = Join-Path $env:TEMP "git-ssh-signing-test"
Remove-Item -LiteralPath $TestRepository -Recurse -Force -ErrorAction SilentlyContinue
git init $TestRepository
git -C $TestRepository commit --allow-empty -m "Verify SSH commit signing"
git -C $TestRepository verify-commit HEAD
git -C $TestRepository tag -a signing-test -m "Verify SSH tag signing"
git -C $TestRepository verify-tag signing-test
Remove-Item -LiteralPath $TestRepository -Recurse -Force
```

Both verification commands should identify the expected email and signing-key
fingerprint.

## WSL

The CachyOS WSL environment intentionally links `~/.ssh` to the Windows
profile, so it uses the same identity files. WSL runs its own `ssh-agent`
process and loads the shared private key independently. See
`windows/wsl/cachyos/README.md` for its activation steps.
