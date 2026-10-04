## Calidad de los datos

- `u_ex260917.log` cambia de columnas en la linea 2351 (aparecen `cs-host` y `X-Forwarded-For`): se lee cada bloque con su propio encabezado.
- `u_ex260916 - copia.log` es identico (MD5 4806dded) a `u_ex260916.log`: **se excluye** para no contar doble.
- Logs IIS en UTC: primer registro 2026-09-14 05:00:01 UTC = 2026-09-14 00:00:01 hora Colombia. Se convierte todo a UTC-05:00.
- Perfmon: 13 muestras sin `Private Bytes` de w3wp. Las de 18-sep 14:40-15:00 coinciden con el pool detenido (no existia el proceso): es evidencia, no error.
- Desde el 16-sep 22:12 (hora Colombia) `c-ip` es siempre 10.20.4.4 (proxy/balanceador no documentado); la IP real queda en `X-Forwarded-For`.
- Ruido descartado: DCOM 10016 (advertencia benigna conocida, constante toda la semana), Schannel 36887 y Service Control Manager 7036.

## Vision del NOC

- Sonda NOC `/health`: 20101 respuestas 200 en el log IIS (100 %), pero **52 fallos 503** en HTTP.sys entre 18-09 14:38 y 15:03.
- Latencia de `/health`: max 4 ms toda la semana, incluso cuando la app tardaba >20 s: el endpoint no prueba la aplicacion.

## Hitos del 18-sep

- Primer 500 en /api/pagos/confirmar: 13:23:45 (IIS)
- Primer OutOfMemoryException: 13:24:19 (ASP.NET 1309)
- Caidas de w3wp (.NET 1026): 5 -> 14:22:12, 14:34:40, 14:35:55, 14:36:58, 14:38:03
- Pool deshabilitado por Rapid-Fail (WAS 5002): 14:38:05
- Primer 503 AppOffline: 14:38:00 | ultimo: 15:03:59
- Primera respuesta normal tras reinicio manual: 15:04:00
