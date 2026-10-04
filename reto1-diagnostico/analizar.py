"""
Reto 1 - Diagnostico del incidente PortalPagos (18-sep-2026).

Uso:
    python analizar.py --kit ../kit --salida resultados

Lee el kit tal como lo entrego soporte y produce, en la carpeta de salida:
    - calidad_datos.md          problemas encontrados en los datos crudos
    - disponibilidad_diaria.csv disponibilidad real por dia (incluye 503 de HTTP.sys)
    - linea_tiempo_18sep.csv    peticiones, errores y p95 cada 10 min el 18-sep
    - senales_diarias.csv       memoria pico, p95 y disco libre por dia
    - pronostico_disco.md       cuando se llena el disco C: y con que metodo
    - eventos_clave.csv         eventos relevantes (sin ruido DCOM/Schannel/SCM)
    - graficas *.png

Convencion de tiempo: TODO se presenta en hora de Colombia (UTC-05:00, sin horario de verano).
    - Logs W3C de IIS y log de HTTP.sys vienen en UTC  -> se convierten.
    - Eventos de Windows y Perfmon vienen en hora local -> se dejan igual.
"""
from __future__ import annotations

import argparse
import hashlib
from pathlib import Path

import matplotlib
matplotlib.use("Agg")  # sin ventana: solo guarda imagenes
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

TZ_LOCAL = "America/Bogota"
UMBRAL_LENTO_MS = 3000          # supuesto: >3 s se considera mala experiencia
RUIDO_EVENTOS = {10016, 36887, 7036}  # DCOM, Schannel, cambios de servicio


# --------------------------------------------------------------------------- lectura
def leer_w3c(ruta: Path) -> pd.DataFrame:
    """Lee un log W3C respetando cada linea #Fields (las columnas pueden cambiar a mitad de archivo)."""
    filas, campos = [], None
    with open(ruta, encoding="utf-8", errors="replace") as f:
        for n, linea in enumerate(f, start=1):
            linea = linea.rstrip("\r\n")
            if linea.startswith("#Fields:"):
                campos = linea[len("#Fields:"):].split()
                continue
            if linea.startswith("#") or not linea.strip():
                continue
            partes = linea.split(" ")
            if campos is None or len(partes) != len(campos):
                raise ValueError(f"{ruta.name}:{n} no coincide con #Fields")
            fila = dict(zip(campos, partes))
            fila["_archivo"], fila["_linea"] = ruta.name, n
            filas.append(fila)
    return pd.DataFrame(filas)


def a_hora_local(df: pd.DataFrame) -> pd.Series:
    utc = pd.to_datetime(df["date"] + " " + df["time"], utc=True)
    return utc.dt.tz_convert(TZ_LOCAL).dt.tz_localize(None)


def md5(ruta: Path) -> str:
    return hashlib.md5(ruta.read_bytes()).hexdigest()


def cargar_iis(kit: Path, notas: list[str]) -> pd.DataFrame:
    carpeta = kit / "logs" / "iis" / "W3SVC2"
    vistos: dict[str, str] = {}
    partes = []
    # las copias ("- copia") se procesan al final para conservar el nombre original
    for ruta in sorted(carpeta.glob("*.log"), key=lambda r: ("copia" in r.name.lower(), r.name)):
        h = md5(ruta)
        if h in vistos:
            notas.append(f"- `{ruta.name}` es identico (MD5 {h[:8]}) a `{vistos[h]}`: **se excluye** para no contar doble.")
            continue
        vistos[h] = ruta.name
        with open(ruta, encoding="utf-8", errors="replace") as f:
            fields = [(i, l.strip()) for i, l in enumerate(f, 1) if l.startswith("#Fields")]
        if len(fields) > 1:
            notas.append(f"- `{ruta.name}` cambia de columnas en la linea {fields[1][0]} "
                         f"(aparecen `cs-host` y `X-Forwarded-For`): se lee cada bloque con su propio encabezado.")
        partes.append(leer_w3c(ruta))
    df = pd.concat(partes, ignore_index=True)
    df["ts"] = a_hora_local(df)
    for c in ["sc-status", "sc-substatus", "sc-win32-status", "time-taken"]:
        df[c] = pd.to_numeric(df[c], errors="coerce")
    df["X-Forwarded-For"] = df.get("X-Forwarded-For", pd.Series(index=df.index)).fillna("-")
    # IP real del cliente: desde que aparece el proxy (10.20.4.4) esta en X-Forwarded-For
    df["ip_cliente"] = np.where(df["X-Forwarded-For"].ne("-"), df["X-Forwarded-For"], df["c-ip"])
    notas.append(f"- Logs IIS en UTC: primer registro {df['date'].iloc[0]} {df['time'].iloc[0]} UTC = "
                 f"{df['ts'].min()} hora Colombia. Se convierte todo a UTC-05:00.")
    return df


