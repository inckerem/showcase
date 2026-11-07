#!/usr/bin/env python3
import argparse
import bz2
import gzip
import hashlib
import io
import os
import shutil
import tarfile
from datetime import datetime, timezone
from pathlib import Path


def read_ar_members(path):
    data = Path(path).read_bytes()
    if data[:8] != b"!<arch>\n":
        raise ValueError(f"{path} is not an ar archive")
    off = 8
    members = {}
    while off + 60 <= len(data):
        header = data[off:off + 60]
        off += 60
        name = header[:16].decode("utf-8", "replace").strip()
        size = int(header[48:58].decode("ascii").strip())
        body = data[off:off + size]
        off += size + (size % 2)
        members[name.rstrip("/")] = body
    return members


def control_from_deb(path):
    members = read_ar_members(path)
    control_name = next((n for n in members if n.startswith("control.tar")), None)
    if not control_name:
        raise ValueError(f"{path} has no control.tar member")

    mode = "r:*"
    with tarfile.open(fileobj=io.BytesIO(members[control_name]), mode=mode) as tar:
        for member in tar.getmembers():
            normalized = member.name.lstrip("./")
            if normalized == "control":
                f = tar.extractfile(member)
                if f is None:
                    break
                return f.read().decode("utf-8")
    raise ValueError(f"{path} has no DEBIAN/control file")


def digest(path, algorithm):
    h = hashlib.new(algorithm)
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def package_entry(repo_root, deb_path):
    rel = deb_path.relative_to(repo_root).as_posix()
    control = control_from_deb(deb_path).rstrip()
    size = deb_path.stat().st_size
    return (
        f"{control}\n"
        f"Filename: {rel}\n"
        f"Size: {size}\n"
        f"MD5sum: {digest(deb_path, 'md5')}\n"
        f"SHA1: {digest(deb_path, 'sha1')}\n"
        f"SHA256: {digest(deb_path, 'sha256')}\n"
    )


