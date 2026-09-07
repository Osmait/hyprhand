#!/usr/bin/env python3
"""Small GTK4 app for the README's observe/type/click/verify walkthrough.

Run through hyprhand launch in a disposable managed session. Requires Python GI
and GTK4. All content stays in this window; no files or network requests are made.
"""
import gi

gi.require_version("Gtk", "4.0")
from gi.repository import Gio, Gtk


def activate(app):
    window = Gtk.ApplicationWindow(application=app, title="Hyprhand · Note demo")
    window.set_default_size(860, 520)
    header = Gtk.HeaderBar()
    window.set_titlebar(header)
    box = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=18)
    for side in ("top", "bottom", "start", "end"):
        box.set_property(f"margin-{side}", 36)
    eyebrow = Gtk.Label(label="DESKTOP AUTOMATION / LOCAL DEMO", xalign=0)
    eyebrow.add_css_class("dim-label")
    box.append(eyebrow)
    title = Gtk.Label(label="From a command to a visible result", xalign=0)
    title.add_css_class("title-1")
    box.append(title)
    description = Gtk.Label(
        label="Hyprhand types into this field. Apply the text, then observe the result.",
        xalign=0, wrap=True,
    )
    box.append(description)
    entry = Gtk.Entry(text="Draft note", hexpand=True)
    entry.update_property([Gtk.AccessibleProperty.LABEL], ["Note text"])
    box.append(entry)
    button = Gtk.Button(label="Apply text", halign=Gtk.Align.START)
    button.add_css_class("suggested-action")
    box.append(button)
    box.append(Gtk.Separator())
    status = Gtk.Label(label="Waiting for input", xalign=0)
    status.add_css_class("heading")
    box.append(status)
    result = Gtk.Label(label="Your applied text will appear here.", xalign=0, wrap=True,
                       selectable=True)
    box.append(result)
    footer = Gtk.Label(label="Observe → act → observe and verify", xalign=0,
                       vexpand=True, valign=Gtk.Align.END)
    footer.add_css_class("dim-label")
    box.append(footer)

    def apply_text(_):
        result.set_text(entry.get_text())
        status.set_text("Text applied successfully")

    button.connect("clicked", apply_text)
    window.set_child(box)
    window.present()
    entry.grab_focus()


if __name__ == "__main__":
    app = Gtk.Application(application_id="org.hyprhand.NoteDemo",
                          flags=Gio.ApplicationFlags.NON_UNIQUE)
    app.connect("activate", activate)
    app.run([])