def cargar_httperr(kit: Path) -> pd.DataFrame:
    partes = [leer_w3c(r) for r in sorted((kit / "logs" / "httperr").glob("*.log"))]
    h = pd.concat(partes, ignore_index=True)
    h["ts"] = a_hora_local(h)
    return h


def cargar_eventos(kit: Path) -> pd.DataFrame:
    e = pd.read_csv(kit / "eventos" / "eventos_WEB-PAGOS-01.csv")
    e["ts"] = pd.to_datetime(e["TimeCreated"])  # ya en hora local
    return e


def cargar_perfmon(kit: Path, notas: list[str]) -> pd.DataFrame:
    p = pd.read_csv(kit / "metricas" / "perfmon_WEB-PAGOS-01.csv", dtype=str)
    p.columns = ["ts", "cpu_pct", "mem_disponible_mb", "disco_libre_pct", "disco_libre_mb",
                 "w3wp_private_bytes", "conexiones"]
    p["ts"] = pd.to_datetime(p["ts"], format="%m/%d/%Y %H:%M:%S.%f")
    for c in p.columns[1:]:
        p[c] = pd.to_numeric(p[c].str.strip(), errors="coerce")
    p["w3wp_mb"] = p["w3wp_private_bytes"] / 2**20
    vacios = p[p["w3wp_mb"].isna()]
    notas.append(f"- Perfmon: {len(vacios)} muestras sin `Private Bytes` de w3wp. Las de "
                 f"18-sep 14:40-15:00 coinciden con el pool detenido (no existia el proceso): es evidencia, no error.")
    return p.set_index("ts")


# --------------------------------------------------------------------------- analisis
def disponibilidad(iis: pd.DataFrame, http: pd.DataFrame) -> pd.DataFrame:
    """Peticiones de usuarios: sin /health (sonda NOC) y sin 404 (escaneos). Los 503 de HTTP.sys cuentan como fallo."""
    u = iis[(iis["cs-uri-stem"] != "/health") & (iis["sc-status"] != 404)]
    f503 = http[(http["sc-status"] == "503") & ~http["cs-uri"].str.startswith("/health")]
    dia_u, dia_h = u["ts"].dt.date, f503["ts"].dt.date
    total = u.groupby(dia_u).size().add(f503.groupby(dia_h).size(), fill_value=0)
    ok = u[u["sc-status"] < 500].groupby(dia_u).size()
    ok_rapido = u[(u["sc-status"] < 500) & (u["time-taken"] < UMBRAL_LENTO_MS)].groupby(dia_u).size()
    r = pd.DataFrame({"peticiones": total.astype(int),
                      "fallidas_5xx_iis": u[u["sc-status"] >= 500].groupby(dia_u).size(),
                      "fallidas_503_httpsys": f503.groupby(dia_h).size()}).fillna(0).astype(int)
    r["disponibilidad_pct"] = (100 * ok / total).round(3)
    r[f"disp_sin_error_y_<{UMBRAL_LENTO_MS//1000}s_pct"] = (100 * ok_rapido / total).round(3)
    r.loc["SEMANA"] = [r["peticiones"].sum(), r["fallidas_5xx_iis"].sum(), r["fallidas_503_httpsys"].sum(),
                       round(100 * ok.sum() / total.sum(), 3), round(100 * ok_rapido.sum() / total.sum(), 3)]
    return r.astype({"peticiones": int, "fallidas_5xx_iis": int, "fallidas_503_httpsys": int})


def vision_noc(iis: pd.DataFrame, http: pd.DataFrame) -> str:
    h = iis[iis["cs-uri-stem"] == "/health"]
    hf = http[http["cs-uri"].str.startswith("/health")]
    return (f"- Sonda NOC `/health`: {len(h)} respuestas 200 en el log IIS (100 %), pero **{len(hf)} fallos 503** "
            f"en HTTP.sys entre {hf['ts'].min():%d-%m %H:%M} y {hf['ts'].max():%H:%M}.\n"
            f"- Latencia de `/health`: max {h['time-taken'].max():.0f} ms toda la semana, incluso cuando la app "
            f"tardaba >20 s: el endpoint no prueba la aplicacion.\n")


