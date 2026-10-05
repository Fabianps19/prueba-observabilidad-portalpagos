<%@ Page Language="C#" %>
<script runat="server">
// Health check: 503 si la memoria administrada supera LIMITE_MB (el portal ya no puede atender pagos).
protected void Page_Load(object sender, EventArgs e)
{
    int limiteMb;
    if (!int.TryParse(System.Configuration.ConfigurationManager.AppSettings["LIMITE_MB"], out limiteMb)) limiteMb = 600;
    long mb = GC.GetTotalMemory(false) / 1048576;
    Response.ContentType = "text/plain";
    if (mb > limiteMb) { Response.StatusCode = 503; Response.Write("degradado memoria_mb=" + mb); }
    else Response.Write("ok memoria_mb=" + mb);
}
</script>
