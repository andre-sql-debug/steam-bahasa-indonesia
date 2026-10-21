# RE4 Remake: Minecraft mod (work in progress)

Brings Minecraft into Resident Evil 4 Remake. Minecraft runs in the background with a small
Fabric mod. Your keys in RE4 are passed to Minecraft, Minecraft's own code moves its player and
calculates attacks, and REFramework scripts copy that movement to Leon, apply the damage to RE4
enemies and draw Minecraft's HUD. RE4 only adds its world (walls, floors) and its enemies.
Use a **Superflat** world in Minecraft so its player isn't blocked by Minecraft blocks.

**Terrain mode** (like RE4Craft): RE4's floors and walls around Leon are measured with RE4's own physics
raycasts and sent to Minecraft, which adds them as collision boxes for its player (moved up to y=250, above
its own world). Minecraft's physics then decides everything: walking, jumping, stairs and ramps, walls,
falling; Leon is just placed where the Minecraft player is.

**Story mode**: RE4 gets Leon back whenever the story needs it, by reading RE4's own player flags
(`minecraft_control.lua`). Ladders, windows, jumping down, doors, kicks, elevators, the boat and rides:
RE4 moves Leon while Minecraft's first-person view, mouse and bow stay (shoot from the boat).
Cutscenes, grabs/QTEs, the merchant, radio calls and menus: RE4's turn (its camera, keys, mouse and
prompts), and **your Minecraft character plays Leon in cutscenes** (`minecraft_cutscenes.lua`: drawn by
Minecraft through RE4's cutscene camera, walking and turning with Leon, arms and legs following his).
Afterwards Minecraft's player is moved to where Leon ended up, keeping the world mapping so the blocks
you built stay put.

**Minecraft's own controls in RE4**: **E** opens Minecraft's inventory / creative menu inside RE4 (with a
mouse cursor; click, drag, shift-click and type in the search box), **T** chat, **/** commands, **Q** drops
the held item, the mouse wheel scrolls the hotbar, **F1**-**F3** do what they do in Minecraft, and **Esc**
closes Minecraft's screen (not RE4's pause menu). While a Minecraft screen is open, every key and the mouse
go to Minecraft. TNT works: place it on RE4's ground, light it with flint and steel, and the blast hurts
RE4's enemies.

**Minecraft in RE4**: spawn eggs and blocks work on RE4's ground, and the blocks you build are drawn by
Minecraft itself into RE4 (real models and textures: TNT, glass, chests...); Minecraft's mobs, dropped items,
arrows and particles are drawn into RE4. Each RE4 enemy near Leon has an (unseen) Minecraft stand-in,
so iron golems, tamed wolves, TNT and your sword fight RE4's enemies with Minecraft's own attacks (sounds,
crit sparks, damage hearts, knockback, enchantments); the damage is applied to the real enemy, and a killing
hit makes RE4 kill it properly (its own death call, so it falls and is gone). Melee reaches enemies right
up close too. Damage is Minecraft's: a fist does 1, a diamond sword 7 (a normal enemy has a zombie's 20). Bows and crossbows (hold right-click) hit what the crosshair is on. Bosses get more health
(up to the Wither's 300) than normal enemies (a zombie's 20).

```
Minecraft 1.21.1 + RE4 Bridge mod  --writes-->  RE4\reframework\data\minecraft_bridge.json        --read by-->  minecraft_bridge_hud.lua
Minecraft 1.21.1 + RE4 Bridge mod  <--reads--   RE4\reframework\data\minecraft_bridge_input.json  <--writes--  minecraft_bridge_hud.lua
```

## Install / update (one click)
Unzip, then double-click **`install.bat`**. It finds RE4 and your CurseForge Minecraft profile (asks if it
can't), installs the ready-made Minecraft mod and RE4 overlay plugin from `prebuilt\` (replacing old
versions), tells the mod where RE4 is, and copies the RE4 scripts. Needs: REFramework in RE4 and a
CurseForge profile with Minecraft 1.21.1 + Fabric. Close Minecraft and RE4 before running it. The folders it
found are remembered in `install-paths.txt`. (Without `prebuilt\`, it builds the mod and needs the Java 21 JDK.)

## Live Minecraft overlay
While RE4 is in control, Minecraft skips drawing its world and renders only its hand, held item and HUD
on a see-through background, at RE4's half resolution with GUI scale 2 and 60 FPS. Each frame goes into
`reframework\data\minecraft_overlay.bin` (two picture slots), and the `re4_minecraft_overlay.dll`
REFramework plugin (`re4-overlay-plugin/`, built with MinGW-w64 via `build.sh`) draws it over RE4. So the
HUD, held items, swing animations, item names and attack indicator are Minecraft's own. Keep the Minecraft
window open behind RE4 (not minimized). The Lua HUD only draws its own copy when the plugin isn't running.
While Minecraft is in control, the plugin keeps the mouse and Minecraft's movement keys (WASD, Space,
Shift, Ctrl, E, Q, 1-9) away from RE4, so Leon doesn't aim, ready his knife or run on his own. During RE4's
turn (cutscenes, menus, **F7**) RE4 gets everything again; while RE4 moves Leon (ladders, the boat) it
gets the movement keys.

## RE4 side
Requirements: RE4 Remake on PC (Steam) and [REFramework](https://github.com/praydog/REFramework-nightly/releases)
(`REFramework.zip` → `dinput8.dll` in the game folder).

Copy the `.lua` files into `<RE4 game folder>\reframework\autorun\`. Settings: press **Insert** → **Script Generated UI**.

- `minecraft_bridge_hud.lua`: Minecraft HUD (hotbar, hearts, hunger, XP, held item) from live Minecraft data.
  In RE4, **1-9** pick the Minecraft hotbar slot and **left-click** swings the held item (in RE4 and Minecraft).
  Without Minecraft running, it shows Leon's health as hearts.
  The HUD is drawn from Minecraft's own images (hotbar, hearts, hunger, armor, XP bar) and font, and item
  icons are the real Minecraft textures, all sent by the Minecraft mod. RE4's own UI is hidden while
  Leon is in the game (**F8** shows it again).
- `minecraft_first_person.lua`: Minecraft's camera, with all of Leon hidden (body, head, hair, weapons).
  **F5** works like in Minecraft: first person → behind → in front. In the third-person views your
  Minecraft character (your skin, Minecraft's walk/swing animations, held item) is drawn by Minecraft into
  the overlay, and RE4's camera is put exactly where Minecraft's camera is (also stopped by RE4 walls), with
  Minecraft's field of view including the sprint zoom. First person: a steady eye height above
  Leon's feet (1.62 m, 1.27 m sneaking), turned only by the raw mouse (read by the overlay plugin) with
  Minecraft's sensitivity formula and your Minecraft sensitivity setting. Draws a `+` crosshair only when
  Minecraft isn't drawing its own.
- `minecraft_control.lua`: decides who has Leon (story mode, see above). **F7** = everything to RE4 and back.
  Menus are detected from Tab / I / M / Esc. Debug: Script Generated UI → Minecraft Control.
- `minecraft_cutscenes.lua`: your Minecraft character in cutscenes (see above).
- `minecraft_terrain.lua`: terrain mode (see above). Scans a 10 m radius around Leon in 0.5 m cells and
  places Leon where Minecraft's player is, facing where you look (so RE4's **F** interacts with what you
  look at). Sends RE4's enemies near Leon to Minecraft. **F9** re-anchors the two worlds.
  Debug: Script Generated UI → Minecraft Terrain.
- `minecraft_gameplay.lua`: copies the Minecraft player's movement (walking, sprinting, sneaking, jumping,
  Creative flying) to Leon and applies Minecraft's attack damage (cooldown, crits) to the enemy in front of
  you. Without Minecraft it falls back to built-in Minecraft movement numbers. Also: no damage for Leon.
- `minecraft_blocks.lua`: shows the blocks you build in Minecraft as 3D cubes in RE4. **Right-click** places
  (Minecraft's own "use"), **left-click** breaks (Minecraft's mining). Minecraft's player looks where Leon
  looks, and is pulled back next to Leon when RE4 walls stop him. **F9** re-anchors the two worlds.
- `minecraft_scanner.lua`: debugging tool; saves RE4 internals to `reframework\data\minecraft_scan.json`.

## Minecraft side (`minecraft-bridge-mod/`)
A client-only Fabric mod for Minecraft Java **1.21.1**.

1. Install a Java 21 JDK (e.g. Eclipse Temurin 21).
2. Build: in `minecraft-bridge-mod`, run `gradlew.bat build` (Windows). The mod is `build\libs\re4bridge-0.9.0.jar`.
3. Install Fabric Loader for 1.21.1 (Fabric installer, or a Fabric 1.21.1 profile in the CurseForge/Modrinth app)
   and put the jar in that profile's `mods` folder.
4. Start Minecraft once. `config\re4bridge.txt` holds the path of the file it writes; change it if RE4 is
   installed somewhere else than `D:\SteamLibrary\steamapps\common\RESIDENT EVIL 4  BIOHAZARD RE4`.

The mod turns off Minecraft's "pause on lost focus" so it keeps running while you play in the RE4 window.
