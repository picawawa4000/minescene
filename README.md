# MineScene: Minecraft level viewer

## Usage

There are binaries for macOS and Linux provided in the Releases tab. On Windows, try using a Linux VM as there will likely never be a build for Windows.

## Vanilla Assets & Data

Neither the vanilla datapack nor the vanilla assets are shipped with this application. However, Python scripts are provided to download them for your convenience.

The vanilla data can be downloaded or extracted by using `Scripts/extract_vanilla_datapack.py --version <version>`. `<version>` defaults to 1.21.11 for now as it was the latest stable release when this tool was initially created, and 26.1 didn't really change anything in terms of data. (Remind me to change this when 26.2 releases.)

Structure rendering expects extracted vanilla assets on disk instead of bundling them in the app. These assets are not required unless you intend to employ structure rendering. Use `Scripts/download_vanilla_assets.py <version>` to fetch the official client jar from Mojang's version manifest and extract the `assets/` tree into `vanilla/<version>`.

Set `MINESCENE_DEBUG_BLOCKSTATES=1` to launch the blockstate debug viewer instead of terrain rendering. It loads representative blockstates from the extracted vanilla assets and lays them out in a line. Optional env vars:

- `MINESCENE_VANILLA_ASSETS_VERSION=1.21.11` to force a specific extracted asset version under `vanilla/`.
- `MINESCENE_VANILLA_ASSETS_PATH=relative/path/to/1.21.11` to point directly at an extracted asset root containing `assets/`.
- `MINESCENE_DEBUG_BLOCKSTATE_LIMIT=128` to cap how many blockstates are loaded into the debug strip.

## Commands

There's in-app documentation for these, but it's not that obvious, so this can't hurt. (These may not be accurate or complete, as I wrote them from memory.)

- `/help [command]` - Get a list of all commands, or detailed help for the specified command.

- `/tp <pos>` - Teleport to the specified position. (Supports relative coordinates via `~`.)

- `/seed` - Manipulate the world seed.
  - `/seed get` - Print the current seed.
  - `/seed copy` - Copy the current seed to the clipboard.
  - `/seed set <seed>` - Set the seed.
  - `/seed paste` - Paste the seed from the clipboard.

- `/waypoint` - Manipulate waypoints (that is, combinations of seeds and positions).
  - `/waypoint save <name> [pos] [seed]` - Create a new waypoint.
  - `/waypoint load <name>` - Teleport to a waypoint.
  - `/waypoint info [name]` - Get information about a waypoint, or list all waypoints.
  - `/waypoint file <save|load> <file>` - Save waypoints to or load waypoints from a `.txt` file (extension not required in command). File location is platform-dependent.

- `/setting` - Configure settings. As of now, only really useful for keybinds.
  - `/setting set <setting> <value>` - Set the value of a setting.
  - `/setting get <setting>` - Get the current value of a setting.
  - `/setting help [setting]` - Get information about a setting, or list all settings.
