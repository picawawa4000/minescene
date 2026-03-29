# MineScene: Minecraft level viewer

## Usage

There are binaries for macOS and Linux provided in the Releases tab. On Windows, try using a Linux VM as there will likely never be a build for Windows.

## Commands

There's in-app documentation for these, but it's not that obvious, so this can't hurt. (These may not be accurate or complete, as I wrote them from memory.)

- `/help [command]` - Get a list of all commands, or detailed help for the specified command.

- `/tp <pos>` - Teleport to the specified position. (Supports relative coordinates via `~`.)

- `/seed` - Manipulate the world seed.
  - `/seed get` - Print the current seed.
  - `/seed copy` - Copy the current seed to the clipboard.
  - `/seed set <seed>` - Set the seed.
  - `/seed paste` - Paste the seed from the clipboard.

- `/dimension` - Manipulate the active worldgen noise settings.
  - `/dimension get` - Print the current noise settings ID.
  - `/dimension list` - List discovered noise settings IDs from the loaded datapacks.
  - `/dimension set <id>` - Rebuild worldgen using that noise settings entry.
  - This operates on noise settings, not the dimension registry entry itself. Changing it can alter min Y and total build height, so it rebuilds worldgen state much like switching seeds.

- `/waypoint` - Manipulate waypoints (that is, combinations of seeds and positions).
  - `/waypoint save <name> [pos] [seed]` - Create a new waypoint.
  - `/waypoint load <name>` - Teleport to a waypoint.
  - `/waypoint info [name]` - Get information about a waypoint, or list all waypoints.
  - `/waypoint file <save|load> <file>` - Save waypoints to or load waypoints from a `.txt` file (extension not required in command). File location is platform-dependent.

- `/colormap <file>` - Load biome colour overrides from a `.txt` file in the platform `minescene/colormaps` directory (extension not required in command).
  - Line format: `<namespaced-biome-id> <red> <green> <blue>`.
  - Biome IDs without a namespace default to `minecraft:`. (This is done primarily so that colourmaps from cubiomes-viewer can be directly loaded into MineScene with no modification.)
  - Colour components must be decimal integers from `0` to `255`.

- `/setting` - Configure settings. As of now, only really useful for keybinds.
  - `/setting set <setting> <value>` - Set the value of a setting.
  - `/setting get <setting>` - Get the current value of a setting.
  - `/setting help [setting]` - Get information about a setting, or list all settings.
