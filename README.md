# Secure Boot & TPM 2.0 Check

Games with kernel anti-cheat often refuse to start unless **Secure Boot** and **TPM 2.0** are turned on. This tool tells you whether your PC is ready and, if it isn't, **exactly why** and how to fix it, step by step.

> [!IMPORTANT]
> **This tool makes no changes to your PC.**
> It only *reads* your settings. It does not change BIOS settings, files, disks, BitLocker or the TPM, and it never restarts your PC. Every fix is shown as instructions: nothing happens unless you decide to do it yourself.

## How to use it

### Option 1: one command (quickest)

Right-click the Start button, open **Terminal** or **PowerShell**, then paste this and press Enter:

```powershell
irm https://raw.githubusercontent.com/Krimziee/SecureBootCheck/main/run.ps1 | iex
```

Click **Yes** when Windows asks for admin rights. The firmware settings can only be read with them. The check opens in a new window.

Nothing is downloaded to your PC: the newest version is loaded straight from this repository into memory and run.

### Option 2: download it

1. Download the latest zip from **[Releases](https://github.com/Krimziee/SecureBootCheck/releases/latest)** and unpack it.
2. Double-click **`Check Secure Boot.cmd`**.
3. Click **Yes** when Windows asks for admin rights.

This opens the check in a window: your PC and every check on the left, the result and the fix steps on the right. Commands in the fix steps can be selected and copied, but the window never runs them. It has no button that changes anything. **Check again** runs the check once more after you've made a change.

The one-command version (Option 1) shows the same check as text.

Works on Windows 10 and Windows 11. The check is also a tab in Krimz's Toolkit, which shows the same window.

## What it checks

| Check | What it finds |
|---|---|
| Boot mode | Whether Windows started in UEFI mode or old Legacy / CSM mode (Secure Boot needs UEFI), and whether the motherboard supports UEFI at all |
| Windows disk | Whether the disk is GPT or MBR, and whether it can be converted without reinstalling Windows |
| Secure Boot | Whether it's on, and if not, why: switched off in the BIOS, keys wiped, audit mode, custom keys without Microsoft's certificate, or a motherboard that has no Secure Boot at all |
| Secure Boot keys | Missing Microsoft certificates, insecure test keys from the PC maker, and whether the 2023 certificate update is installed |
| TPM 2.0 | Whether a TPM is there, switched on, version 2.0 and ready, and which BIOS setting to turn on (AMD fTPM / Intel PTT). If none is found, it uses your processor to tell whether it's most likely just switched off or your processor has none. Also warns if the TPM is locked after too many wrong PINs |
| BitLocker | Whether your drive is encrypted and has a recovery key, so changing BIOS settings won't lock you out |

It also detects your PC or motherboard brand and tells you which key opens its BIOS setup.

**If it finds several problems**, it lists them as steps in the order you need to do them. For example, converting the disk comes before switching the BIOS to UEFI. Some settings can only be checked once the earlier steps are done, so run the check again afterwards.

**If your hardware can't do it**, it says so plainly instead of sending you hunting for settings that don't exist. That covers a motherboard without UEFI, a UEFI firmware without Secure Boot, and a processor without a built-in TPM 2.0. It also never suggests converting your disk on a motherboard that can't start in UEFI mode.

**What it can't see:** Windows can't look inside the BIOS menus, so it can't tell whether an option is greyed out or protected by a BIOS password. It also can't tell whether your motherboard has a connector for a separate TPM module; check the manual for that. It also can't predict problems that only appear after Secure Boot is turned on, such as an old graphics card showing a black screen. In those cases it gives you the most likely settings to check.

## Example

```
 Result
 ------
  [FAIL] Secure Boot                  OFF
  [ OK ] TPM 2.0                      ready

  1 thing to fix before games that require Secure Boot / TPM 2.0 will run.

  BEFORE YOU CHANGE ANYTHING - protect your files
  ----------------------------------------------

  Your Windows drive (C:) is encrypted with BitLocker / Device Encryption.
  ...

  HOW TO OPEN THE BIOS/UEFI SETUP
  -------------------------------
     - Gigabyte PC or motherboard: turn it on and keep pressing Del until the setup screen opens.
     ...

  WHY, AND HOW TO FIX IT  (do the steps in this order)
  ----------------------------------------------------
  These are instructions for you. This tool has not run any of these commands
  or changed any setting - nothing happens unless you do it yourself.

  Step 1. Secure Boot is turned off in the BIOS/UEFI settings.
     - The keys are installed correctly - Secure Boot is simply switched off. In the BIOS/UEFI setup,
       open the Secure Boot page and set it to "Enabled".
     ...

  After these steps, run this check again to confirm everything is fixed.

  Check finished. Nothing on your PC was changed.
```

## Is it really read-only?

Yes. The script only reads firmware settings, the registry, the TPM status and the disk layout. Commands like `mbr2gpt /convert` or `manage-bde` appear only as text in the fix steps, and the script never runs them.

The one thing it writes: on a PC still in Legacy mode with an MBR disk, it runs Windows' own check-only command `mbr2gpt /validate` to see whether the disk can be converted. Like every run of that tool, it writes its log files (`setupact.log`, `setuperr.log`) to `C:\Windows`. It doesn't touch the disk itself.

## Protecting your data

Some fixes can affect your files if they're done carelessly, so the tool warns you before listing them:

- **BitLocker:** changing Secure Boot, TPM or boot settings makes Windows ask for your BitLocker recovery key. The tool checks that a key exists, shows how to view and save it, and how to pause BitLocker first.
- **Converting the disk (MBR to GPT):** this is built to keep your files, but a power cut while it runs can stop Windows from starting. The tool tells you to back up first and what to do afterwards.

## Windows warning when you start it

Windows may show **"Windows protected your PC"** because the file was downloaded from the internet. Click **More info → Run anyway**. The whole tool is plain PowerShell: you can open `SecureBootCheck.ps1` in Notepad and read exactly what it does.

## Running it from PowerShell

```powershell
powershell -ExecutionPolicy Bypass -File .\SecureBootCheck.ps1
```

This shows the text version. Add `-NoPause` to close the window right away when it's finished, or `-Window` to open the window instead.

## License

[MIT](LICENSE)
