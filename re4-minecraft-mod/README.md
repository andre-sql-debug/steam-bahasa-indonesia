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
(up to the Wither's 300) than normal enemies (a zombie's 20). RE4's enemies fight back: a mob attacking one
within its reach takes a blow (2 hearts) about once a second, so a golem wins fights but not forever. An RE4
enemy that a Minecraft mob is fighting looks at that mob (RE4's own look-at for enemies), and looks back at
Leon when the fight ends (setting: **Enemies look at the Minecraft mobs fighting them**). Once
**Minecraft Diagnostics → Attack test** found how to start an enemy's own attacks (saved in
`reframework\data\minecraft_attack.json`), an enemy within reach of its mob turns to it and swings with one of
its own attacks, at most every 2.5 s, never while it reels from a hit or during RE4's scenes (setting:
**Enemies swing at the Minecraft mobs fighting them**).
Minecraft hits (yours and your mobs') can make RE4 enemies flinch through RE4's own hit code: the mod builds
the same kind of hit RE4 builds for Leon's knife and hands it to the enemy. Which way of building it works is
found once by **Minecraft Diagnostics → Flinch test** and saved (`reframework\data\minecraft_flinch.json`);
until then this stays off (setting: **Enemies flinch at Minecraft hits**).

Minecraft's things sit in RE4's world: they are drawn from RE4's own camera of each frame (see below), so
they stay exactly in place when you turn or move; RE4's floors and walls hide them like they hide anything
in RE4; and mobs, your character, dropped items and lit TNT cast Minecraft's soft round shadow on RE4's floor.

**Real RE4 mobs** (experimental, setting **Minecraft Real Mobs → Real RE4 mobs**): Minecraft's mobs become
real RE4 objects, lit, shadowed and hidden by RE4's renderer like its own models (the way SkyCraft puts
Minecraft into Skyrim). The Minecraft mod turns each body part it draws (its model and texture) into RE4's
own file formats (`.mesh`, `.tex`, `.mdf2`) in `natives\STM\minecraft`, once per part; every frame it sends
each part's position, rotation and size, `minecraft_native.lua` places RE4 objects with those models there,
and Minecraft stops drawing the parts RE4 shows (it still draws a part while the mob flashes red after a
hit, and anything RE4 can't show). Your own character in third person (F5) and in cutscenes goes the same way,
with your skin (its see-through outer layer cut out). The blocks you built do too: each kind of block is
written once with its own few textures (cut from Minecraft's block textures, not the whole sheet), and RE4
places one object per block, up to the 400 nearest; Minecraft keeps drawing only what RE4 doesn't show:
blocks Minecraft colours by biome (grass, leaves, vines), see-through ones (stained glass, ice, slime),
animated ones (fire, lanterns, campfires, magma, sea lanterns) and blocks drawn by their own code (chests,
banners). Pixel-art textures are scaled up sharply, and see-through
pixels are cut out. Needs REFramework's **Loose File Loader** (`install.bat` turns it on).

**Minecraft lights in RE4** (experimental, off by default; setting **Minecraft lights light RE4**): the light
blocks near you (torches, lanterns, campfires, jack o'lanterns, glowstone, shroomlights, sea lanterns, end rods,
lit furnaces, lit candles, redstone torches, soul torches and lanterns...) become real RE4 point lights, so they
light RE4's floors, walls, enemies and Leon like RE4's own lamps. The Minecraft mod sends the 24 light blocks
nearest its player (each light's spot in RE4, a torch's at its flame, also on a wall; its Minecraft light level; and
a colour per kind: warm orange for torches, lanterns and campfires, blue-cyan for soul ones, red for redstone
torches and lit redstone ore, pale yellow for glowstone, cool white for sea lanterns and end rods, warm white for
furnaces and candles), and `minecraft_lights.lua` keeps up to 16 RE4 lights on the ones nearest Leon: brightness
and reach (up to 8 m) follow the light level, and a light is only moved or changed when its block is. The lights
are on only while Minecraft is running and writing (lights left in the file by a Minecraft that was closed are never
lit). **Brightness** scales them all; **Lights cast shadows** is off by default
(slower; a light inside its own full block, like glowstone, never casts them). Needs no model files or Loose File
Loader, only the two worlds lined up by terrain mode (`minecraft_terrain.lua`). Which of RE4's light settings
exist isn't confirmed yet: each one is tried, and the section (and the diagnostics report) says which ones worked.
The light blocks themselves still look like Minecraft's (they don't glow in RE4).

**Hearts and death**: RE4's hits on Leon cost the Minecraft player hearts (Leon keeps full health in RE4),
and when either dies the other does too (settings: **RE4's hits cost Minecraft hearts**, **Shared death**).
In Creative mode the Minecraft player takes no damage. If RE4 closes, Minecraft's player is held in place and
after 10 seconds moved back to the world spawn, so it doesn't fall out of the sky.

```
Minecraft 1.21.1 + RE4 Bridge mod  --writes-->  RE4\reframework\data\minecraft_bridge.json        --read by-->  minecraft_bridge_hud.lua
Minecraft 1.21.1 + RE4 Bridge mod  <--reads--   RE4\reframework\data\minecraft_bridge_input.json  <--writes--  minecraft_bridge_hud.lua
```

## Install / update (one click)
Unzip, then double-click **`install.bat`**. It finds RE4 and your CurseForge Minecraft profile (asks if it
can't), installs the ready-made Minecraft mod and RE4 overlay plugin from `prebuilt\` (replacing old
versions), tells the mod where RE4 is, copies the RE4 scripts, and turns on REFramework's Loose File Loader
for the real RE4 mobs (in `re2_fw_config.txt`, keeping a `.bak`). Needs: REFramework in RE4 and a
CurseForge profile with Minecraft 1.21.1 + Fabric. Close Minecraft and RE4 before running it. The folders it
found are remembered in `install-paths.txt`. (Without `prebuilt\`, it builds the mod and needs the Java 21 JDK.)

**`uninstall.bat`** removes everything the mod added: the Minecraft mod and its setting, the RE4 scripts,
the overlay plugin, the mobs' model files and the mod's files in `reframework\data`. Minecraft worlds stay;
the Loose File Loader stays on (turn it off in RE4: **Insert → Loose File Loader**).

## Live Minecraft overlay
While RE4 is in control, Minecraft skips drawing its own world and renders only its things (your blocks,
mobs, items, particles, hand, held item and HUD) on a see-through background, at RE4's resolution (up to
1920x1080) with Minecraft's automatic GUI scale. Each frame goes into `reframework\data\minecraft_overlay.bin`
(two picture slots), and the `re4_minecraft_overlay.dll` REFramework plugin (`re4-overlay-plugin/`, built
with MinGW-w64 via `build.sh`) draws it over RE4. So the HUD, held items, swing animations, item names and
attack indicator are Minecraft's own.

Frames are drawn in lockstep: right before RE4 renders a frame, the plugin writes RE4's camera (position,
direction, field of view) into the same file; Minecraft waits for it, draws its picture from exactly that
camera (lined up through the terrain anchor), and tags the picture with the camera's number; the plugin
shows each RE4 frame with the Minecraft picture made for it (waiting at most 12 ms; on a PC where
Minecraft can't keep up it stops waiting for a while rather than slow RE4 down). Keep the Minecraft
window open behind RE4 (not minimized). The Lua HUD only draws its own copy when the plugin isn't running.
While Minecraft is in control, the plugin keeps the mouse and Minecraft's movement keys (WASD, Space,
Shift, Ctrl, E, Q, 1-9) away from RE4, so Leon doesn't aim, ready his knife or run on his own. During RE4's
turn (cutscenes, menus, **F7**) RE4 gets everything again; while RE4 moves Leon (ladders, the boat) it
gets the movement keys.

## RE4 side
Requirements: RE4 Remake on PC (Steam) and [REFramework](https://github.com/praydog/REFramework-nightly/releases)
(`REFramework.zip` → `dinput8.dll` in the game folder).

Copy the `.lua` files into `<RE4 game folder>\reframework\autorun\`. Settings: press **Insert** → **Script Generated UI**
→ **Minecraft**.

- `minecraft_menu.lua`: the one **Minecraft** menu. On top: whether Minecraft is connected and who has Leon,
  the most used switches (hearts, shared death, flinching, real RE4 mobs, Minecraft lights, camera, cutscenes,
  RE4's HUD),
  **Save diagnostics report**, **Make support zip** and **Reset all settings to defaults**; below it every
  script's own section. Settings are saved by themselves in `reframework\data\minecraft_settings.json` and
  come back the next time RE4 starts. **Make support zip** saves the diagnostics report, then the Minecraft
  mod puts Minecraft's log, the mod's files in `reframework\data`, REFramework's log and settings, and lists
  of the installed scripts, plugins, mob files and Minecraft mods into one zip on the Desktop (the menu shows
  where): send that one file when reporting a problem.

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
- `minecraft_diagnostics.lua`: writes `reframework\data\minecraft_diagnostics.json` after a minute of play
  (or **Save report now**): which RE4 methods the mod uses exist, Leon's joints, nearby enemies and their
  health state, who had Leon how often and every handover with its reason (a timeline), frame rate, how
  RE4's enemies pick targets, what RE4 says about the chapter and area, how the real RE4 mobs loaded, which
  of RE4's light settings the Minecraft lights could use (and the lights Minecraft sent), and what RE4 offers
  for adding objects to its world. **Record real hits** logs which RE4 functions run when
  RE4 itself hits an enemy, and in which order. RE4's own hits on enemies are captured all the time (what the
  hit carries, and the enemy's behavior states right after: its damage reactions). **Live tests** (Look,
  Walk, Flinch, Attack) try RE4's own functions on the nearest enemy for a few seconds and measure by
  themselves whether the enemy looked at a point, walked to it, went into a damage reaction from a
  Minecraft-style hit (every working way is saved and switched on; how much health RE4's hit code took is
  written down), or started one of its own attacks on request (the way to make enemies swing at mobs); the
  report saves itself after each. **Spawn test cube / enemy-model copy / light** create real RE4 objects in
  front of Leon, to see whether RE4 lights, shadows and hides them like its own (the way to make Minecraft's
  mobs and torches real RE4 objects). **Make support zip** in the Minecraft menu collects this report with
  everything else needed when reporting a problem.
- `minecraft_terrain.lua`: terrain mode (see above). Scans a 10 m radius around Leon in 0.5 m cells and
  places Leon where Minecraft's player is, facing where you look (so RE4's **F** interacts with what you
  look at). Sends RE4's enemies near Leon to Minecraft. **F9** re-anchors the two worlds.
  Debug: Script Generated UI → Minecraft Terrain.
- `minecraft_gameplay.lua`: copies the Minecraft player's movement (walking, sprinting, sneaking, jumping,
  Creative flying) to Leon and applies Minecraft's attack damage (cooldown, crits) to the enemy in front of
  you. Without Minecraft it falls back to built-in Minecraft movement numbers. Also: hearts and shared
  death (see above), flinching, and enemies looking at the mobs fighting them.
- `minecraft_native.lua`: real RE4 mobs, your character and built blocks (see above). Status and errors: Script
  Generated UI → Minecraft Real Mobs.
- `minecraft_lights.lua`: Minecraft's light blocks as RE4 lights (see above). Status, which light settings work
  and errors: Script Generated UI → Minecraft → Minecraft Lights.
- `minecraft_blocks.lua`: shows the blocks you build in Minecraft as 3D cubes in RE4. **Right-click** places
  (Minecraft's own "use"), **left-click** breaks (Minecraft's mining). Minecraft's player looks where Leon
  looks, and is pulled back next to Leon when RE4 walls stop him. **F9** re-anchors the two worlds.
- `minecraft_scanner.lua`: debugging tool; saves RE4 internals to `reframework\data\minecraft_scan.json`.

## Minecraft side (`minecraft-bridge-mod/`)
A client-only Fabric mod for Minecraft Java **1.21.1**.

1. Install a Java 21 JDK (e.g. Eclipse Temurin 21).
2. Build: in `minecraft-bridge-mod`, run `gradlew.bat build` (Windows). The mod is `build\libs\re4bridge-0.12.0.jar`.
3. Install Fabric Loader for 1.21.1 (Fabric installer, or a Fabric 1.21.1 profile in the CurseForge/Modrinth app)
   and put the jar in that profile's `mods` folder.
4. Start Minecraft once. `config\re4bridge.txt` holds the path of the file it writes; change it if RE4 is
   installed somewhere else than `D:\SteamLibrary\steamapps\common\RESIDENT EVIL 4  BIOHAZARD RE4`.

The mod turns off Minecraft's "pause on lost focus" so it keeps running while you play in the RE4 window.
