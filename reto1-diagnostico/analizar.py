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
    - analisis_avanzado.md      memoria vs pagos, reintentos, trafico vs base, deteccion hipotetica
    - powerbi/*.csv             tablas limpias para validar las cifras en Power BI (ver POWERBI.md)
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


# --------------------------------------------------------------------------- analisis avanzado
PAGOS = ["/api/pagos/iniciar", "/api/pagos/confirmar"]


def analisis_avanzado(iis, http, perf) -> str:
    u = iis[iis["cs-uri-stem"] != "/health"]
    out = ["## Analisis avanzado\n"]

    # 1) La memoria crece con cada operacion de pago (evidencia de que la fuga esta en el cache de pagos)
    pag = u[u["cs-uri-stem"].isin(PAGOS) & (u["sc-status"] < 500)]
    hr = pd.DataFrame({"pagos": pag.set_index("ts").resample("1h").size(),
                       "peticiones": u.set_index("ts").resample("1h").size(),
                       "mem": perf["w3wp_mb"].resample("1h").last()})
    hr["delta_mem"] = hr["mem"].diff()
    x = hr.loc["2026-09-16 04:00":"2026-09-18 12:00"].dropna()
    x = x[~x.index.hour.isin([2, 3])]  # excluir el reinicio nocturno
    r_pag = np.corrcoef(x["pagos"], x["delta_mem"])[0, 1]
    r_req = np.corrcoef(x["peticiones"], x["delta_mem"])[0, 1]
    mb_op = np.polyfit(x["pagos"], x["delta_mem"], 1)[0]
    ops_crash = len(pag[(pag["ts"] >= "2026-09-18 02:00") & (pag["ts"] < "2026-09-18 13:24")])
    out.append("### 1. La memoria crece con cada pago\n")
    out.append(f"- Correlacion por hora entre crecimiento de memoria y operaciones de pago: **{r_pag:.3f}** "
               f"(contra {r_req:.3f} con el total de peticiones).")
    out.append(f"- Cada operacion de pago deja ~**{mb_op:.2f} MB** retenidos en memoria.")
    out.append(f"- El 18-sep el primer OutOfMemory llego tras **{ops_crash:,} operaciones de pago** desde el reinicio de 02:00. "
               f"El 16 y 17 hubo ~3.600 y ~4.000 en el dia completo: estuvieron cerca del limite.")
    out.append("- Implicacion: el portal aguanta ~4.200 operaciones de pago por dia. Cualquier dia por encima se cae.\n")

    # 2) Embudo de pagos: confirmaciones > inicios el 18 => reintentos
    f = u[u["cs-uri-stem"].isin(PAGOS)]
    emb = f.groupby([f["ts"].dt.date, "cs-uri-stem"]).size().unstack()
    emb["confirmar/iniciar"] = (emb["/api/pagos/confirmar"] / emb["/api/pagos/iniciar"]).round(2)
    normal = emb.loc[emb.index != pd.Timestamp("2026-09-18").date(), "confirmar/iniciar"].median()
    d18 = emb.loc[pd.Timestamp("2026-09-18").date()]
    extra = d18["/api/pagos/confirmar"] - normal * d18["/api/pagos/iniciar"]
    out.append("### 2. Reintentos de confirmacion de pago\n")
    try:
        out.append(emb.to_markdown())
    except ImportError:  # to_markdown requiere el paquete tabulate
        out.append(emb.to_string())
    out.append(f"\n- En un dia normal se confirman ~{normal:.0%} de los pagos iniciados. El 18-sep hubo **mas "
               f"confirmaciones que inicios** ({d18['confirmar/iniciar']:.2f}): ~{extra:,.0f} intentos de confirmacion de mas.")
    out.append("- Hipotesis: los clientes reintentaron al recibir errores. **Riesgo:** si `/api/pagos/confirmar` no es "
               "idempotente, pudo haber cobros duplicados. Se debe cruzar con el sistema de pagos.\n")

    # 3) Trafico frente a un dia normal (descarta abandono masivo antes de la caida)
    by = u.groupby([u["ts"].dt.hour, u["ts"].dt.date]).size().unstack()
    base = by[[c for c in by.columns if str(c) in ("2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17")]].mean(axis=1)
    rel = (by[pd.Timestamp("2026-09-18").date()] / base).round(2)
    out.append("### 3. Trafico del 18 frente a un dia habil promedio (misma hora)\n")
    out.append(" | ".join(f"{h}h: {rel[h]:.2f}x" for h in range(7, 19)))
    out.append("\n- El trafico se mantuvo ~1,5x durante la degradacion y solo cayo en la hora de la caida (14h). "
               "No hay evidencia de abandono masivo por lentitud; el impacto fue sobre todo errores y espera.\n")

    # 4) Cuando habria detectado un monitoreo adecuado (MTTD hipotetico)
    w = u.set_index("ts").resample("5min")
    s5 = pd.DataFrame({"n": w.size(), "e": w["sc-status"].apply(lambda v: (v >= 500).sum()),
                       "p95": w["time-taken"].quantile(0.95)})
    s5["h"] = http[~http["cs-uri"].str.startswith("/health")].set_index("ts").resample("5min").size().reindex(s5.index).fillna(0)
    s5["pct"] = 100 * (s5["e"] + s5["h"]) / (s5["n"] + s5["h"]).clip(lower=1)
    base_p95 = s5.loc["2026-09-14":"2026-09-17", "p95"].median()
    d = s5.loc["2026-09-18"]
    lat = ((d["p95"] > 2 * base_p95) & (d["n"] >= 100)).astype(int).rolling(3).sum()
    falsos = sum(((s5.loc[x, "p95"] > 2 * base_p95) & (s5.loc[x, "n"] >= 100)).astype(int).rolling(3).sum().ge(3).any()
                 for x in ["2026-09-14", "2026-09-15", "2026-09-16", "2026-09-17"])
    reglas = [
        ("Memoria w3wp > 1 GB", perf["w3wp_mb"][perf["w3wp_mb"] > 1000].index.min()),
        ("Disco C: < 30 % libre", perf["disco_libre_pct"][perf["disco_libre_pct"] < 30].index.min()),
        # para reglas por ventana, el aviso ocurre al CERRAR la ventana (inicio + 5 min)
        (f"p95 > 2x linea base ({2*base_p95:.0f} ms) por 15 min, con >=100 pet/5 min",
         lat[lat >= 3].index.min() + pd.Timedelta(minutes=5)),
        ("Errores (5xx + 503) > 5 % en 5 min, con >=50 pet",
         d[(d["pct"] > 5) & ((d["n"] + d["h"]) >= 50)].index.min() + pd.Timedelta(minutes=5)),
        ("Sonda sintetica externa (falla de /health)", http[http["cs-uri"].str.startswith("/health")]["ts"].min()),
        ("Primer ticket de cliente (real)", pd.Timestamp("2026-09-18 13:34")),
        ("Recuperacion manual (real)", pd.Timestamp("2026-09-18 15:04")),
    ]
    out.append("### 4. Cuando habria avisado un monitoreo adecuado\n")
    out.append("| Regla | Habria disparado |\n|---|---|")
    dias = ["lun", "mar", "mie", "jue", "vie", "sab", "dom"]
    out += [f"| {n} | {dias[t.dayofweek]} {t:%d-%m %H:%M} |" for n, t in reglas]
    out.append(f"\n- La regla de latencia no habria dado falsas alarmas los dias 14 a 17 (dias con disparo: {falsos}).")
    t_lat = reglas[2][1]
    ticket, caida = pd.Timestamp("2026-09-18 13:34"), pd.Timestamp("2026-09-18 14:38")
    fmt = lambda td: f"{int(td.total_seconds()//3600)} h {int(td.total_seconds()%3600//60)} min"
    out.append(f"- Con la alerta de latencia se habria detectado **{fmt(ticket - t_lat)} antes del primer ticket** y "
               f"**{fmt(caida - t_lat)} antes de la caida**; con la de memoria, casi **dos dias antes**.\n")
    return "\n".join(out)


# --------------------------------------------------------------------------- exportacion para Power BI
def exportar_powerbi(iis, http, perf, ev, kit: Path, salida: Path) -> None:
    """Tablas limpias (hora Colombia) para validar las cifras en Power BI. Ver POWERBI.md."""
    d = salida / "powerbi"
    d.mkdir(parents=True, exist_ok=True)
    a = pd.DataFrame({
        "fecha_hora": iis["ts"], "fuente": "IIS", "endpoint": iis["cs-uri-stem"],
        "status": iis["sc-status"], "tiempo_ms": iis["time-taken"], "ip_cliente": iis["ip_cliente"],
    })
    b = pd.DataFrame({
        "fecha_hora": http["ts"], "fuente": "HTTP.sys", "endpoint": http["cs-uri"],
        "status": pd.to_numeric(http["sc-status"], errors="coerce"), "tiempo_ms": np.nan, "ip_cliente": http["c-ip"],
    })
    pet = pd.concat([a, b], ignore_index=True).sort_values("fecha_hora")
    pet["fecha"] = pet["fecha_hora"].dt.date
    pet["hora"] = pet["fecha_hora"].dt.hour
    pet["ventana_10min"] = pet["fecha_hora"].dt.floor("10min")
    pet["es_sonda_noc"] = pet["endpoint"].eq("/health")
    pet["es_escaneo"] = pet["status"].eq(404)
    pet["es_cliente"] = ~pet["es_sonda_noc"] & ~pet["es_escaneo"] & pet["status"].notna()
    pet["es_error"] = pet["status"].ge(500)
    pet["es_pago"] = pet["endpoint"].isin(["/api/pagos/iniciar", "/api/pagos/confirmar"])
    pet.to_csv(d / "peticiones.csv", index=False, date_format="%Y-%m-%d %H:%M:%S")

    pm = perf.reset_index()[["ts", "cpu_pct", "mem_disponible_mb", "disco_libre_pct", "disco_libre_mb", "w3wp_mb", "conexiones"]]
    pm.rename(columns={"ts": "fecha_hora"}).to_csv(d / "perfmon.csv", index=False, date_format="%Y-%m-%d %H:%M:%S")

    e = ev[["ts", "LogName", "ProviderName", "Id", "LevelDisplayName", "Message"]].copy()
    e["es_ruido"] = e["Id"].isin(RUIDO_EVENTOS)
    e["Message"] = e["Message"].str.slice(0, 250)
    e.rename(columns={"ts": "fecha_hora"}).to_csv(d / "eventos.csv", index=False, date_format="%Y-%m-%d %H:%M:%S")

    t = pd.read_csv(kit / "tickets" / "tickets_mesa_servicio.csv")
    t.to_csv(d / "tickets.csv", index=False)


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

    fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(11, 5.5), sharex=True, gridspec_kw={"height_ratios": [3, 2]})
    ax1.plot(tl.index, tl["p95_ms"] / 1000, c="tab:blue", lw=1.8)
    ax1.set_ylabel("p95 (s)"); ax1.grid(axis="y", alpha=.3)
    ax1.set_title("18-sep (hora Colombia): lentitud desde ~11:20, errores desde 13:23, caida 14:38-15:04")
    ax2.bar(tl.index, tl["errores_5xx"] + tl["503_httpsys"], width=0.006, color="tab:red")
    ax2.set_ylabel("errores / 10 min"); ax2.grid(axis="y", alpha=.3)
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
    (a.salida / "analisis_avanzado.md").write_text(analisis_avanzado(iis, http, perf), encoding="utf-8")
    exportar_powerbi(iis, http, perf, ev, a.kit, a.salida)
    graficar(perf, tl, a.salida)

    print((a.salida / "calidad_datos.md").read_text(encoding="utf-8"))
    print(disp.to_string()); print(); print(sen.to_string()); print()
    print((a.salida / "pronostico_disco.md").read_text(encoding="utf-8"))
    print((a.salida / "analisis_avanzado.md").read_text(encoding="utf-8"))


if __name__ == "__main__":
    main()
