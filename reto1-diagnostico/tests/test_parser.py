"""Pruebas de las dos trampas del parser: cambio de #Fields y conversion UTC -> Colombia."""
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from analizar import leer_w3c, a_hora_local  # noqa: E402


def test_cambio_de_fields_a_mitad_de_archivo(tmp_path: Path):
    log = tmp_path / "u_ex.log"
    log.write_text(
        "#Fields: date time cs-uri-stem sc-status\n"
        "2026-09-17 03:00:00 /a 200\n"
        "#Fields: date time cs-uri-stem cs-host sc-status X-Forwarded-For\n"
        "2026-09-17 03:15:00 /b pagos.example 500 1.2.3.4\n", encoding="utf-8")
    df = leer_w3c(log)
    assert len(df) == 2
    assert df.loc[1, "sc-status"] == "500"
    assert df.loc[1, "X-Forwarded-For"] == "1.2.3.4"


def test_utc_a_hora_colombia(tmp_path: Path):
    log = tmp_path / "u_ex.log"
    log.write_text("#Fields: date time\n2026-09-18 19:38:00\n", encoding="utf-8")
    ts = a_hora_local(leer_w3c(log))
    assert str(ts.iloc[0]) == "2026-09-18 14:38:00"
