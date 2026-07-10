require("dotenv").config();
const oracledb = require("oracledb");

const API_URL = process.env.API_URL;

const MERGE_SQL = `
  MERGE INTO NAGT_NFE_STATUS_UFS tgt
  USING (
    SELECT
      :id AS ID, :sigla AS SIGLA, :nome_estado AS NOME_ESTADO,
      :bg AS BG, :color AS COLOR, :tempo_resposta AS TEMPO_RESPOSTA,
      :svc AS SVC, :normal AS NORMAL
    FROM dual
  ) src
  ON (tgt.ID = src.ID)
  WHEN MATCHED THEN UPDATE SET
    tgt.SIGLA = src.SIGLA,
    tgt.NOME_ESTADO = src.NOME_ESTADO,
    tgt.BG = src.BG,
    tgt.COLOR = src.COLOR,
    tgt.TEMPO_RESPOSTA = src.TEMPO_RESPOSTA,
    tgt.SVC = src.SVC,
    tgt.NORMAL = src.NORMAL,
    tgt.ATUALIZADO_EM = SYSTIMESTAMP
  WHEN NOT MATCHED THEN INSERT (ID, SIGLA, NOME_ESTADO, BG, COLOR, TEMPO_RESPOSTA, SVC, NORMAL, ATUALIZADO_EM)
  VALUES (src.ID, src.SIGLA, src.NOME_ESTADO, src.BG, src.COLOR, src.TEMPO_RESPOSTA, src.SVC, src.NORMAL, SYSTIMESTAMP)
`;

async function fetchStatus() {
  const res = await fetch(API_URL);
  if (!res.ok) {
    throw new Error(`API respondeu ${res.status} ${res.statusText}`);
  }
  const data = await res.json();
  // API retorna um objeto { "SP": {...}, "RJ": {...}, ... }, não um array
  const rows = Array.isArray(data) ? data : Object.values(data);
  if (!Array.isArray(rows) || rows.length === 0) {
    throw new Error("Resposta da API vazia ou em formato inesperado");
  }
  return rows;
}

async function syncToOracle(rows) {
  const binds = rows.map((r) => ({
    id: r.id,
    sigla: r.sigla,
    nome_estado: r.nome_estado,
    bg: r.bg,
    color: r.color,
    tempo_resposta: r.tempo_resposta,
    svc: r.svc,
    normal: r.normal,
  }));

  const connectionConfig = {
    user: process.env.ORACLE_USER,
    password: process.env.ORACLE_PASSWORD,
    connectString: process.env.ORACLE_CONNECT_STRING,
  };
  // Só necessário se ORACLE_CONNECT_STRING for um alias TNS (não um Easy Connect host:porta/service)
  if (process.env.TNS_ADMIN) {
    connectionConfig.configDir = process.env.TNS_ADMIN;
  }

  const connection = await oracledb.getConnection(connectionConfig);

  try {
    const result = await connection.executeMany(MERGE_SQL, binds, {
      autoCommit: true,
    });
    return result.rowsAffected ?? binds.length;
  } finally {
    await connection.close();
  }
}

async function main() {
  const startedAt = new Date().toISOString();
  try {
    const rows = await fetchStatus();
    const affected = await syncToOracle(rows);
    console.log(`[${startedAt}] OK - ${affected} linha(s) sincronizada(s)`);
  } catch (err) {
    console.error(`[${startedAt}] FALHA -`, err.message);
    process.exitCode = 1;
  }
}

main();
