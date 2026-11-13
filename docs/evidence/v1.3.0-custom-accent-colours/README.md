# v1.3.0 custom accent colour evidence

These PNG files were captured by the Windows GUI acceptance run on 2026-11-13. The test used the isolated v1.3.0 acceptance executable and a disposable profile. Timer screenshots were checked against the rendered ring pixels; the result JSON is kept in the local build evidence folder because it includes machine-specific paths.

- `native-choose-color-dialog.png`: the native ChooseColorW dialog with Basic colours, Custom colours, colour spectrum, RGB fields, OK and Cancel.
- `settings-custom-combo-*.png`: Appearance settings with a selected Work/Break pair. Three examples and black/white extremes are included.
- `custom-*-work.png` and `custom-*-break.png`: rendered timer rings for four custom colour pairs. `*-work-after-break.png` shows the Work accent returning after a break.
- `custom-high-contrast-*.png` and `timer-high-contrast-*-break.png`: readable high-contrast Work and Break palettes with saved custom colours.
- `timer-dark-break-accent-off.png`: the Work accent is used during a break when distinct break accents are disabled.
- `settings-high-contrast-visible-focus.png`: keyboard focus remains visible in High Contrast Light.
- `custom-reset-default-work.png`: the default Dark Work accent after Reset to Default Colours.
- `custom-cancel-keeps-green.png`: Cancel leaves the saved Work colour unchanged.
- `picker-resource-time-series.csv` and `reminder-window-resource-time-series.csv`: USER objects, GDI objects, handle count and memory samples during repeated interactions.
