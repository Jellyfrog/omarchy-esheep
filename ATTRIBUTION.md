# Attribution

This plugin is a port of [desktopPet](https://github.com/Adrianotiger/desktopPet)
by **Adriano Petrucci** — the open-source revival of the '90s eSheep screen
mate. The animation format, the behaviour rules the engine follows (weighted
next-animation lists, border and gravity exits, `only=` placement filters,
child pets), and every sprite in `assets/` come from that project.

`Engine.js` is a fresh implementation of that behaviour for Quickshell, written
against the upstream C# (`src/dotNet/FormPet.cs`, `Animations.cs`, `Xml.cs`) and
the author's own JavaScript port,
[web-esheep](https://github.com/Adrianotiger/web-esheep) (GPL-3.0). This plugin
is GPL-3.0-or-later for the same reason.

## Sprites

Each pet under `assets/` was converted from its upstream `animations.xml` with
`tools/build-pets.py`. Nothing was redrawn; the conversion only decodes the
embedded PNG, applies the declared colour key, and rewrites the animation graph
as JSON.

| Pet | Upstream folder | Pet author | Sprite source |
|-----|-----------------|------------|---------------|
| eSheep (`esheep`) | `Pets/esheep64` | Adriano Petrucci | Sprites ripped by [LiL_Stenly](http://spritedatabase.net/game/2071) |
| gSheep Blue (`sheep-blue`) | `Pets/blue_sheep` | Oliver B. | Oliver B. |
| Neko (`neko`) | `Pets/neko` | Adriano Petrucci | Sprites from [webneko.net](https://webneko.net/) |
| Pingus (`pingus`) | `Pets/pingus` | Adriano Petrucci | Sprites from the [Pingus](https://github.com/Pingus/) project |
| Fox (`fox`) | `Pets/fox` | Michelle Tran | Michelle Tran, from [The Fox Tale](https://ganeshsar.github.io/thefoxtale/index.html) |

More pets live in the [upstream pet
database](https://github.com/Adrianotiger/desktopPet/tree/master/Pets). Any of
them can be converted with `tools/build-pets.py`; see the README. If you package
one for redistribution, carry its author's credit with it.

## Omarchy

The plugin targets the [Omarchy](https://github.com/basecamp/omarchy) shell and
uses its `qs.Commons` and `qs.Ui` components (theme colours, panel chrome) so it
looks like the rest of the desktop. Omarchy is MIT licensed; nothing from it is
copied into this repository.