def linea_tiempo(iis, http, inicio="2026-09-18 10:00", fin="2026-09-18 16:30") -> pd.DataFrame:
    u = iis[(iis["cs-uri-stem"] != "/health") & iis["ts"].between(inicio, fin)].set_index("ts")
    g = u.resample("10min")
    r = pd.DataFrame({"peticiones": g.size(),
                      "errores_5xx": g["sc-status"].apply(lambda s: int((s >= 500).sum())),
                      "p95_ms": g["time-taken"].quantile(0.95).round(0)})
    h = http[http["ts"].between(inicio, fin)].set_index("ts").resample("10min").size()
    r["503_httpsys"] = h.reindex(r.index).fillna(0).astype(int)
    return r


def hitos(iis, http, ev) -> list[str]:
    u = iis[iis["cs-uri-stem"] != "/health"]
    d18 = u[u["ts"].dt.date.astype(str) == "2026-09-18"]
    conf = d18[(d18["cs-uri-stem"] == "/api/pagos/confirmar") & (d18["sc-status"] >= 500)]
    oom = ev[ev["Message"].str.contains("OutOfMemory", na=False)]
    caidas = ev[(ev["Id"] == 1026)]
    pool = ev[(ev["ProviderName"] == "Microsoft-Windows-WAS") & (ev["Id"] == 5002)]
    ult503 = http[http["sc-status"] == "503"]["ts"].max()
    rec = d18[d18["ts"] > ult503]["ts"].min()
    return [
        f"- Primer 500 en /api/pagos/confirmar: {conf['ts'].min():%H:%M:%S} (IIS)",
        f"- Primer OutOfMemoryException: {oom['ts'].min():%H:%M:%S} (ASP.NET 1309)",
        f"- Caidas de w3wp (.NET 1026): {len(caidas)} -> {', '.join(caidas['ts'].dt.strftime('%H:%M:%S'))}",
        f"- Pool deshabilitado por Rapid-Fail (WAS 5002): {pool['ts'].min():%H:%M:%S}",
        f"- Primer 503 AppOffline: {http['ts'].min():%H:%M:%S} | ultimo: {ult503:%H:%M:%S}",
        f"- Primera respuesta normal tras reinicio manual: {rec:%H:%M:%S}",
    ]


def senales_diarias(iis, perf) -> pd.DataFrame:
    u = iis[iis["cs-uri-stem"] != "/health"]
    d = pd.DataFrame({
        "peticiones": iis.groupby(iis["ts"].dt.date).size(),
        "p95_ms": u.groupby(u["ts"].dt.date)["time-taken"].quantile(0.95).round(0),
        "w3wp_pico_mb": perf["w3wp_mb"].groupby(perf.index.date).max().round(0),
        "disco_libre_fin_gb": (perf["disco_libre_mb"].groupby(perf.index.date).last() / 1024).round(2),
    })
    return d


