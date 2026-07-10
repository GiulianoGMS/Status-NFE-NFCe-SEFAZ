# Status NFe/NFC-e SEFAZ — Sync para Oracle

Script PowerShell que consulta uma API de monitoramento do status dos webservices da SEFAZ e persiste os dados em uma tabela Oracle via `sqlplus`. Usado para alimentar um alerta automático no ERP Consinco.

---

## Como funciona

1. Consulta duas APIs (NFe e NFC-e) que retornam o status dos webservices por UF
2. Filtra apenas **SP e RJ** (configurável no array em `sync.ps1`)
3. Faz `MERGE` na tabela `ERP_INTEGRATION.NAGT_NFE_STATUS_UFS` via `sqlplus`
4. O ERP avalia um SELECT de alerta nessa tabela a cada ciclo e notifica quando há lentidão ou contingência ativa

---

## Pré-requisitos

- `sqlplus.exe` disponível no `PATH` do servidor
- Acesso ao banco Oracle (`ERP_INTEGRATION.NAGT_NFE_STATUS_UFS` já criada — ver `ddl.sql`)
- Acesso às APIs externas de monitoramento

---

## Instalação

```powershell
# 1. Criar a tabela no banco (executar uma vez)
#    Conecte no Oracle e rode o conteúdo de ddl.sql

# 2. Copiar e preencher o .env
copy .env.example .env
# editar .env com as credenciais e URLs corretas

# 3. Testar manualmente
powershell.exe -ExecutionPolicy Bypass -File ".\sync.ps1"
```

---

## Configuração (`.env`)

Copie `.env.example` para `.env` e preencha:

```
ORACLE_USER=USUARIO
ORACLE_PASSWORD=SENHA
ORACLE_CONNECT_STRING=HOST:PORTA/SERVICE_NAME

# Opcional — necessário apenas se ORACLE_CONNECT_STRING for um alias TNS
TNS_ADMIN=C:\caminho\para\network\admin

API_URL=http://...      # endpoint de status NFe
API_URL_NFCE=http://... # endpoint de status NFC-e
```

> O arquivo `.env` **não deve ser versionado** (já está no `.gitignore`).

---

## Agendamento (Task Scheduler)

Crie uma tarefa no Agendador de Tarefas do Windows com:

| Campo | Valor |
|-------|-------|
| Programa/script | `powershell.exe` |
| Argumentos | `-ExecutionPolicy Bypass -File "...\sync.ps1"` |
| Iniciar em | pasta raiz do projeto (onde está o `.env`) |

O campo **"Iniciar em"** é obrigatório — o script localiza o `.env` pelo diretório de trabalho.

---

## Estrutura

```
sync.ps1      ← script principal (produção)
sync.js       ← versão alternativa Node.js (sem filtro por UF, sem TIPO)
ddl.sql       ← DDL da tabela NAGT_NFE_STATUS_UFS
.env.example  ← template de configuração
.gitignore
package.json  ← dependências Node.js (oracledb, dotenv) — só para sync.js
```

---

## Alerta no ERP

SQL configurado em **Parâmetros > Alertas** do Consinco:

```sql
SELECT COUNT(1) A
  FROM ERP_INTEGRATION.NAGT_NFE_STATUS_UFS X
 WHERE (
          TIPO = 'NFE'
      AND TEMPO_RESPOSTA > 5
      AND ATUALIZADO_EM >= SYSDATE - (25/1440)
       )
    OR SVC = 'Sim'
HAVING COUNT(1) > 0
```

Dispara quando:
- Tempo de resposta NFe > 5 minutos (e sync rodou nos últimos 25 min)
- Qualquer UF em contingência (`SVC = 'Sim'`)
