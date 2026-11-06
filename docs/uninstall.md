# Uninstall NextTyped

This guide removes everything NextTyped put on your Mac. It ships inside the app (Settings → About), so you can read it offline. Do the steps in order. The order matters: a login item that is still on would start the app again after you quit and delete it, so step 1 turns it off while the app still runs.

You need no `sudo`, no `xattr` and no `tccutil`. The only Terminal commands below are `rm -r` on named folders and `defaults delete` on one preferences domain, and each says what it touches. Everything else is a click in System Settings or Keychain Access.

Every location below was checked against the code. The table at the end maps each one to its source.

## 1. Turn off Launch at login

The app has to be running for this. In the menu bar, switch **Launch at login** off (the same switch is in Settings → General).

Check **System Settings → General → Login Items & Extensions**. NextTyped should not be in the list. If it is, select it and click the minus button.

## 2. Quit NextTyped

Menu bar icon, then **Quit NextTyped**.

## 3. Turn macOS inline prediction back on

Only needed if the first-run nudge or Settings → Setup led you to turn it off. Open **System Settings → Keyboard**, click **Edit…** next to **Input Sources** (on some macOS versions it reads **Text Input**), and turn on **Show inline predictive text**.

## 4. Remove the permission grants

Open **System Settings → Privacy & Security → Accessibility**, select **NextTyped**, and click the minus button.

If you turned on screen-context OCR, do the same under **Privacy & Security → Screen & System Audio Recording**.

## 5. Delete the app

Drag `NextTyped.app` from `/Applications` to the Trash and empty the Trash.

## 6. Delete the app's data folder

This folder holds your usage statistics (`usage-statistics.json`) and the encrypted style profile (`style-profile.enc`). Deleting it cannot be undone.

```bash
rm -r ~/Library/Application\ Support/com.robinklotz.NextTyped
```

It touches only that one folder.

## 7. Delete the Keychain item

The style profile is encrypted with a key that lives in your login keychain. Open **Keychain Access**, select the **login** keychain, search for `com.robinklotz.NextTyped.styleProfile`, select the item and delete it. Without this step the key stays behind, although the file it protected is gone.

## 8. Delete the downloaded model

On first run the app downloads its model, `Robin1333k/Qwen3.5-4B-Base-MLX-6bit`, about 3.2 GB. This is the largest thing the app leaves on your disk, so do not skip this step. The download goes to the Hugging Face cache:

```bash
rm -r ~/.cache/huggingface/hub/models--Robin1333k--Qwen3.5-4B-Base-MLX-6bit
```

A version from before 2026-10-28 downloaded the smaller `Robin1333k/Qwen3.5-2B-Base-MLX-6bit` (about 1.4 GB) instead. If you used one, delete that folder too:

```bash
rm -r ~/.cache/huggingface/hub/models--Robin1333k--Qwen3.5-2B-Base-MLX-6bit
```

It touches only that model's folder. Other models in the same cache belong to other tools and stay. If you set `HF_HUB_CACHE` or `HF_HOME` yourself, the folder is under that location instead, in `hub/`.

If you ever turned on the hidden mid-text setting, the app may also have fetched a second model. Delete any `models--Robin1333k--*` folder in the same place:

```bash
rm -r ~/.cache/huggingface/hub/models--Robin1333k--*
```

On a normal install there is no second model, and zsh prints `zsh: no matches found: ...`. That message is expected and means there was nothing to delete.

Delete `~/Models/` only if you put a model there by hand. The app reads from it when it finds a copy, but it never writes there. A normal install has no such folder.

## 9. Remove preferences, caches and network storage

```bash
defaults delete com.robinklotz.NextTyped
```

This removes the app's preferences domain (`~/Library/Preferences/com.robinklotz.NextTyped.plist`) and nothing else. Then delete the cache folder if it exists:

```bash
rm -r ~/Library/Caches/com.robinklotz.NextTyped
```

This is the URL cache of the model download. It exists after the first-run download, and `No such file or directory` means the app never downloaded a model on this Mac. Then delete the network storage folder the same download creates:

```bash
rm -r ~/Library/HTTPStorages/com.robinklotz.NextTyped
```

It touches only that folder (`httpstorages.sqlite` and its `-wal` and `-shm` files).

## Check that nothing is left

```bash
ls ~/Library/Application\ Support | grep -i com.robinklotz
ls ~/Library/Caches ~/Library/Preferences | grep -i com.robinklotz
ls ~/.cache/huggingface/hub | grep -i Robin1333k
ls ~/Library/HTTPStorages | grep -i com.robinklotz
```

All four should print nothing. To search for anything else with the app's name, run `find ~/Library -maxdepth 3 -iname '*com.robinklotz.NextTyped*'`; it should print nothing too. In Keychain Access, a search for `com.robinklotz` should find nothing.

## Where each location comes from

| Step | Location | Written by |
| --- | --- | --- |
| 1 | Login item | `SMAppService.mainApp` in `App/Support/LaunchAtLogin.swift`, reached through `AppCoordinator.setLaunchAtLogin` |
| 3 | macOS "Show inline predictive text" | Set by you, prompted by `App/Onboarding/InlinePredictionNudge.swift` and `App/Settings/SetupSettingsView.swift` |
| 6 | `~/Library/Application Support/com.robinklotz.NextTyped/usage-statistics.json` | `App/Statistics/UsageStatisticsStore.swift` (`fileURL()`) |
| 6 | `~/Library/Application Support/com.robinklotz.NextTyped/style-profile.enc` | `App/Personalization/StyleProfileStore.swift` (`fileURL()`) |
| 7 | Keychain service `com.robinklotz.NextTyped.styleProfile` | `App/Personalization/StyleProfileStore.swift` (`keychainService`, `baseQuery()`) |
| 8 | `~/.cache/huggingface/hub/models--Robin1333k--Qwen3.5-4B-Base-MLX-6bit` (before 2026-10-28: `…--Qwen3.5-2B-Base-MLX-6bit`) | The Hub downloader in `App/Prediction/MLXPredictionEngine.swift`; location from the swift-huggingface cache rules |
| 8 | `~/Models/` | Read only, `MLXPredictionEngine.modelDirectory`; never written |
| 8 | `~/.cache/huggingface/hub/models--Robin1333k--Qwen3-1.7B-MLX-6bit` | Second (mid-text) model, same downloader; only with the hidden `midTextCompletionEnabled` on |
| 9 | `~/Library/Caches/com.robinklotz.NextTyped` | URL cache of the Hub download's `URLSession` (created by the system, not by our code) |
| 9 | `~/Library/HTTPStorages/com.robinklotz.NextTyped` | Network storage of the same `URLSession` (created by the system) |
| 9 | `~/Library/Preferences/com.robinklotz.NextTyped.plist` | `UserDefaults.standard` in `App/Support/AppSettingsStore.swift` and others |