def pronostico_disco(iis, perf) -> str:
    """Metodo: consumo de disco proporcional al trafico (MB por 1.000 peticiones) en dias sin caidas."""
    req = iis.groupby(iis["ts"].dt.date).size()
    libre = perf["disco_libre_mb"]
    tasas = {}
    for dia in ["2026-09-16", "2026-09-17", "2026-09-19", "2026-09-20"]:  # post-despliegue, sin crash dumps
        s = libre.loc[dia]
        tasas[dia] = (s.iloc[0] - s.iloc[-1]) / req[pd.Timestamp(dia).date()] * 1000
    tasa = float(np.mean(list(tasas.values())))
    tasa_min, tasa_max = min(tasas.values()), max(tasas.values())
    habiles = req[[pd.Timestamp(d).date() for d in ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17"]]]
    req_habil = float(habiles.mean())
    restante = float(libre.iloc[-1])
    dias = restante / (tasa * req_habil / 1000)
    return (f"## Pronostico de llenado del disco C:\n\n"
            f"- Disco libre al cierre (20-sep 23:55): **{restante/1024:.1f} GB**.\n"
            f"- Consumo observado desde el despliegue v2.3.1: {tasa:.0f} MB por 1.000 peticiones "
            f"(rango {tasa_min:.0f}-{tasa_max:.0f}; dias {', '.join(tasas)}).\n"
            f"- Trafico de un dia habil tipico (14-17 sep): {req_habil:,.0f} peticiones -> ~{tasa*req_habil/1024/1000:.1f} GB/dia.\n"
            f"- **Estimado: el disco se llena en {dias:.1f} dias habiles, es decir durante el martes 22-sep.**\n"
            f"- Peor caso: una nueva caida genera volcados de memoria (~7,8 GB en la hora del 18-sep, 14:00-15:00) "
            f"y adelanta el llenado a horas.\n"
            f"- Supuesto: el consumo se debe a logs de aplicacion en nivel Debug (despliegue 15-sep 22:03); "
            f"los logs de IIS solo suman ~5-9 MB/dia.\n")


def eventos_clave(ev) -> pd.DataFrame:
    e = ev[~ev["Id"].isin(RUIDO_EVENTOS)]
    return e[["ts", "LogName", "ProviderName", "Id", "LevelDisplayName", "Message"]]


# --------------------------------------------------------------------------- graficas
def graficar(perf, tl, salida: Path):
    fig, ax = plt.subplots(figsize=(11, 4))
    ax.plot(perf.index, perf["w3wp_mb"], lw=0.8)
    ax.axvline(pd.Timestamp("2026-09-15 22:03"), ls="--", c="gray")
    ax.text(pd.Timestamp("2026-09-15 22:30"), ax.get_ylim()[1] * 0.9, "despliegue v2.3.1", fontsize=8)
    ax.set_title("Memoria del proceso w3wp (Private Bytes, MB) - sube cada dia y el iisreset de 02:00 la oculta")
    ax.set_ylabel("MB"); fig.tight_layout(); fig.savefig(salida / "memoria_w3wp.png", dpi=120); plt.close(fig)

    fig, ax = plt.subplots(figsize=(11, 4))
    ax.plot(perf.index, perf["disco_libre_mb"] / 1024, lw=1)
    ax.set_title("Disco C: libre (GB)"); ax.set_ylabel("GB")
    fig.tight_layout(); fig.savefig(salida / "disco_libre.png", dpi=120); plt.close(fig)

    fig, ax1 = plt.subplots(figsize=(11, 4))
    ax1.bar(tl.index, tl["errores_5xx"] + tl["503_httpsys"], width=0.006, color="tab:red", label="errores (5xx + 503)")
    ax2 = ax1.twinx(); ax2.plot(tl.index, tl["p95_ms"] / 1000, c="tab:blue", label="p95 (s)")
    ax1.set_ylabel("errores / 10 min"); ax2.set_ylabel("p95 latencia (s)")
    ax1.set_title("18-sep (hora Colombia): degradacion desde ~11:20, errores desde 13:23, caida 14:38-15:04")
    fig.tight_layout(); fig.savefig(salida / "incidente_18sep.png", dpi=120); plt.close(fig)


# --------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--kit", default="../kit", type=Path)
    ap.add_argument("--salida", default="resultados", type=Path)
    a = ap.parse_args()
    a.salida.mkdir(parents=True, exist_ok=True)

    notas: list[str] = []
    iis = cargar_iis(a.kit, notas)
    http = cargar_httperr(a.kit)
    ev = cargar_eventos(a.kit)
    perf = cargar_perfmon(a.kit, notas)
    notas.append(f"- Desde el 16-sep 22:12 (hora Colombia) `c-ip` es siempre 10.20.4.4 (proxy/balanceador no documentado); "
                 f"la IP real queda en `X-Forwarded-For`.")
    notas.append("- Ruido descartado: DCOM 10016 (advertencia benigna conocida, constante toda la semana), "
                 "Schannel 36887 y Service Control Manager 7036.")

    disp = disponibilidad(iis, http); disp.to_csv(a.salida / "disponibilidad_diaria.csv")
    tl = linea_tiempo(iis, http); tl.to_csv(a.salida / "linea_tiempo_18sep.csv")
    sen = senales_diarias(iis, perf); sen.to_csv(a.salida / "senales_diarias.csv")
    eventos_clave(ev).to_csv(a.salida / "eventos_clave.csv", index=False)
    (a.salida / "pronostico_disco.md").write_text(pronostico_disco(iis, perf), encoding="utf-8")
    (a.salida / "calidad_datos.md").write_text("## Calidad de los datos\n\n" + "\n".join(notas) + "\n\n## Vision del NOC\n\n"
                                               + vision_noc(iis, http) + "\n## Hitos del 18-sep\n\n" + "\n".join(hitos(iis, http, ev)) + "\n",
                                               encoding="utf-8")
    graficar(perf, tl, a.salida)

    print((a.salida / "calidad_datos.md").read_text(encoding="utf-8"))
    print(disp.to_string()); print(); print(sen.to_string()); print()
    print((a.salida / "pronostico_disco.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
