# Container Workspace Notes

This file is for AI agents working inside the devcontainer.

## Workspace model

- The container workspace root is `/workspace`.
- The product app lives at `/workspace/projects/hello_eink`.
- `/workspace/projects/hello_eink` is its own git repository.
- The training/examples workspace remains under `/workspace/apps`.
- The shared Zephyr manifest is `/workspace/west.yml`.

## Important boundaries

- Do not assume `hello_eink` lives under `/workspace/apps`.
- Do not recreate the old sibling mount `../hello_eink-app`.
- Do not use host-only paths such as `/home/guilherme/...` when working from inside the container unless explicitly asked.
- Do not move content back out of `/workspace/projects/hello_eink`.
- Treat `backup/` content outside the mounted workspace as historical backup, not active source.

## Build and tooling

- The shared helper script is `/workspace/scripts/zephyr-project.sh`.
- The active project may be set to `/workspace/projects/hello_eink`.
- The app repo owns its custom board, module, and patch content locally:
  - `/workspace/projects/hello_eink/boards/custom/eink_llss_esp32`
  - `/workspace/projects/hello_eink/modules/wifi_prov`
  - `/workspace/projects/hello_eink/patches`

## Editing expectations

- Keep the shared workspace focused on common Zephyr tooling and course examples.
- Keep product-specific changes inside `/workspace/projects/hello_eink` unless the change is truly shared.
- If a build/debug path looks wrong, check whether it still assumes `/workspace/apps/hello_eink` and update it to `/workspace/projects/hello_eink`.