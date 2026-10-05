<%@ Page Language="C#" %>
<%@ Import Namespace="System.Collections.Generic" %>
<script runat="server">
// Simulacion de PortalPagos v2.3.1 (ficticio). SesionPagoCache nunca libera sesiones:
// cada operacion retiene FUGA_KB de memoria (0 = version sana, 256 = ~0.25 MB/op como en el incidente).
static readonly List<byte[]> SesionPagoCache = new List<byte[]>();
static readonly object Candado = new object();

static int Ajuste(string nombre, int defecto)
{
    int v;
    return int.TryParse(System.Configuration.ConfigurationManager.AppSettings[nombre], out v) ? v : defecto;
}

protected void Page_Load(object sender, EventArgs e)
{
    string op = Request.QueryString["op"] ?? "iniciar";
    int fugaKb = Ajuste("FUGA_KB", 0);
    int limiteMb = Ajuste("LIMITE_MB", 600);
    long mb;
    lock (Candado)
    {
        if (fugaKb > 0) SesionPagoCache.Add(new byte[fugaKb * 1024]);
        mb = GC.GetTotalMemory(false) / 1048576;
    }
    if (mb > limiteMb)
        throw new OutOfMemoryException("SesionPagoCache.Agregar: memoria " + mb + " MB supera " + limiteMb + " MB");
    Response.ContentType = "application/json";
    Response.Write("{\"op\":\"" + HttpUtility.JavaScriptStringEncode(op) + "\",\"estado\":\"ok\",\"memoria_mb\":" + mb + ",\"sesiones\":" + SesionPagoCache.Count + "}");
}
</script>
