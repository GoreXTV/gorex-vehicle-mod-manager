#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
import_mod.py - Import-Tool fuer den Vehicle Mod Manager (MTA:SA)

Kopiert Mod-Dateien (.dff/.txd/.col/Bilder) nach  mods/<kategorie>/<mod-id>/  und schreibt mod.json.
Danach im Spiel RESCAN druecken (oder /vmm rescan) - der Mod erscheint automatisch.

BEISPIELE
  Einzelner Mod:
    python import_mod.py --category infernus --name "Lamborghini Style" --author GoreX ^
        --files C:\\mods\\lambo\\infernus.dff C:\\mods\\lambo\\infernus.txd --preview C:\\mods\\lambo\\shot.png

  Ganzer Ordner voller Mods (jeder Unterordner = ein Mod), automatisch nummeriert:
    python import_mod.py --category infernus --batch C:\\mods\\alle_infernus --prefix "Infernus"

  Backlight (Textur statt Modell):
    python import_mod.py --category backlights --name "Red Glow" --files glow.png

  Mit Oberflaeche (falls tkinter installiert ist):
    python import_mod.py --gui
"""
import argparse
import json
import os
import re
import shutil
import sys
from pathlib import Path

from normalize_infernus_collision import normalize_dff, read_standard

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_MODS = os.path.normpath(os.path.join(HERE, "..", "mods"))

MODEL_EXT = {".dff", ".txd", ".col"}
IMAGE_EXT = {".png", ".jpg", ".jpeg", ".dds", ".tga"}
ALLOWED = MODEL_EXT | IMAGE_EXT


def safe_id(text):
    """Ordnername, der vom Server akzeptiert wird: nur A-Z a-z 0-9 _ - ."""
    s = re.sub(r"[^A-Za-z0-9_.-]+", "_", text.strip()).strip("._-")
    return s[:60] or "mod"


def next_number(cat_dir, prefix):
    """Naechste freie Nummer (001, 002, ...) anhand vorhandener Ordner <prefix>_NNN."""
    hi = 0
    if os.path.isdir(cat_dir):
        for n in os.listdir(cat_dir):
            m = re.match(r"^%s_(\d+)$" % re.escape(prefix), n)
            if m:
                hi = max(hi, int(m.group(1)))
    return hi + 1


def parse_ints(text):
    out = []
    for part in re.split(r"[,\s]+", text or ""):
        if part.strip().isdigit():
            out.append(int(part))
    return out


def import_one(mods_dir, category, name, files, preview=None, author="", desc="", tags=None,
               models=None, mod_id=None, prefix=None, overwrite=False, dry=False):
    category = safe_id(category).lower()
    cat_dir = os.path.join(mods_dir, category)
    files = [f for f in files if os.path.splitext(f)[1].lower() in ALLOWED and os.path.isfile(f)]
    if not files:
        raise ValueError("Keine gueltigen Dateien (.dff/.txd/.col/.png/.jpg/.dds/.tga) gefunden.")

    # Validate before copying. Every imported Infernus uses the same stock COL.
    normalized = {}
    if category == "infernus":
        standard = read_standard()
        for f in files:
            if f.lower().endswith('.dff'):
                normalized[f] = normalize_dff(Path(f).read_bytes(), standard)
            elif f.lower().endswith('.col'):
                normalized[f] = standard

    if not mod_id:
        if prefix:
            n = next_number(cat_dir, safe_id(prefix).lower())
            mod_id = "%s_%03d" % (safe_id(prefix).lower(), n)
            if not name:
                name = "%s #%03d" % (prefix, n)
        else:
            mod_id = safe_id(name or os.path.basename(os.path.dirname(files[0])))
    mod_id = safe_id(mod_id)
    if mod_id.startswith("_"):
        mod_id = mod_id.lstrip("_")
    dest = os.path.join(cat_dir, mod_id)
    if os.path.exists(dest) and not overwrite:
        raise FileExistsError("Existiert bereits: %s (--overwrite zum Ersetzen)" % dest)

    meta = {"name": name or mod_id}
    if author:
        meta["author"] = author
    if desc:
        meta["description"] = desc
    if tags:
        meta["tags"] = tags
    if models:
        meta["models"] = models

    exts = {os.path.splitext(f)[1].lower() for f in files}
    dff = next((os.path.basename(f) for f in files if f.lower().endswith(".dff")), None)
    txd = next((os.path.basename(f) for f in files if f.lower().endswith(".txd")), None)
    col = next((os.path.basename(f) for f in files if f.lower().endswith(".col")), None)
    img = next((os.path.basename(f) for f in files if os.path.splitext(f)[1].lower() in IMAGE_EXT), None)
    if dff: meta["dff"] = dff
    if txd: meta["txd"] = txd
    if col: meta["col"] = col
    if img and not (exts & MODEL_EXT):
        meta["image"] = img

    print("[%s] %s  ->  %s" % (category, meta["name"], dest))
    if dry:
        return dest
    os.makedirs(dest, exist_ok=True)
    for f in files:
        base = os.path.basename(f)
        if not re.match(r"^[A-Za-z0-9_.-]+$", base):
            base = safe_id(os.path.splitext(base)[0]) + os.path.splitext(base)[1].lower()
            for k in ("dff", "txd", "col", "image"):
                if meta.get(k) == os.path.basename(f):
                    meta[k] = base
        if f in normalized:
            Path(dest, base).write_bytes(normalized[f])
        else:
            shutil.copy2(f, os.path.join(dest, base))
    if preview and os.path.isfile(preview):
        ext = os.path.splitext(preview)[1].lower()
        if ext in (".png", ".jpg", ".jpeg"):
            shutil.copy2(preview, os.path.join(dest, "preview" + ext))
    with open(os.path.join(dest, "mod.json"), "w", encoding="utf-8") as fh:
        json.dump(meta, fh, indent=2, ensure_ascii=False)
    return dest


def find_preview(folder):
    for n in sorted(os.listdir(folder)):
        if re.match(r"^(preview|thumb|screenshot|image)\.(png|jpe?g)$", n, re.I):
            return os.path.join(folder, n)
    return None


def import_batch(mods_dir, category, source, prefix, author="", tags=None, models=None, dry=False):
    """Jeder Unterordner von <source> ist ein Mod (dff/txd/Bild werden automatisch gefunden)."""
    count = 0
    for sub in sorted(os.listdir(source), key=lambda s: [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]):
        folder = os.path.join(source, sub)
        if not os.path.isdir(folder):
            continue
        files = [os.path.join(folder, f) for f in os.listdir(folder)
                 if os.path.splitext(f)[1].lower() in ALLOWED and not re.match(r"^preview", f, re.I)]
        if not files:
            print("  uebersprungen (keine Dateien): %s" % sub)
            continue
        try:
            import_one(mods_dir, category, None, files, find_preview(folder), author=author, tags=tags,
                       models=models, prefix=prefix or category, dry=dry)
            count += 1
        except Exception as e:
            print("  FEHLER bei %s: %s" % (sub, e))
    return count


def run_gui(mods_dir):
    import tkinter as tk
    from tkinter import filedialog, messagebox

    root = tk.Tk()
    root.title("Vehicle Mod Manager - Import")
    state = {"files": [], "preview": None}
    cats = sorted(d for d in os.listdir(mods_dir) if os.path.isdir(os.path.join(mods_dir, d)) and not d.startswith("_")) \
        if os.path.isdir(mods_dir) else ["infernus", "backlights", "wheels"]

    def row(label, r):
        tk.Label(root, text=label, anchor="w").grid(row=r, column=0, sticky="w", padx=8, pady=3)

    cat = tk.StringVar(value=cats[0] if cats else "infernus")
    row("Category", 0)
    tk.Entry(root, textvariable=cat, width=34).grid(row=0, column=1, padx=8)
    name, author, tags, models = tk.StringVar(), tk.StringVar(), tk.StringVar(), tk.StringVar()
    for i, (lbl, var) in enumerate((("Name", name), ("Author", author), ("Tags (comma)", tags), ("Model IDs (optional)", models)), 1):
        row(lbl, i)
        tk.Entry(root, textvariable=var, width=34).grid(row=i, column=1, padx=8)
    info = tk.Label(root, text="No files selected", anchor="w", fg="gray")
    info.grid(row=6, column=0, columnspan=2, sticky="w", padx=8)

    def pick_files():
        fs = filedialog.askopenfilenames(title="Mod files", filetypes=[("Mod files", "*.dff *.txd *.col *.png *.jpg *.dds *.tga")])
        if fs:
            state["files"] = list(fs)
            info.config(text="%d file(s) selected" % len(fs))

    def pick_preview():
        f = filedialog.askopenfilename(title="Preview image", filetypes=[("Images", "*.png *.jpg *.jpeg")])
        if f:
            state["preview"] = f

    def do_import():
        try:
            dest = import_one(mods_dir, cat.get(), name.get(), state["files"], state["preview"], author=author.get(),
                              tags=[t.strip() for t in tags.get().split(",") if t.strip()],
                              models=parse_ints(models.get()) or None,
                              prefix=None if name.get().strip() else cat.get())
            messagebox.showinfo("Import", "Imported to:\n%s\n\nPress RESCAN in the panel." % dest)
        except Exception as e:
            messagebox.showerror("Import", str(e))

    tk.Button(root, text="Select files ...", command=pick_files).grid(row=5, column=0, padx=8, pady=8, sticky="w")
    tk.Button(root, text="Select preview ...", command=pick_preview).grid(row=5, column=1, padx=8, pady=8, sticky="w")
    tk.Button(root, text="IMPORT", command=do_import, width=20).grid(row=7, column=0, columnspan=2, pady=10)
    root.mainloop()


def main():
    ap = argparse.ArgumentParser(description="Vehicle Mod Manager - Mods importieren")
    ap.add_argument("--mods-dir", default=DEFAULT_MODS, help="Pfad zum mods-Ordner (Standard: ../mods)")
    ap.add_argument("--gui", action="store_true", help="Oberflaeche starten (tkinter)")
    ap.add_argument("--category", help="Kategorie-Ordner, z. B. infernus, backlights, wheels")
    ap.add_argument("--name", help="Anzeigename")
    ap.add_argument("--id", help="Ordnername (Standard: aus Name/Prefix erzeugt)")
    ap.add_argument("--author", default="")
    ap.add_argument("--description", default="")
    ap.add_argument("--tags", default="", help="Komma-getrennt")
    ap.add_argument("--models", default="", help="Modell-IDs, z. B. 411 oder 1025,1073")
    ap.add_argument("--files", nargs="*", default=[], help="Mod-Dateien (.dff/.txd/.col/Bild)")
    ap.add_argument("--preview", help="Preview-Bild (png/jpg)")
    ap.add_argument("--batch", help="Ordner, dessen Unterordner je ein Mod sind")
    ap.add_argument("--prefix", help="Praefix fuer Auto-Nummerierung, z. B. Infernus -> infernus_001 / 'Infernus #001'")
    ap.add_argument("--overwrite", action="store_true")
    ap.add_argument("--dry-run", action="store_true")
    a = ap.parse_args()

    if a.gui:
        try:
            run_gui(a.mods_dir)
        except ImportError:
            print("tkinter ist nicht installiert - nutze die Kommandozeile (siehe --help).")
            return 1
        return 0
    if not a.category:
        ap.print_help()
        return 1

    tags = [t.strip() for t in a.tags.split(",") if t.strip()]
    models = parse_ints(a.models) or None
    try:
        if a.batch:
            n = import_batch(a.mods_dir, a.category, a.batch, a.prefix, a.author, tags, models, a.dry_run)
            print("%d Mod(s) importiert." % n)
        else:
            import_one(a.mods_dir, a.category, a.name, a.files, a.preview, a.author, a.description, tags,
                       models, a.id, a.prefix, a.overwrite, a.dry_run)
            print("Fertig. Im Panel RESCAN druecken.")
    except Exception as e:
        print("FEHLER:", e)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
