# In-game test checklist (about 17 minutes)

Close RE4 and Minecraft, run `install.bat`, then start Minecraft (your RE4 profile, Superflat world) and RE4.
In RE4 press **Insert** → **Script Generated UI** → **Minecraft**. Everything below is in that menu.

## 1. Menu and settings (1 min)
- The top line says Minecraft is connected and who has Leon.
- Untick **Shared death**, restart RE4 (or ScriptRunner → Reset scripts): it is still unticked. Tick it again.

## 2. Hits and reactions (5 min, chapter 1 village)
1. Press **F7** (RE4 plays), knife one villager once, shoot one once, let one hit you once, press **F7** again.
2. **Minecraft Diagnostics** → **Flinch test** next to a standing villager. Wait for the result line.
3. **Attack test** next to the villager that hit you.
4. Hit villagers with Minecraft (fist, then a sword): do they react? Do strong hits react more?
5. **Record real hits**: Start → F7 → knife a villager twice → F7 → Stop and save.

## 3. Real RE4 objects (3 min)
- **Spawn test cube**, **Spawn enemy-model copy** and **Spawn test light** in a dark spot and in daylight. Take one
  screenshot of each: is the cube lit and shadowed? Does the light light the ground? Then **Remove test objects**.

## 4. Real RE4 mobs (3 min)
- Tick **Real RE4 mobs (experimental)**. In Minecraft summon an iron golem near Leon (`/summon iron_golem`).
- Look at it from all sides, walk around it, let it fight a villager. Screenshot.
- Build a small wall (stone, planks, plain glass) and switch to third person: are the wall and
  your character lit and shadowed like RE4's things? Does the golem behind the wall disappear behind it? Screenshot.
- Stand on the wall in third person: only one shadow under you? Press F7 (RE4's turn): does the wall stay real
  (no flat cubes painted over it)? A lantern or fire on the wall should still move (Minecraft keeps drawing those).
- The **Minecraft Real Mobs** section shows parts loaded/failed and any errors. If it says RE4 can't open
  the files, the Loose File Loader is off: close RE4, run `install.bat` again.
- If anything looks wrong or RE4 misbehaves, untick it again.

## 5. Minecraft lights (2 min)
- Tick **Minecraft lights light RE4 (experimental)**. In a dark spot (a house at night, a cave) place a torch on the
  floor near Leon, then a soul lantern and a glowstone a few steps away. Screenshot: does each light the floor, the
  walls and Leon around it, in its colour (orange, blue, pale yellow)? Break the torch: does its light go out?
- The **Minecraft Lights** section says which RE4 light settings work. Screenshot it. Untick it again if RE4
  misbehaves.

## 6. Play a while (as long as you like)
- Play on through chapter 1. Whenever something is wrong (stuck in RE4's turn, a door or ladder that
  doesn't work, a cutscene without your character), note roughly when.

## 7. Send
- **Make support zip** (top of the menu). It saves the diagnostics report first and puts everything in one
  zip on your Desktop; the menu shows the file name. Send that zip and your screenshots.
