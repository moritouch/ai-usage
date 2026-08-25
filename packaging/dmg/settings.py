import os


application = defines["app"]  # noqa: F821 - provided by dmgbuild
background_image = defines["background"]  # noqa: F821 - provided by dmgbuild
app_name = os.path.basename(application)

format = "UDZO"
filesystem = "APFS"
files = [application]
symlinks = {"Applications": "/Applications"}

background = background_image
window_rect = ((200, 200), (800, 500))
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
default_view = "icon-view"
include_icon_view_settings = True
include_list_view_settings = False

arrange_by = None
grid_offset = (0, 0)
grid_spacing = 100
scroll_position = (0, 0)
label_pos = "bottom"
text_size = 14
icon_size = 96
show_icon_preview = False

# Keep the Finder background out of the install surface even when users reveal
# dotfiles. dmgbuild creates this file at the volume root.
hide = [".background.png"]

icon_locations = {
    app_name: (180, 135),
    "Applications": (620, 135),
    ".background.png": (1200, 900),
}
