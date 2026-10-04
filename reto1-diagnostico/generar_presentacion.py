"""
Genera resultados/presentacion.html: una pagina (Bootstrap 5 + Chart.js) para apoyar la sustentacion del Reto 1.
Todas las cifras se calculan desde el kit con las funciones de analizar.py (nada escrito a mano).

Uso:
    python generar_presentacion.py --kit ../kit --salida resultados
Navegacion: flechas <- -> (o AvPag/RePag) saltan entre secciones; tecla F = pantalla completa.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path

import numpy as np
import pandas as pd

from analizar import (cargar_eventos, cargar_httperr, cargar_iis, cargar_perfmon,
                      disponibilidad, linea_tiempo, senales_diarias)

PAGOS = ["/api/pagos/iniciar", "/api/pagos/confirmar"]
DIAS = ["lun", "mar", "mié", "jue", "vie", "sáb", "dom"]


def etiqueta(t, hora=True) -> str:
    t = pd.Timestamp(t)
    return f"{DIAS[t.dayofweek]} {t:%d}" + (f" {t:%H:%M}" if hora else "")


def datos(kit: Path) -> dict:
    notas: list[str] = []
    iis, http = cargar_iis(kit, notas), cargar_httperr(kit)
    perf, ev = cargar_perfmon(kit, notas), cargar_eventos(kit)
    u = iis[iis["cs-uri-stem"] != "/health"]

    disp = disponibilidad(iis, http)
    d18 = disp.loc[pd.Timestamp("2026-09-18").date()]
    sem = disp.loc["SEMANA"]

    tl = linea_tiempo(iis, http, "2026-09-18 08:00", "2026-09-18 16:59")
    tl["errores"] = tl["errores_5xx"] + tl["503_httpsys"]

    mem = perf["w3wp_mb"].resample("30min").max()
    disco = (perf["disco_libre_mb"].resample("1h").last() / 1024).round(2)
    sen = senales_diarias(iis, perf)

    # memoria vs pagos (por hora, sin la hora del reinicio)
    pag = u[u["cs-uri-stem"].isin(PAGOS) & (u["sc-status"] < 500)]
    hr = pd.DataFrame({"pagos": pag.set_index("ts").resample("1h").size(),
                       "mem": perf["w3wp_mb"].resample("1h").last()})
    hr["delta"] = hr["mem"].diff()
    x = hr.loc["2026-09-16 04:00":"2026-09-18 12:00"].dropna()
    x = x[~x.index.hour.isin([2, 3])]
    corr = float(np.corrcoef(x["pagos"], x["delta"])[0, 1])

    # embudo
    f = u[u["cs-uri-stem"].isin(PAGOS)]
    emb = f.groupby([f["ts"].dt.date, "cs-uri-stem"]).size().unstack()
    ratio = (emb["/api/pagos/confirmar"] / emb["/api/pagos/iniciar"]).round(2)

    health_fallos = int(http["cs-uri"].str.startswith("/health").sum())
    return {
        "disp18": float(d18["disponibilidad_pct"]), "dispSem": float(sem["disponibilidad_pct"]),
        "fallidas18": int(d18["fallidas_5xx_iis"] + d18["fallidas_503_httpsys"]),
        "f5xx": int(d18["fallidas_5xx_iis"]), "f503": int(d18["fallidas_503_httpsys"]),
        "healthFallos": health_fallos, "corr": round(corr, 3),
        "inc": {"x": [t.strftime("%H:%M") for t in tl.index],
                "p95": [None if pd.isna(v) else round(v / 1000, 2) for v in tl["p95_ms"]],
                "err": [int(v) for v in tl["errores"]]},
        "mem": {"x": [etiqueta(t) for t in mem.index],
                "y": [None if pd.isna(v) else round(v) for v in mem]},
        "disco": {"x": [etiqueta(t) for t in disco.index], "y": disco.tolist()},
        "dias": {"x": [etiqueta(d, False) for d in sen.index],
                 "p95": sen["p95_ms"].tolist(), "mem": sen["w3wp_pico_mb"].tolist()},
        "ratio": {"x": [etiqueta(d, False) for d in ratio.index], "y": ratio.tolist()},
        "disp": [{"dia": etiqueta(i, False), "pet": int(r["peticiones"]),
                  "f": int(r["fallidas_5xx_iis"] + r["fallidas_503_httpsys"]),
                  "d": float(r["disponibilidad_pct"])} for i, r in disp.drop("SEMANA").iterrows()],
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--kit", default="../kit", type=Path)
    ap.add_argument("--salida", default="resultados", type=Path)
    a = ap.parse_args()
    a.salida.mkdir(parents=True, exist_ok=True)
    plantilla = (Path(__file__).parent / "plantilla_presentacion.html").read_text(encoding="utf-8")
    d = datos(a.kit)
    html = plantilla.replace("/*__DATOS__*/null", json.dumps(d, ensure_ascii=False))
    for k in ["disp18", "dispSem", "fallidas18", "f5xx", "f503", "healthFallos", "corr"]:
        v = d[k]
        txt = (f"{v:.1f}".replace(".", ",") if k.startswith("disp") else
               f"{v:.3f}".replace(".", ",") if k == "corr" else f"{v:,}".replace(",", "."))
        html = html.replace("{{" + k + "}}", txt)
    (a.salida / "presentacion.html").write_text(html, encoding="utf-8")
    print(f"Listo: {a.salida / 'presentacion.html'}  (abrelo en el navegador)")


if __name__ == "__main__":
    main()