def write_release(repo_root, packages_bytes):
    now = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S %z")
    package_files = [
        ("Packages", repo_root / "Packages"),
        ("Packages.gz", repo_root / "Packages.gz"),
        ("Packages.bz2", repo_root / "Packages.bz2"),
    ]
    lines = [
        "Origin: KCS",
        "Label: KCS",
        "Suite: stable",
        "Codename: ios",
        "Version: 1.0",
        "Architectures: iphoneos-arm iphoneos-arm64",
        "Components: main",
        "Icon: https://kcs.net.tr/repo/CydiaIcon.png",
        f"Date: {now}",
        "Description: KCS jailbreak package repository",
        "MD5Sum:",
    ]
    for name, path in package_files:
        lines.append(f" {digest(path, 'md5')} {path.stat().st_size} {name}")
    lines.append("SHA1:")
    for name, path in package_files:
        lines.append(f" {digest(path, 'sha1')} {path.stat().st_size} {name}")
    lines.append("SHA256:")
    for name, path in package_files:
        lines.append(f" {digest(path, 'sha256')} {path.stat().st_size} {name}")
    (repo_root / "Release").write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_index(repo_root):
    html = """<!doctype html>
<html lang="tr">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta name="theme-color" content="#3b82f6">
  <meta name="description" content="Showcase KCS Cydia deposu. Hotspot veya mevcut Wi-Fi ağıyla kablosuz CarPlay.">
  <title>Showcase KCS · Cydia deposu</title>
  <style>
    :root { --blue:#3b82f6; --purple:#8b5cf6; --ink:#16304e; --muted:#64748b; }
    * { box-sizing:border-box; }
    body { margin:0; color:var(--ink); font:16px/1.55 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;
      background:linear-gradient(135deg,#dbeafe 0%,#f0f4f8 33%,#fce7f3 68%,#e0e7ff 100%); min-height:100vh; }
    a { color:#2563eb; text-decoration:none; } a:hover { text-decoration:underline; }
    .wrap { max-width:990px; margin:auto; padding:28px 24px 70px; }
    header { display:flex; justify-content:space-between; align-items:center; gap:16px; }
    .brand { display:flex; align-items:center; gap:12px; color:var(--ink); font-weight:750; }
    .brand-mark { display:grid; place-items:center; width:38px; height:38px; border-radius:10px;
      color:#fff; background:linear-gradient(135deg,var(--blue),var(--purple)); font-size:12px; letter-spacing:-.03em; }
    nav { display:flex; gap:20px; font-size:14px; }
    .hero { margin-top:76px; display:grid; grid-template-columns:minmax(0,1fr) 300px; align-items:center; gap:32px; }
    .network { width:300px; max-width:100%; filter:drop-shadow(0 18px 30px #64748b22); }
    .eyebrow { color:#5b42ce; font-size:12px; font-weight:800; letter-spacing:.14em; text-transform:uppercase; }
    h1 { font-size:clamp(42px,7vw,74px); letter-spacing:-.055em; line-height:1.04; margin:15px 0 20px; }
    h1 span { background:linear-gradient(110deg,var(--blue),var(--purple),#ec4899); background-clip:text; -webkit-background-clip:text; color:transparent; }
    .lead { font-size:19px; color:#475569; max-width:670px; margin-bottom:30px; }
    .source { display:flex; align-items:center; gap:10px; flex-wrap:wrap; background:#fff; border:1px solid #c7d2fe;
      border-radius:17px; padding:9px 9px 9px 18px; box-shadow:0 18px 48px #64748b22; width:max-content; max-width:100%; }
    .source code { overflow:auto; white-space:nowrap; font-size:15px; }
    button { border:0; border-radius:11px; padding:12px 18px; background:linear-gradient(135deg,var(--blue),var(--purple));
      color:#fff; font:inherit; font-weight:700; cursor:pointer; }
    button:focus-visible,a:focus-visible { outline:3px solid #1d4ed8; outline-offset:3px; }
    .grid { display:grid; grid-template-columns:repeat(3,minmax(0,1fr)); gap:16px; margin:70px 0 34px; }
    .card { background:#ffffffd9; border:1px solid #fff; border-radius:20px; padding:24px; box-shadow:0 10px 30px #64748b13; }
    .card b { display:block; font-size:17px; margin-bottom:8px; } .card p { margin:0; color:#52657e; font-size:14px; }
    .steps { background:#fff; border-radius:22px; padding:28px 32px; } .steps h2 { margin:0 0 10px; font-size:24px; }
    .steps ol { margin-bottom:0; padding-left:22px; } .steps li { margin:9px 0; }
    footer { margin-top:34px; color:var(--muted); font-size:13px; }
    @media(max-width:800px) { nav { gap:10px; font-size:13px; } .hero { margin-top:54px; grid-template-columns:1fr; } .network { display:none; } .grid { grid-template-columns:1fr; margin-top:45px; }
      .source { display:block; width:100%; padding:10px; } .source code { display:block; padding:5px 7px 12px; white-space:normal; overflow-wrap:anywhere; }
      .source button { width:100%; } }
  </style>
</head>
<body>
  <div class="wrap">
    <header><a class="brand" href="https://kcs.net.tr/"><span class="brand-mark" aria-hidden="true">KCS</span><span>Kerem Cloud Services</span></a>
      <nav><a href="https://github.com/inckerem/showcase">GitHub</a><a href="Packages">Paketler</a></nav></header>
    <main>
      <section class="hero"><div><div class="eyebrow">KCS / Cydia Repository</div><h1>Eski iPad'ine <span>CarPlay</span> ekranı.</h1>
        <p class="lead">Showcase KCS, jailbreak'li iPad veya iPhone'u kablosuz CarPlay alıcısına dönüştürür. Kişisel erişim noktasıyla ya da iki cihazın bağlandığı mevcut Wi-Fi ağıyla çalışır.</p>
        <div class="source"><code id="repo-url">https://kcs.net.tr/repo/</code><button type="button" id="copy">Repo adresini kopyala</button></div></div>
        <svg class="network" viewBox="0 0 300 300" role="img" aria-label="iPhone ve iPad aynı Wi-Fi yönlendiricisine bağlı" xmlns="http://www.w3.org/2000/svg">
          <defs><linearGradient id="link" x1="0" x2="1"><stop stop-color="#3b82f6"/><stop offset="1" stop-color="#8b5cf6"/></linearGradient></defs>
          <path d="M75 90 Q150 45 226 90 M75 212 Q150 260 226 212" fill="none" stroke="url(#link)" stroke-width="3" stroke-dasharray="6 7"/>
          <rect x="23" y="55" width="70" height="127" rx="16" fill="#fff" stroke="#90a7d0" stroke-width="3"/>
          <rect x="31" y="68" width="54" height="94" rx="5" fill="#e0e7ff"/>
          <path d="M39 126h38m-38 10h31" stroke="#a5b4fc" stroke-width="3" stroke-linecap="round"/>
          <circle cx="58" cy="172" r="4" fill="#94a3b8"/>
          <rect x="205" y="113" width="79" height="125" rx="12" fill="#fff" stroke="#90a7d0" stroke-width="3"/>
          <rect x="213" y="126" width="63" height="96" rx="4" fill="#1e3a5f"/>
          <path d="M221 185q20-34 47-21" fill="none" stroke="#60a5fa" stroke-width="4" stroke-linecap="round"/>
          <circle cx="244" cy="230" r="3" fill="#94a3b8"/>
          <rect x="117" y="128" width="67" height="42" rx="10" fill="url(#link)"/>
          <path d="M130 142q20-17 40 0m-32 7q12-9 24 0" fill="none" stroke="#fff" stroke-width="3" stroke-linecap="round"/>
          <circle cx="150" cy="156" r="2.5" fill="#fff"/>
          <text x="55" y="203" text-anchor="middle" fill="#475569" font-size="12" font-family="sans-serif">iPhone</text>
          <text x="244" y="259" text-anchor="middle" fill="#475569" font-size="12" font-family="sans-serif">iPad</text>
        </svg></section>
      <section class="grid" aria-label="Özellikler">
        <div class="card"><b>Hotspot şart değil</b><p>Taşınabilir modem kullanıyorsan iki cihazı aynı Wi-Fi ağına bağla ve ayarlardan Mevcut Wi-Fi ağı seç.</p></div>
        <div class="card"><b>iOS 12 desteği</b><p>Şu an yayımlanan paket rootful iOS 12 içindir ve iPad Air üzerinde kullanıldı. Cihaz ve jailbreak uyumu değişebilir.</p></div>
        <div class="card"><b>Açık kaynak</b><p>Amine Rostane'nin özgün Showcase projesinin KCS tarafından sürdürülen GPL lisanslı sürümü.</p></div>
      </section>
      <section class="steps"><h2>Kurulum</h2><ol><li>Cydia, Sileo veya Zebra'ya yukarıdaki adresi kaynak olarak ekle.</li>
        <li><strong>Showcase (Rootful)</strong> paketini kur. KCS deposunda şu an rootless veya Taurine paketi yayımlanmıyor.</li>
        <li>Uygulamada Ayarlar → Wi-Fi Kurulumu bölümünden bağlantı şeklini seç.</li></ol>
        <p>Kullanım verisi paylaşımı varsayılan olarak kapalıdır. Tanılama arşivi yalnız onay verirsen KCS'ye gönderilir. <a href="https://github.com/inckerem/showcase#anonymous-usage">Veri ayrıntıları</a></p></section>
    </main>
    <footer>© Kerem Cloud Services · Özgün Showcase: <a href="https://github.com/amineross/showcase">Amine Rostane</a> · GPL-3.0-or-later · <a href="Release">APT Release</a></footer>
  </div>
  <script>document.getElementById('copy').addEventListener('click',function(){navigator.clipboard.writeText(document.getElementById('repo-url').textContent).then(()=>{this.textContent='Kopyalandı';});});</script>
</body>
</html>
"""
    (repo_root / "index.html").write_text(html, encoding="utf-8")


