# RE4 Remake: Minecraft mod (work in progress)

Brings Minecraft into Resident Evil 4 Remake. Minecraft runs in the background with a small
Fabric mod that sends your real HUD data (health, hunger, XP, hotbar) to RE4, where
REFramework scripts draw Minecraft's HUD and add first person and Creative-style flying.

```
Minecraft 1.21.1 + RE4 Bridge mod  --writes-->  RE4\reframework\data\minecraft_bridge.json        --read by-->  minecraft_bridge_hud.lua
Minecraft 1.21.1 + RE4 Bridge mod  <--reads--   RE4\reframework\data\minecraft_bridge_input.json  <--writes--  minecraft_bridge_hud.lua
```

## RE4 side
Requirements: RE4 Remake on PC (Steam) and [REFramework](https://github.com/praydog/REFramework-nightly/releases)
(`REFramework.zip` → `dinput8.dll` in the game folder).

Copy the `.lua` files into `<RE4 game folder>\reframework\autorun\`. Settings: press **Insert** → **Script Generated UI**.

- `minecraft_bridge_hud.lua`: Minecraft HUD (hotbar, hearts, hunger, XP, held item) from live Minecraft data.
  In RE4, **1-9** pick the Minecraft hotbar slot and **left-click** swings the held item (in RE4 and Minecraft).
  Without Minecraft running, it shows Leon's health as hearts.
- `minecraft_first_person.lua`: first-person camera (toggle with **F5**) and Minecraft's `+` crosshair.
- `minecraft_creative.lua`: Creative mode: flying (double-tap **Space** or **F6**; WASD, Space up, Shift or C down, Ctrl faster) and no damage.

## Minecraft side (`minecraft-bridge-mod/`)
A client-only Fabric mod for Minecraft Java **1.21.1**.

1. Install a Java 21 JDK (e.g. Eclipse Temurin 21).
2. Build: in `minecraft-bridge-mod`, run `gradlew.bat build` (Windows). The mod is `build\libs\re4bridge-0.2.0.jar`.
3. Install Fabric Loader for 1.21.1 (Fabric installer, or a Fabric 1.21.1 profile in the CurseForge/Modrinth app)
   and put the jar in that profile's `mods` folder.
4. Start Minecraft once. `config\re4bridge.txt` holds the path of the file it writes; change it if RE4 is
   installed somewhere else than `D:\SteamLibrary\steamapps\common\RESIDENT EVIL 4  BIOHAZARD RE4`.

The mod turns off Minecraft's "pause on lost focus" so it keeps running while you play in the RE4 window.
