# Preset-owned appearance and quiet App Lock transition

Remove the Settings Appearance card and all local Dark/Light controls. Restore only the saved preset/RGB; old device-level mode overrides are ignored and no longer persisted. Default/custom RGB uses dark surfaces; each named preset retains its defined artwork and palette, including the supplied Mint Light preset.

On correct App Lock password verification, start the existing Login Successful animation immediately. Authenticate the local session and fetch the saved theme inside this success transition, with the existing bounded wait and stale-session protections. Open the dashboard after the animation and internal work are complete. Do not display theme-check text or theme status snackbars in this flow. Incorrect-password and genuine authentication errors retain the existing behavior.

Settings preview screenshots are regenerated from the same native widgets so the website also stops showing the removed toggle. Native appearance persistence and the exact password-screen flow have focused regression coverage.
