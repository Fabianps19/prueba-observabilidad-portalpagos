"""Genera el Azure Workbook de PortalPagos (dos publicos: Direccion y NOC). Uso: python3 workbook.py <LAW_ID>"""
import json, sys

def md(texto, nombre):
    return {"type": 1, "content": {"json": texto}, "name": nombre}

def kql(nombre, titulo, consulta, vis, rango_ms=14400000, ancho="50"):
    return {"type": 3, "name": nombre, "customWidth": ancho, "content": {
        "version": "KqlItem/1.0", "query": consulta, "size": 0, "title": titulo,
        "timeContext": {"durationMs": rango_ms}, "queryType": 0,
        "resourceType": "microsoft.operationalinsights/workspaces", "visualization": vis}}

def grupo(nombre, titulo, items):
    return {"type": 12, "name": nombre, "content": {"version": "NotebookGroup/1.0", "groupType": "editable",
            "title": titulo, "items": items}}

P = 'AppServiceHTTPLogs | where CsUriStem has "pagos"'
direccion = grupo("direccion", "Para la Direccion: el servicio visto como lo vive el cliente", [
    md("**Objetivo de disponibilidad: 99,5 %.** Disponibilidad = pagos atendidos sin error / pagos intentados. "
       "No mide si el servidor responde (eso decia 100 % el 18-sep), mide si los clientes pueden pagar.", "explica"),
    kql("kpi", "Resumen de las ultimas 24 h",
        P + ' | summarize Pagos=count(), Fallidos=countif(ScStatus >= 500)'
        ' | extend ["Disponibilidad %"]=round(100.0*(Pagos-Fallidos)/Pagos, 2), ["Objetivo %"]=99.5', "table", 86400000, "100"),
    kql("disp", "Disponibilidad cada 15 minutos (%)",
        P + ' | summarize disponibilidad=round(100.0*countif(ScStatus < 500)/count(), 2) by bin(TimeGenerated, 15m)', "timechart", 86400000),
    kql("remed", "Remediaciones automaticas (decision del runbook)",
        'AzureDiagnostics | where Category == "JobStreams" and ResultDescription has "REMEDIACION"'
        ' | extend d=parse_json(substring(ResultDescription, indexof(ResultDescription, "{")))'
        ' | summarize veces=count() by decision=tostring(d.decision)', "barchart", 86400000),
])
noc = grupo("noc", "Para el NOC: senales en vivo y que hizo la automatizacion", [
    kql("e5xx", "Respuestas 5xx por minuto", P + ' | summarize errores_5xx=countif(ScStatus >= 500) by bin(TimeGenerated, 1m)', "timechart"),
    kql("p95", "Latencia p95 (ms) cada 5 min", P + ' | summarize p95_ms=percentile(TimeTaken, 95) by bin(TimeGenerated, 5m)', "timechart"),
    kql("mem", "Memoria del proceso (MB): senal temprana de la fuga",
        'AzureMetrics | where MetricName == "MemoryWorkingSet" | summarize MB=max(Maximum)/1048576 by bin(TimeGenerated, 1m)', "timechart"),
    kql("endp", "Endpoints con errores", P + ' | where ScStatus >= 500 | summarize errores=count() by CsUriStem, ScStatus | order by errores desc', "table"),
    kql("log", "Bitacora de la auto-remediacion",
        'AzureDiagnostics | where Category == "JobStreams" and ResultDescription has "REMEDIACION"'
        ' | extend d=parse_json(substring(ResultDescription, indexof(ResultDescription, "{")))'
        ' | project hora_utc=todatetime(d.ts), decision=tostring(d.decision), detalle=tostring(d.detalle) | order by hora_utc desc', "table", 14400000, "100"),
])
wb = {"version": "Notebook/1.0", "items": [
    md("# PortalPagos (laboratorio) - Observabilidad\nHoras en UTC (Bogota = UTC-5). Fuente: Log Analytics.", "titulo"),
    direccion, noc], "fallbackResourceIds": [sys.argv[1]]}
print(json.dumps(wb, ensure_ascii=True))
