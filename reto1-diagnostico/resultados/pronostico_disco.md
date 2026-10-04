## Pronostico de llenado del disco C:

- Disco libre al cierre (20-sep 23:55): **10.9 GB**.
- Consumo observado desde el despliegue v2.3.1: 242 MB por 1.000 peticiones (rango 206-267; dias 2026-09-16, 2026-09-17, 2026-09-19, 2026-09-20).
- Trafico de un dia habil tipico (14-17 sep): 26,418 peticiones -> ~6.3 GB/dia.
- **Estimado: el disco se llena en 1.7 dias habiles, es decir durante el martes 22-sep.**
- Peor caso: una nueva caida genera volcados de memoria (~7,8 GB en la hora del 18-sep, 14:00-15:00) y adelanta el llenado a horas.
- Supuesto: el consumo se debe a logs de aplicacion en nivel Debug (despliegue 15-sep 22:03); los logs de IIS solo suman ~5-9 MB/dia.
