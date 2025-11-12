```markdown
# Roblox Reconnect Script (Termux)

This is a Termux-compatible Bash script that:

- Prompts whether you have multiple Roblox accounts and collects user IDs.
- Asks for a game ID or private server link to join.
- Asks for a restart interval (minutes) to fully restart the Roblox app periodically.
- Opens the join link INSIDE the Roblox Android app using Android intents (tries several deep-link styles).
- Waits 25 seconds for the client to join the game.
- Uses the Roblox Presence API to detect whether any of the monitored users are online; if they are online it waits 30 seconds and rechecks, otherwise it fully closes the Roblox app and reopens the game link.
- Supports automatic executor update checks for the "Delta" Android executor using the WEAO API. If WEAO reports a newer Android Roblox version and Delta reports compatibility, the script will attempt to download and install `Delta-[VERSION].apk` from `https://delta.filenetwork.vip/file/Delta-[VERSION].apk`. The script will force-stop Roblox before installing.

Important notes and limitations:
- The script tries multiple deep-link formats to open the game inside the Roblox app, but behavior can vary by device, Android version, and Roblox client.
- Presence detection uses `https://presence.roblox.com/v1/presence/users?userIds=...`. The API only indicates online/offline and no longer reliably reveals which *game* a user is in.
- Auto-installing APKs using `pm install` may require appropriate permissions or user interaction; on some devices, `pm install` will not succeed without additional privileges.
- Termux must have storage permissions if you want APKs downloaded to `/sdcard/Download`. Run `termux-setup-storage` if needed.
- You may need to install `jq` via `pkg install jq` if not present.

Usage:
1. Save `reconnect.sh` and make executable:
   chmod +x reconnect.sh

2. Run in Termux:
   ./reconnect.sh

3. Follow prompts.

Files:
- reconnect.sh : The main script.
- README.md : This file.

If you want improvements (e.g., service/foreground implementation, logging to file, or different deep-link formats), tell me what device/Android version you are using and I can adjust the intents.
```
