# Keyframe Program Language Specs

Keyframe programs are programs that can be used to automate capturing large amounts of content. They are stored in `<name>.kfp` files in the `/programs` directory in the user's local data directory, and are run via the in-app command `/keyframe program run <name>`.

## Whitespace

Whitespace (e.g. tabs and spaces) at the beginning of lines are to be ignored. There must be at least one space between keywords.

## Comments

Comments come in two varieties: C-style `/**/` block comments and C++-style `//` line comments. They work as you'd expect in those languages.

## Header

The header of a keyframe program describes how the scenes in the program are to be rendered. They have the following format:

```text
PROGRAM [WITH <program-attribute> <value>] ...
```

The following program attributes along with their values are supported:

* `RENDER-DISTANCE`: an integer representing the total render distance with LODs in chunks. Equivalent to the `video.renderDistance` setting. Must be >0.
* `LOD-NEAR-DISTANCE`: an integer representing the number of chunks before LODs start. Equivalent to the `video.terrainLodNearDistance` setting. Must be >0.
* `LOD-STEP-DISTANCE`: an integer representing the number of chunks between levels of distance. Equivalent to the `video.terrainLodStepDistance` setting. Must be >0.
* `MOTION-SPEED`: a real representing the motion speed in blocks per second. Must be >0. Defaults to 1.
* `SPIN-SPEED`: a real representing the base rotation speed in degrees per second (unit of measure subject to change based on technical demands). Only used for spin keyframes. Must be >0. Defaults to 10.
* `SURFACE-ONLY`: a boolean representing whether only the surface should be rendered. Defaults to false.

It is not required to express any program attributes.

## Scenes

Scenes are sets of keyframes that are rendered in sequence and stitched to produce the final video. Every scene has the following format:

```text
SCENE <index> SEED <seed> AT-POSITION <x> <y> <z> [WITH <scene-attribute> <value>] ...
[KEYFRAME-LIST]
```

The index is the number that the scene is to be played at, and must be greater than or equal to 0. Scenes are to be played in order of ascending index. Gaps in index are permitted. Scenes do not have to be ordered in the file in order of ascending index.

The seed is the seed that the scene is to be rendered on. It must be a valid seed as accepted by `/seed set`.

The position is the base position in the world (the "scene anchor"). Keyframes are expressed relative to this position.

Scene attribues are currently the same as program attributes. They override program attributes where possible. If a given attribute is not expressed in either the program or scene header and has no default, an error is thrown. It is not required to express any scene attributes.

The following shorthand is also supported:

```text
SCENE <index> WAYPOINT <waypoint> [OFFSET <delta-x> <delta-y> <delta-z>] [WITH <scene-attribute> <value>] ...
[KEYFRAME-LIST]
```

This is the same as the above header format, except the seed and position are to be loaded from the given waypoint. The offset is from the origin specified in the waypoint.

The body of a scene consists of keyframes. It is illegal for a scene to have no keyframes. There are different kinds of keyframes, such as position keyframes or spin keyframes, and each one represents an instruction to the renderer.

Position keyframes have the following format:

```text
POSITION <x> <y> <z> [ROTATION <yaw> <pitch>]
```

They represent instructions to move to the given position. These are the only keyframes accessible in-app (for now...). Consecutive position keyframes will be interpolated the same way as keyframes set in-app are. The position is relative to the scene anchor. Angle is linearly interpolated and does not depend on `SPIN-SPEED`. If no rotation is provided, it will not change from the last keyframe. If the first keyframe in any given scene has no rotation provided, an error is thrown.

Spin keyframes have the following format:

```text
SPIN <delta-yaw> <delta-pitch> [FROM <yaw> <pitch>] [SPEED <degrees-per-second>]
```

They represent instructions to spin the camera with the given yaw and pitch. If a `FROM` argument is supplied, the camera will begin by snapping to that angle; otherwise it will keep its current angle unchanged. It will then rotate through the given delta at the given speed, or, if none is provided, at the default spin speed defined in the program or scene attributes. The yaw delta may be greater than one full turn; however, it is illegal for pitch to exit the range [-90, +90] at any time. (This behaviour may change in the future.) If a spin keyframe is the first keyframe in a scene, it executes at (0, 0, 0) with starting yaw as 0 and starting pitch as 0 (unless `FROM` is supplied). If both yaw and pitch are specified, `SPEED` applies to the combined total of both axes, not each individual one.

Template keyframes have the following format:

```text
INVOKE-TEMPLATE <template-name>
```

They represent instructions to invoke the given template. Templates will be explained more in the following section.

## Scene Templates

Scene templates are sets of keyframes that can be inserted into scenes. They are essentially copy-pasted upon invocation, using the scene anchor of the scene they are invoked from. They have the following format:

```text
TEMPLATE <template-name>
[KEYFRAME-LIST]
```

Templates may invoke other templates. It is illegal for a template to have no keyframes, or for a template to reference itself or another template that references it, even indirectly. (This prevents cycles, which cannot be broken under this architecture.)