def main():
    parser = argparse.ArgumentParser(description="Generate a small jailbreak APT repository index.")
    parser.add_argument("repo", nargs="?", default="repo", help="Repository root containing debs/")
    args = parser.parse_args()

    repo_root = Path(args.repo).resolve()
    debs = sorted((repo_root / "debs").glob("*.deb"))
    if not debs:
        raise SystemExit(f"No .deb files found in {repo_root / 'debs'}")

    entries = [package_entry(repo_root, deb) for deb in debs]
    packages = "\n".join(entries).encode("utf-8")

    (repo_root / "Packages").write_bytes(packages)
    with gzip.open(repo_root / "Packages.gz", "wb", compresslevel=9) as f:
        f.write(packages)
    with bz2.open(repo_root / "Packages.bz2", "wb", compresslevel=9) as f:
        f.write(packages)

    source_depictions = Path(__file__).resolve().parents[1] / "depictions"
    if source_depictions.is_dir():
        target_depictions = repo_root / "depictions"
        if target_depictions.exists():
            shutil.rmtree(target_depictions)
        shutil.copytree(source_depictions, target_depictions)

    source_assets = Path(__file__).resolve().parents[1] / "assets"
    if source_assets.is_dir():
        target_icons = repo_root / "icons"
        if target_icons.exists():
            shutil.rmtree(target_icons)
        target_icons.mkdir(parents=True)
        shutil.copy2(source_assets / "showcase.png", target_icons / "showcase.png")
        shutil.copy2(source_assets / "profile.png", target_icons / "profile.png")
        shutil.copy2(source_assets / "profile.png", repo_root / "CydiaIcon.png")
        shutil.copy2(source_assets / "profile.png", repo_root / "icon.png")

    write_release(repo_root, packages)
    write_index(repo_root)
    print(f"Wrote Packages, Packages.gz, Packages.bz2, and Release for {len(debs)} deb(s).")


if __name__ == "__main__":
    main()
