# RE4 Remake: Minecraft mod (work in progress)

REFramework Lua scripts that bring Minecraft's look and feel into Resident Evil 4 Remake.

## Requirements
- Resident Evil 4 Remake on PC (Steam)
- [REFramework](https://github.com/praydog/REFramework-nightly/releases) (`REFramework.zip` → `dinput8.dll` in the game folder)

## Install
Copy the `.lua` files into `<RE4 game folder>\reframework\autorun\` and start the game.
Settings: press **Insert** → **Script Generated UI**.

## Scripts
- `minecraft_hearts.lua`: Leon's health shown as 10 Minecraft hearts, with half hearts and the low-health shake.
- `minecraft_first_person.lua`: first-person camera (toggle with **F5**) and Minecraft's `+` crosshair.
- `minecraft_creative.lua`: Creative mode: flying (double-tap **Space** or **F6**; WASD, Space up, Ctrl down, Shift faster) and no damage.
