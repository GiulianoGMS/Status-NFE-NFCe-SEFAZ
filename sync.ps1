$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$envPath = Join-Path $scriptDir ".env"

function Get-EnvConfig {
    param([string]$Path)

    if (-not (Test-Path $Path)) {
        throw "Arquivo .env não encontrado em $Path"
    }

    $config = @{}
    Get-Content $Path | ForEach-Object {
        $line = $_.Trim()
        if ($line -eq "" -or $line.StartsWith("#")) { return }
        if ($line -match '^([^=]+)=(.*)$') {
            $key = $Matches[1].Trim()
            $value = $Matches[2].Trim().Trim('"')
            $config[$key] = $value
        }
    }
    return $config
}

function Escape-Sql {
    param([string]$Value)
    if ($null -eq $Value) { return "" }
    return $Value.Replace("'", "''")
}

function Remove-Diacritics {
    param([string]$Text)
    if ($null -eq $Text) { return $Text }
    $normalized = $Text.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $normalized.ToCharArray()) {
        $category = [System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($ch)
        if ($category -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($ch)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function Get-ApiRows {
    param([string]$Url, [string]$Tipo)

    $webClient = New-Object System.Net.WebClient
    $webClient.Encoding = [System.Text.Encoding]::UTF8
    $jsonText = $webClient.DownloadString($Url)
    $response = $jsonText | ConvertFrom-Json

    # API retorna um objeto { "SP": {...}, "RJ": {...}, ... }, não um array
    $rows = if ($response -is [System.Array]) { $response } else { $response.PSObject.Properties.Value }

    if (-not $rows -or $rows.Count -eq 0) {
        throw "Resposta da API ($Tipo) vazia ou em formato inesperado"
    }

    $rows = $rows | Where-Object { $_.sigla -in @("SP", "RJ") }
    foreach ($r in $rows) {
        $r | Add-Member -NotePropertyName tipo -NotePropertyValue $Tipo
    }
    return $rows
}

$config = Get-EnvConfig -Path $envPath
$startedAt = Get-Date -Format "yyyy-MM-ddTHH:mm:ss"

try {
    $rows = @()
    $rows += Get-ApiRows -Url $config.API_URL -Tipo "NFE"
    $rows += Get-ApiRows -Url $config.API_URL_NFCE -Tipo "NFCE"

    if (-not $rows -or $rows.Count -eq 0) {
        throw "Nenhuma linha de SP/RJ encontrada nas respostas das APIs"
    }

    $sqlLines = New-Object System.Collections.Generic.List[string]
    $sqlLines.Add("WHENEVER SQLERROR EXIT SQL.SQLCODE")
    $sqlLines.Add("SET DEFINE OFF")
    $sqlLines.Add("SET FEEDBACK OFF")
    $sqlLines.Add("CONNECT $($config.ORACLE_USER)/$($config.ORACLE_PASSWORD)@$($config.ORACLE_CONNECT_STRING)")

    foreach ($r in $rows) {
        $merge = @"
MERGE INTO NAGT_NFE_STATUS_UFS tgt
USING (
  SELECT '$(Escape-Sql $r.tipo)' AS TIPO, $([int]$r.id) AS ID, '$(Escape-Sql $r.sigla)' AS SIGLA, '$(Escape-Sql (Remove-Diacritics $r.nome_estado))' AS NOME_ESTADO,
         $([int]$r.tempo_resposta) AS TEMPO_RESPOSTA, '$(Escape-Sql (Remove-Diacritics $r.svc))' AS SVC, $([int]$r.normal) AS NORMAL
  FROM dual
) src
ON (tgt.ID = src.ID AND tgt.TIPO = src.TIPO)
WHEN MATCHED THEN UPDATE SET
  tgt.SIGLA = src.SIGLA, tgt.NOME_ESTADO = src.NOME_ESTADO,
  tgt.TEMPO_RESPOSTA = src.TEMPO_RESPOSTA, tgt.SVC = src.SVC, tgt.NORMAL = src.NORMAL, tgt.ATUALIZADO_EM = SYSDATE
WHEN NOT MATCHED THEN INSERT (TIPO, ID, SIGLA, NOME_ESTADO, TEMPO_RESPOSTA, SVC, NORMAL, ATUALIZADO_EM)
VALUES (src.TIPO, src.ID, src.SIGLA, src.NOME_ESTADO, src.TEMPO_RESPOSTA, src.SVC, src.NORMAL, SYSDATE);
"@
        $sqlLines.Add($merge)
    }

    $sqlLines.Add("COMMIT;")
    $sqlLines.Add("EXIT;")

    $tempSql = Join-Path $env:TEMP "nfe_sync_$([guid]::NewGuid().ToString('N')).sql"
    [System.IO.File]::WriteAllLines($tempSql, $sqlLines, (New-Object System.Text.UTF8Encoding($false)))

    $output = & sqlplus.exe "-S" "/nolog" "@$tempSql" 2>&1
    $exitCode = $LASTEXITCODE

    Remove-Item $tempSql -Force -ErrorAction SilentlyContinue

    $outputText = $output -join "`n"
    if ($exitCode -ne 0 -or $outputText -match "ORA-\d{5}") {
        throw "sqlplus retornou erro:`n$outputText"
    }

    Write-Output "[$startedAt] OK - $($rows.Count) linha(s) sincronizada(s)"
}
catch {
    Write-Error "[$startedAt] FALHA - $($_.Exception.Message)"
    exit 1
}
