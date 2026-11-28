# Layout of the .dmg window, for dmgbuild (https://dmgbuild.readthedocs.io).
# scripts/make-dmg.sh passes: app, background and icon with -D.
import os.path

app = defines["app"]  # noqa: F821 (provided by dmgbuild)
app_name = os.path.basename(app)

format = "UDZO"
filesystem = "HFS+"
size = None

files = [app]
symlinks = {"Applications": "/Applications"}

# Volume icon: the app icon instead of the generic grey disk.
icon = defines.get("icon")  # noqa: F821

# A compact window: the background is 640x440 and keeps everything important above y=380,
# so it looks right whether Finder counts the title bar in the window's height or not.
background = defines["background"]  # noqa: F821
window_rect = ((200, 140), (640, 428))
default_view = "icon-view"
show_toolbar = False
show_pathbar = False
show_status_bar = False
show_tab_view = False
show_sidebar = False
show_icon_preview = False
include_icon_view_settings = True

icon_size = 128
text_size = 13
arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
label_pos = "bottom"

# Icon centres, matching the arrow drawn on the background.
icon_locations = {
    app_name: (170, 190),
    "Applications": (470, 190),
}
