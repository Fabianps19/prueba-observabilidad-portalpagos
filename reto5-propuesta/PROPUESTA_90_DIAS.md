# Mis primeros 90 días: de enterarnos por los clientes a enterarnos primero

**Fabián Pinzón** · Especialista en Observabilidad y Automatización

Punto de partida, medido con los datos de la semana del 14 al 20 de septiembre: la degradación del 18-sep tardó **2 h 14 min** en detectarse, y la detectó un cliente; **0 %** de los incidentes se detectan antes que el usuario, y el NOC reportó 100 % de disponibilidad cuando la real fue 98,6 %.

**Mi enfoque.** Mi formación y experiencia en innovación me han enseñado a empezar por los problemas y necesidades del core del negocio, no por la tecnología. En Skandia eso significa priorizar lo que afecta directamente a los clientes y a los servicios que generan valor, como la continuidad de los canales transaccionales, y medir cada iniciativa por ese impacto. Quiero liderar proyectos que apliquen a esas necesidades de punta a punta y, antes de abrir frentes nuevos, **inventariar y llevar a término los proyectos que ya estén en curso**.

**Semana 1, antes de cualquier iniciativa: contener lo urgente con los dueños de cada tema.** Liberar disco preservando los volcados de memoria, coordinar con desarrollo la corrección o el rollback de la v2.3.1, rotar la contraseña expuesta en el script y verificar posibles cobros duplicados del 18-sep.

## Iniciativas, priorizadas

| # | Iniciativa | Impacto | Esfuerzo | Riesgo | Cuándo |
|---|---|---|---|---|---|
| 1 | **Ver el servicio como lo ve el cliente:** prueba sintética externa, health check transaccional y alertas de latencia y errores (validadas con datos: habrían avisado 1 h 34 min antes del primer ticket) | Alto | Bajo | Bajo | Días 1–30 |
| 2 | **Telemetría centralizada y un tablero para dos públicos:** logs IIS, HTTP.sys, eventos y métricas en Log Analytics; SLO acordado con negocio; tablero Dirección/NOC | Alto | Medio | Bajo | Días 15–45 |
| 3 | **Mantenimiento seguro e inventario de scripts heredados:** reemplazar el `.BAT` (Reto 2) e inventariar scripts con credenciales o "éxito" fijo | Medio | Bajo | Medio | Días 20–60 |
| 4 | **Auto-remediación con frenos:** 30 días en modo *sugerir*; luego automática solo para el pool detenido, con límite de intentos | Medio | Medio | Medio | Días 45–90 |
| 5 | **Triage asistido por IA:** piloto en el NOC; sugiere desde un catálogo cerrado y una persona decide | Medio | Bajo | Bajo | Días 60–90 |

El orden sigue una lógica simple: primero **ver**, luego **entender**, después **limpiar** lo que hace daño y por último **automatizar** la respuesta.

## Cómo mediría el éxito (a los 90 días)

| Indicador | Hoy | Meta a 90 días |
|---|---|---|
| Incidentes detectados antes que el usuario | 0 % | ≥ 80 % |
| MTTD de degradaciones | 2 h 14 min | < 15 min |
| MTTR de caída del pool | 26 min | < 10 min |
| Despliegues con revisión a las 24 h | 0 % | 100 % |
| Scripts con credenciales en texto plano o "éxito" fijo | Al menos 1 conocido | 0 en los servidores del portal |
| Horas manuales eliminadas | — | Revisión semanal del NOC y reinicios manuales: estimar la línea base en el mes 1 y reportar el ahorro |

Cada meta se mide con las mismas consultas del Reto 3, para que el resultado no dependa de mi opinión.

## Lo que necesito que mi líder me destrabe

La lista de proyectos de automatización y observabilidad en curso, para priorizarlos y cerrarlos · acceso de lectura a producción y un ambiente de pruebas · espacio en el comité de cambios y un contacto en desarrollo · una gMSA para el mantenimiento y el canal de Teams del NOC · presupuesto de ingesta (~USD 10–30/mes por servidor) y el SLO acordado con negocio.

## Lo que NO haría

- **Reinicios automáticos sin modo sugerir:** sobre una fuga solo la esconden, como el script de 2019.
- **IA que ejecute acciones:** sugiere desde un catálogo cerrado; decide una persona.
- **Comprar herramientas antes de la línea base:** primero medir con lo que ya hay en Azure.
- **Dejar proyectos a medias por abrir otros nuevos:** primero se cierra lo que está en curso o se decide explícitamente detenerlo.
- **Tocar el código de la aplicación:** la fuga la corrige desarrollo; yo aseguro que se detecte a tiempo.
- **Reemplazar de golpe lo del NOC:** las alertas nuevas conviven hasta demostrar que no hacen ruido.
