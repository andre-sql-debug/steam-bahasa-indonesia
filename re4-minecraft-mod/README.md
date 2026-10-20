# RE4 Remake: Minecraft mod (work in progress)

Brings Minecraft into Resident Evil 4 Remake. Minecraft runs in the background with a small
Fabric mod. Your keys in RE4 are passed to Minecraft, Minecraft's own code moves its player and
calculates attacks, and REFramework scripts copy that movement to Leon, apply the damage to RE4
enemies and draw Minecraft's HUD. RE4 only adds its world (walls, floors) and its enemies.
Use a **Superflat** world in Minecraft so its player isn't blocked by Minecraft blocks.

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
  **Hide RE4 UI elements** in its menu hides RE4's own HUD (saved to `reframework\data\minecraft_hidden_gui.json`).
- `minecraft_first_person.lua`: first-person camera (toggle with **F5**) and Minecraft's `+` crosshair.
- `minecraft_gameplay.lua`: copies the Minecraft player's movement (walking, sprinting, sneaking, jumping,
  Creative flying) to Leon and applies Minecraft's attack damage (cooldown, crits) to the enemy in front of
  you. Without Minecraft it falls back to built-in Minecraft movement numbers. Also: no damage for Leon.
  **F7** turns Minecraft movement off (for ladders and doors).
- `minecraft_scanner.lua`: debugging tool; saves RE4 internals to `reframework\data\minecraft_scan.json`.

## Minecraft side (`minecraft-bridge-mod/`)
A client-only Fabric mod for Minecraft Java **1.21.1**.

1. Install a Java 21 JDK (e.g. Eclipse Temurin 21).
2. Build: in `minecraft-bridge-mod`, run `gradlew.bat build` (Windows). The mod is `build\libs\re4bridge-0.3.1.jar`.
3. Install Fabric Loader for 1.21.1 (Fabric installer, or a Fabric 1.21.1 profile in the CurseForge/Modrinth app)
   and put the jar in that profile's `mods` folder.
4. Start Minecraft once. `config\re4bridge.txt` holds the path of the file it writes; change it if RE4 is
   installed somewhere else than `D:\SteamLibrary\steamapps\common\RESIDENT EVIL 4  BIOHAZARD RE4`.

The mod turns off Minecraft's "pause on lost focus" so it keeps running while you play in the RE4 window.
