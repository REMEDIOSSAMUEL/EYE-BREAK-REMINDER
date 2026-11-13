# Accessibility

Eye Break Reminder keeps the existing native Win32 controls and five theme choices. Custom accents affect emphasis such as the timer ring, active navigation, primary actions and status indicators; they do not recolour the background, layout or general typography.

## Custom colour contrast

The selected RGB value is preserved as entered. For primary action buttons, the app selects black or white text based on contrast with the button colour. Accent-coloured status text is moved toward black or white only as much as needed to meet its contrast target against the current background; this display adjustment does not alter the saved colour. Timer rings and other non-text indicators receive a contrasting outline when the selected accent is too close to the surrounding surface.

Focus indicators remain visible independently of the chosen accent. The colour buttons are tab stops and can be opened with the keyboard. The native Windows colour dialog supplies keyboard-operable basic/custom swatches, RGB fields, and OK/Cancel buttons. Disabled controls continue to use the theme's distinguishable disabled styling.

## High contrast and Forced Colors

High Contrast Dark and High Contrast Light use their own accessible palettes instead of custom accents. When Windows Forced Colors is active, the app uses the system window, text, highlight, hotlight and highlight-text colours. These system settings take priority over decorative custom colours, and changes reported by Windows cause the UI theme to be reapplied. Custom preferences remain stored and return when normal colour rendering resumes.

The optional distinct-break-colour setting affects normal themes. High contrast always keeps work and break accents distinct for state recognition. The existing reduced-motion behavior remains active.

## Verification

The core suite checks the R/G/B conversion and text contrast choices for very dark and very light colours. The isolated Windows GUI suite exercises both high-contrast themes while custom colours are saved, verifies that rendered timer-ring pixels use the high-contrast palette, and checks keyboard focus and native picker activation. The system-wide Windows Forced Colors setting was not changed during local testing; if it is enabled on the test system, record that state and repeat the rendered-color checks without toggling it for the user.
