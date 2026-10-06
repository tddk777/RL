# RL

A 3D card game made with Godot 4.7 and GDScript. The camera looks down at a
table; you hold a fanned hand of cards, play them onto the table and draw from
the deck.

## Setup (Windows, everything on E:)

All local installs for this project go on the **E: drive** (see `CLAUDE.md`).

1. Clone the repo to `E:\Projects\RL`:
   ```
   git clone https://github.com/tddk777/RL.git E:\Projects\RL
   ```
2. Install Godot to `E:\Tools\Godot` (downloads and verifies the official
   build, and turns on self-contained mode so editor data stays on E:):
   ```
   powershell -ExecutionPolicy Bypass -File E:\Projects\RL\tools\setup-windows.ps1
   ```
3. Open the project:
   ```
   E:\Projects\RL\tools\open-editor.cmd
   ```
   Press **F5** in the editor to run the game.

## What's in the starter

- `scenes/main.tscn`: table, fixed camera, lighting, deck, play zone and HUD.
- `scenes/card.tscn`: a card with cost, title and description labels.
- `data/cards/`: six placeholder cards. Add a card by duplicating a `.tres` file
  and editing it in the Inspector; the deck picks up every file in this folder.
- Controls: hover a card to lift it, click it to play it, click the deck to draw
  (hand limit 8).

The card effects in the descriptions are placeholders; nothing resolves yet.
