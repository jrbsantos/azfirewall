#!/usr/bin/env bash
#
# criar_regras_firewall.sh
#
# Lê um arquivo CSV e cria regras no Azure Firewall usando o Azure CLI.
# Suporta os três tipos de regra do Azure Firewall "clássico", selecionado
# pela opção -t (cada tipo tem seu PRÓPRIO formato de CSV, com só as
# colunas que fazem sentido para ele — veja "FORMATO DO CSV" abaixo):
#
#   -t network      -> az network firewall network-rule create
#   -t nat          -> az network firewall nat-rule create      (DNAT)
#   -t application  -> az network firewall application-rule create
#
# Referências oficiais consultadas (Microsoft Learn):
#   - Tutorial: https://learn.microsoft.com/azure/firewall/deploy-cli
#   - Network rule: https://learn.microsoft.com/cli/azure/network/firewall/network-rule
#   - NAT rule: https://learn.microsoft.com/cli/azure/network/firewall/nat-rule
#   - Application rule: https://learn.microsoft.com/cli/azure/network/firewall/application-rule
#
# ---------------------------------------------------------------------------
# POR QUE UM CSV DIFERENTE POR TIPO DE REGRA?
#
#   As três regras têm campos bem diferentes entre si (ex.: só NAT tem
#   translated_address/translated_port; só Application tem target_fqdns).
#   Um CSV único com todas as colunas de todos os tipos obrigaria a deixar
#   várias células em branco em toda linha, o que é fácil de errar ao
#   preencher manualmente (contar vírgulas, lembrar quais colunas ignorar
#   para cada tipo). Por isso cada rule_type tem seu próprio formato de CSV,
#   enxuto, só com os campos que ele realmente usa — e uma única execução
#   do script sempre lida com um tipo por vez (indicado em -t).
#
# ---------------------------------------------------------------------------
# IDEMPOTÊNCIA (importante):
#
#   Antes de criar qualquer regra, o script consulta as rule collections do
#   tipo selecionado (-t) que já existem no firewall (uma única chamada
#   "az network firewall show") e monta um índice em memória de
#   "coleção|regra" já cadastradas.
#
#   Para cada linha do CSV, se a combinação collection_name + rule_name já
#   existir no firewall (nesse tipo de regra), a linha é PULADA (não
#   duplica e não sobrescreve). Regras que já existem não são atualizadas
#   mesmo que os demais campos do CSV sejam diferentes dos valores atuais
#   no Azure — se for necessário alterar uma regra existente, isso deve ser
#   feito de forma explícita (fora deste script), por exemplo com o comando
#   "*-rule update" correspondente, ou removendo a regra antes de rodar o
#   script novamente.
#
#   Isso permite executar o script quantas vezes forem necessárias com o
#   mesmo CSV (ou um CSV incremental) sem risco de duplicar regras.
#
# NOTA SOBRE "priority" E "action":
#
#   Na Azure Firewall "clássica", priority e action pertencem à *coleção*
#   de regras, não à regra individual. Isso quer dizer que esses valores só
#   têm efeito na primeira regra que cria a coleção — linhas seguintes do
#   CSV que apontem para a mesma coleção com priority/action diferentes são
#   silenciosamente ignoradas pela API. O script valida isso e emite um
#   aviso caso detecte valores divergentes para a mesma coleção.
#
# ---------------------------------------------------------------------------
# FORMATO DO CSV (com cabeçalho obrigatório e exato na primeira linha —
# o script recusa a execução se o cabeçalho não bater com o esperado para
# o -t escolhido, e também recusa qualquer linha de dados com número de
# campos diferente do esperado, para não desalinhar colunas por causa de
# uma vírgula a mais ou a menos):
#
# -t network (regra de rede — Allow/Deny por IP/porta/protocolo):
#   collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports
#
#   - collection_name       : nome da coleção (criada automaticamente se não existir)
#   - rule_name              : nome da regra
#   - priority               : número de 100 a 65000 (só a 1ª regra da coleção; opcional nas demais)
#   - action                 : Allow ou Deny (padrão: Allow)
#   - protocols              : Any, ICMP, TCP ou UDP, separados por ";"
#   - source_addresses       : IP(s)/CIDR de origem, separados por ";". "*" = qualquer origem
#   - destination_addresses  : IP(s)/CIDR de destino, separados por ";"
#   - destination_ports      : porta(s) de destino, separadas por ";". "*" = qualquer porta
#
#   Exemplo:
#   Net-Coll01,Allow-DNS,200,Allow,UDP,10.0.2.0/24,168.63.129.16;8.8.8.8,53
#
# -t nat (DNAT — redireciona tráfego que chega no firewall para um
# endereço/porta internos; a action é sempre "Dnat", por isso não há
# coluna de action neste formato):
#   collection_name,rule_name,priority,protocols,source_addresses,destination_addresses,destination_ports,translated_address,translated_port
#
#   - collection_name       : nome da coleção
#   - rule_name              : nome da regra
#   - priority               : número de 100 a 65000 (só a 1ª regra da coleção)
#   - protocols              : TCP ou UDP, separados por ";" (não suporta Any/ICMP)
#   - source_addresses       : IP(s)/CIDR de origem, separados por ";"
#   - destination_addresses  : endereço público/IP do firewall que recebe o tráfego
#   - destination_ports      : porta em que o tráfego chega
#   - translated_address     : endereço interno para onde o tráfego é traduzido
#   - translated_port        : porta interna para onde o tráfego é traduzido
#
#   Exemplo:
#   Nat-Coll01,DNAT-RDP,210,TCP,0.0.0.0/0,20.1.2.3,3389,10.0.2.10,3389
#
# -t application (regra de aplicação — Allow/Deny por FQDN; não tem IP de
# destino, por isso não há colunas destination_addresses/destination_ports
# neste formato):
#   collection_name,rule_name,priority,action,protocols,source_addresses,target_fqdns,fqdn_tags
#
#   - collection_name : nome da coleção
#   - rule_name         : nome da regra
#   - priority          : número de 100 a 65000 (só a 1ª regra da coleção)
#   - action            : Allow ou Deny (padrão: Allow)
#   - protocols         : pares "Protocolo=Porta" separados por ";", ex.: "Http=80;Https=443"
#                        (protocolos aceitos: Http, Https, Mssql)
#   - source_addresses  : IP(s)/CIDR de origem, separados por ";"
#   - target_fqdns      : FQDN(s) de destino, separados por ";" (ex.: "www.contoso.com;*.contoso.net")
#   - fqdn_tags         : FQDN tag(s) do Azure, separadas por ";" (ex.: "WindowsUpdate")
#                        (pelo menos um entre target_fqdns e fqdn_tags é obrigatório)
#
#   Exemplo:
#   App-Coll01,Allow-Web,220,Allow,Http=80;Https=443,10.0.2.0/24,www.microsoft.com;*.ubuntu.com,
#
# ---------------------------------------------------------------------------
# USO:
#
#   ./criar_regras_firewall.sh -g <resource-group> -f <firewall-name> -t <network|nat|application> -c <arquivo.csv> [-n] [-l <log-file>]
#
#   -g   Resource group onde está o Azure Firewall
#   -f   Nome do Azure Firewall
#   -t   Tipo de regra do CSV: network, nat ou application
#   -c   Caminho do arquivo CSV com as regras (no formato do -t escolhido)
#   -n   Modo dry-run: apenas exibe os comandos que seriam executados
#   -l   Caminho de um arquivo de log (a saída também é gravada nele)
#   -h   Exibe esta ajuda
#
# Pré-requisitos: Azure CLI (az) e jq instalados e "az login" já executado.
# Ambos já vêm pré-instalados no Azure Cloud Shell.
#
# DIAGNÓSTICO DE SESSÃO/PERMISSÃO:
#
#   "az account show" sozinho não garante muita coisa: ele só lê o cache
#   local (~/.azure), então pode "passar" mesmo com o token de atualização
#   expirado. Por isso o script também roda "az account get-access-token",
#   que força uma renovação de token de verdade junto ao Azure AD, antes de
#   fazer qualquer outra coisa. Se a sessão caiu, o script para logo no
#   início com uma mensagem específica pedindo "az login" novamente, em vez
#   de deixar o erro aparecer depois, disfarçado de "firewall não
#   encontrado" ou de uma sequência de "FALHOU" no meio do processamento do
#   CSV.
#
#   Se a sessão expirar NO MEIO da execução (CSV grande, token expira após
#   ~1h), o script também detecta isso na criação de uma regra e ABORTA
#   imediatamente com uma mensagem clara — em vez de continuar tentando
#   criar as regras seguintes e reportando "FALHOU" em cada uma delas sem
#   dizer por quê. Como o script é idempotente, basta rodar "az login" e
#   executá-lo de novo: as regras já criadas não serão duplicadas.
#
#   Da mesma forma, "resource group não encontrado" e "firewall não
#   encontrado" agora são erros distintos (antes caíam na mesma mensagem
#   genérica), e o texto de erro devolvido pelo Azure CLI é sempre exibido
#   quando o motivo da falha não é reconhecido, em vez de descartado.
# ---------------------------------------------------------------------------

set -uo pipefail
set -f  # desabilita expansão de glob (importante: campos como "*" não podem virar nomes de arquivo)

RESOURCE_GROUP=""
FIREWALL_NAME=""
CSV_FILE=""
DRY_RUN=false
LOG_FILE=""
RULE_TYPE_RAW=""

# Padrão usado para reconhecer, no texto de erro do Azure CLI, que o
# problema é sessão/token expirado ou inválido (e não outra falha
# qualquer). Reaproveitado no diagnóstico inicial e nas chamadas de
# criação de regra dentro do loop.
AUTH_ERROR_REGEX="az login|AADSTS|refresh token|token has expired|Please run|has not been authenticated|InvalidAuthenticationToken|Please re-authenticate"

usage() {
  echo "Uso: $0 -g <resource-group> -f <firewall-name> -t <network|nat|application> -c <arquivo.csv> [-n] [-l <log-file>]"
  echo
  echo "  -g   Resource group do Azure Firewall"
  echo "  -f   Nome do Azure Firewall"
  echo "  -t   Tipo de regra do CSV: network, nat ou application"
  echo "  -c   Arquivo CSV com as regras (no formato do -t escolhido)"
  echo "  -n   Dry-run (apenas exibe os comandos, sem executar)"
  echo "  -l   Também grava a saída neste arquivo de log"
  echo "  -h   Exibe esta ajuda"
  exit 1
}

while getopts ":g:f:c:t:nl:h" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    f) FIREWALL_NAME="$OPTARG" ;;
    c) CSV_FILE="$OPTARG" ;;
    t) RULE_TYPE_RAW="$OPTARG" ;;
    n) DRY_RUN=true ;;
    l) LOG_FILE="$OPTARG" ;;
    h) usage ;;
    :) echo "Erro: a opção -$OPTARG requer um argumento." >&2; usage ;;
    \?) echo "Erro: opção inválida -$OPTARG." >&2; usage ;;
  esac
done

[[ -z "$RESOURCE_GROUP" || -z "$FIREWALL_NAME" || -z "$CSV_FILE" || -z "$RULE_TYPE_RAW" ]] && usage

RULE_TYPE="${RULE_TYPE_RAW,,}"
case "$RULE_TYPE" in
  network|nat|application) ;;
  *)
    echo "Erro: -t deve ser 'network', 'nat' ou 'application' (recebido: '$RULE_TYPE_RAW')." >&2
    usage
    ;;
esac

# Formato de CSV esperado para o tipo escolhido: cabeçalho exato, número de
# campos por linha, e em qual array do recurso do firewall procurar as
# regras já existentes (idempotência).
case "$RULE_TYPE" in
  network)
    EXPECTED_HEADER="collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports"
    EXPECTED_FIELD_COUNT=8
    JQ_COLLECTION_FIELD="networkRuleCollections"
    ;;
  nat)
    EXPECTED_HEADER="collection_name,rule_name,priority,protocols,source_addresses,destination_addresses,destination_ports,translated_address,translated_port"
    EXPECTED_FIELD_COUNT=9
    JQ_COLLECTION_FIELD="natRuleCollections"
    ;;
  application)
    EXPECTED_HEADER="collection_name,rule_name,priority,action,protocols,source_addresses,target_fqdns,fqdn_tags"
    EXPECTED_FIELD_COUNT=8
    JQ_COLLECTION_FIELD="applicationRuleCollections"
    ;;
esac

trim() {
  local var="$1"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo -n "$var"
}

if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "===== Execução iniciada em $(date -Iseconds) ====="
fi

if [[ ! -f "$CSV_FILE" ]]; then
  echo "Erro: arquivo '$CSV_FILE' não encontrado."
  exit 1
fi

# Valida o cabeçalho do CSV ANTES de qualquer chamada ao Azure — pega de
# imediato um CSV no formato errado para o -t escolhido (ex.: apontar um
# CSV de "nat" enquanto roda com -t network).
CSV_HEADER_NORM=$(trim "$(head -n 1 "$CSV_FILE")")
CSV_HEADER_NORM="${CSV_HEADER_NORM//, /,}"
CSV_HEADER_NORM="${CSV_HEADER_NORM// ,/,}"
if [[ "$CSV_HEADER_NORM" != "$EXPECTED_HEADER" ]]; then
  echo "Erro: cabeçalho do CSV não confere com o esperado para -t $RULE_TYPE."
  echo "  Esperado : $EXPECTED_HEADER"
  echo "  Encontrado: $CSV_HEADER_NORM"
  exit 1
fi

if ! command -v az >/dev/null 2>&1; then
  echo "Erro: Azure CLI (az) não encontrado no PATH."
  exit 1
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "Erro: 'jq' não encontrado no PATH (necessário para a checagem de idempotência)."
  echo "No Azure Cloud Shell o jq já vem pré-instalado."
  exit 1
fi

# Verifica se está autenticado no Azure CLI. "az account show" só lê o
# cache local (~/.azure) e pode "passar" mesmo com o token expirado, então
# em seguida forçamos uma renovação de token de verdade com
# "az account get-access-token" — é isso que realmente detecta uma sessão
# caída antes de começarmos a mexer no firewall.
ACCOUNT_ERR=$(az account show -o none 2>&1)
if [[ $? -ne 0 ]]; then
  echo "Erro: você não está autenticado no Azure CLI. Execute 'az login' antes de continuar."
  [[ -n "$ACCOUNT_ERR" ]] && echo "Detalhe retornado pelo Azure CLI: $ACCOUNT_ERR"
  exit 1
fi

TOKEN_ERR=$(az account get-access-token -o none 2>&1)
if [[ $? -ne 0 ]]; then
  echo "Erro: sua sessão do Azure CLI expirou ou é inválida. Execute 'az login' novamente antes de continuar."
  [[ -n "$TOKEN_ERR" ]] && echo "Detalhe retornado pelo Azure CLI: $TOKEN_ERR"
  exit 1
fi

# Garante que a extensão azure-firewall está instalada/atualizada
az extension add --name azure-firewall --upgrade --only-show-errors >/dev/null 2>&1 || true

# Confirma que o firewall existe no resource group informado e já aproveita
# a mesma chamada para carregar as coleções/regras existentes (evita
# chamadas extras "az network firewall show" só para isso).
echo "Consultando o Azure Firewall '$FIREWALL_NAME'..."
FIREWALL_ERR=$(mktemp)
FIREWALL_JSON=$(az network firewall show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FIREWALL_NAME" \
  --only-show-errors -o json 2>"$FIREWALL_ERR")
FIREWALL_EXIT=$?
FIREWALL_ERR_TEXT=$(cat "$FIREWALL_ERR")
rm -f "$FIREWALL_ERR"

if [[ "$FIREWALL_EXIT" -ne 0 || -z "$FIREWALL_JSON" ]]; then
  if [[ "$FIREWALL_ERR_TEXT" =~ $AUTH_ERROR_REGEX ]]; then
    echo "Erro: sua sessão do Azure CLI expirou ou é inválida. Execute 'az login' novamente antes de continuar."
  elif [[ "$FIREWALL_ERR_TEXT" =~ ResourceGroupNotFound ]]; then
    echo "Erro: o resource group '$RESOURCE_GROUP' não foi encontrado (ou você não tem permissão para acessá-lo)."
  elif [[ "$FIREWALL_ERR_TEXT" =~ (ResourceNotFound|was not found) ]]; then
    echo "Erro: firewall '$FIREWALL_NAME' não encontrado no resource group '$RESOURCE_GROUP'."
  else
    echo "Erro: não foi possível consultar o firewall '$FIREWALL_NAME' no resource group '$RESOURCE_GROUP'."
  fi
  [[ -n "$FIREWALL_ERR_TEXT" ]] && echo "Detalhe retornado pelo Azure CLI: $FIREWALL_ERR_TEXT"
  exit 1
fi

# ---------------------------------------------------------------------------
# Índice de idempotência: "collection_name|rule_name" -> 1 para toda regra
# do tipo selecionado (-t) já existente no firewall.
# ---------------------------------------------------------------------------
declare -A EXISTING_RULES
while IFS=$'\t' read -r coll rule; do
  [[ -z "$coll" || -z "$rule" ]] && continue
  EXISTING_RULES["${coll}|${rule}"]=1
done < <(echo "$FIREWALL_JSON" | jq -r --arg field "$JQ_COLLECTION_FIELD" '
  (.[$field] // [])[] | .name as $c | (.rules // [])[] | "\($c)\t\(.name)"
')
echo "Encontradas ${#EXISTING_RULES[@]} regra(s) do tipo '$RULE_TYPE' já existente(s) no firewall."

TOTAL=0
OK=0
SKIPPED=0
FAIL=0
LINE_NUM=0

# Conjuntos válidos (chave em maiúsculas -> valor "canônico" esperado pela API)
declare -A VALID_PROTOCOLS=( [ANY]="Any" [ICMP]="ICMP" [TCP]="TCP" [UDP]="UDP" )
declare -A VALID_ACTIONS=( [ALLOW]="Allow" [DENY]="Deny" )
declare -A VALID_APP_PROTOCOLS=( [HTTP]="Http" [HTTPS]="Https" [MSSQL]="Mssql" )

# Resumo legível dos campos da regra (linha atual), variando por RULE_TYPE.
# Usa as variáveis do laço principal diretamente (mesma shell, sem subshell).
format_rule_summary() {
  local d="tipo=$RULE_TYPE"
  case "$RULE_TYPE" in
    nat)
      d+=" action=Dnat protocolo(s)=${protocols//;/, } origem=${source_addresses:-*}"
      d+=" destino=${destination_addresses//;/, } porta(s)=${destination_ports//;/, }"
      d+=" traduzido_para=${translated_address}:${translated_port}"
      ;;
    application)
      d+=" action=${action:-Allow} protocolo(s)=${protocols//;/, } origem=${source_addresses:-*}"
      [[ -n "$target_fqdns" ]] && d+=" fqdns=${target_fqdns//;/, }"
      [[ -n "$fqdn_tags" ]] && d+=" fqdn_tags=${fqdn_tags//;/, }"
      ;;
    *)
      d+=" action=${action:-Allow} protocolo(s)=${protocols//;/, } origem=${source_addresses:-*}"
      d+=" destino=${destination_addresses//;/, } porta(s)=${destination_ports//;/, }"
      ;;
  esac
  [[ -n "$priority" ]] && d+=" priority=$priority"
  echo -n "$d"
}

# Separa uma linha de CSV em campos, preservando campos vazios no FINAL da
# linha (ex.: "a,b,," -> 4 campos). "read -a" sozinho descarta um campo
# vazio final, então acrescentamos um marcador antes do split e removemos
# em seguida. Resultado fica no array global "raw_fields".
split_csv_line() {
  local line="$1"
  IFS=',' read -ra raw_fields <<< "${line},__END__"
  unset "raw_fields[${#raw_fields[@]}-1]"
}

# ---------------------------------------------------------------------------
# Pré-checagem: avisa se o CSV define priority/action divergentes para a
# mesma coleção (a Azure só usa o valor da primeira regra que cria a
# coleção). collection_name, rule_name e priority estão sempre nas 3
# primeiras posições, nos três formatos de CSV; "action" só existe nos
# formatos network/application (na posição 4).
# ---------------------------------------------------------------------------
declare -A COLL_PRIORITY_SEEN
declare -A COLL_ACTION_SEEN
_pre_line=0
while IFS= read -r pline || [[ -n "$pline" ]]; do
  _pre_line=$((_pre_line + 1))
  [[ "$_pre_line" -eq 1 ]] && continue
  [[ -z "$pline" || "$pline" =~ ^#.*$ ]] && continue

  split_csv_line "$pline"
  pc_name=$(trim "${raw_fields[0]:-}")
  pc_priority=$(trim "${raw_fields[2]:-}")
  [[ -z "$pc_name" ]] && continue

  if [[ -n "$pc_priority" ]]; then
    prev="${COLL_PRIORITY_SEEN[$pc_name]:-}"
    if [[ -n "$prev" && "$prev" != "$pc_priority" ]]; then
      echo "Aviso: a coleção '$pc_name' tem valores de 'priority' divergentes no CSV ('$prev' e '$pc_priority'). A Azure só usa a priority definida na primeira regra que cria a coleção." >&2
    fi
    COLL_PRIORITY_SEEN[$pc_name]="$pc_priority"
  fi

  if [[ "$RULE_TYPE" != "nat" ]]; then
    pc_action=$(trim "${raw_fields[3]:-}")
    if [[ -n "$pc_action" ]]; then
      prev="${COLL_ACTION_SEEN[$pc_name]:-}"
      if [[ -n "$prev" && "$prev" != "$pc_action" ]]; then
        echo "Aviso: a coleção '$pc_name' tem valores de 'action' divergentes no CSV ('$prev' e '$pc_action'). A Azure só usa a action definida na primeira regra que cria a coleção." >&2
      fi
      COLL_ACTION_SEEN[$pc_name]="$pc_action"
    fi
  fi
done < "$CSV_FILE"

# ---------------------------------------------------------------------------
# Retry com backoff exponencial para chamadas ao Azure CLI. Chamadas ao
# Azure Firewall fazem um GET+PUT do recurso inteiro e podem falhar
# transitoriamente (ex.: "AnotherOperationInProgress") quando disparadas em
# sequência rápida.
# ---------------------------------------------------------------------------
# Retorna: 0 = sucesso, 1 = falha comum (esgotou as tentativas), 2 = falha
# por sessão/token expirado (não adianta tentar de novo, é preciso "az login").
run_with_retry() {
  local max_attempts=3
  local delay=5
  local attempt=1
  local output
  while true; do
    if output=$("$@" 2>&1); then
      return 0
    fi
    if [[ "$output" =~ $AUTH_ERROR_REGEX ]]; then
      echo "$output" >&2
      return 2
    fi
    if [[ "$attempt" -ge "$max_attempts" ]]; then
      echo "$output" >&2
      return 1
    fi
    echo "  Tentativa $attempt falhou, tentando novamente em ${delay}s..." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

while IFS= read -r line || [[ -n "$line" ]]; do
  LINE_NUM=$((LINE_NUM + 1))

  # Pula o cabeçalho (já validado antes do loop)
  [[ "$LINE_NUM" -eq 1 ]] && continue

  # Pula linhas vazias ou comentadas com #
  [[ -z "$line" || "$line" =~ ^#.*$ ]] && continue

  TOTAL=$((TOTAL + 1))

  split_csv_line "$line"
  if [[ "${#raw_fields[@]}" -ne "$EXPECTED_FIELD_COUNT" ]]; then
    echo "[Linha $LINE_NUM] Ignorada: número de campos incorreto (esperado $EXPECTED_FIELD_COUNT para -t $RULE_TYPE, encontrado ${#raw_fields[@]}) — confira as vírgulas da linha."
    FAIL=$((FAIL + 1))
    continue
  fi

  # Valores padrão: cada tipo só preenche os campos que usa (os demais
  # ficam vazios e simplesmente não são referenciados no restante do loop).
  action=""; destination_addresses=""; destination_ports=""
  translated_address=""; translated_port=""; target_fqdns=""; fqdn_tags=""

  case "$RULE_TYPE" in
    network)
      collection_name="${raw_fields[0]}"; rule_name="${raw_fields[1]}"; priority="${raw_fields[2]}"
      action="${raw_fields[3]}"; protocols="${raw_fields[4]}"; source_addresses="${raw_fields[5]}"
      destination_addresses="${raw_fields[6]}"; destination_ports="${raw_fields[7]}"
      ;;
    nat)
      collection_name="${raw_fields[0]}"; rule_name="${raw_fields[1]}"; priority="${raw_fields[2]}"
      protocols="${raw_fields[3]}"; source_addresses="${raw_fields[4]}"; destination_addresses="${raw_fields[5]}"
      destination_ports="${raw_fields[6]}"; translated_address="${raw_fields[7]}"; translated_port="${raw_fields[8]}"
      ;;
    application)
      collection_name="${raw_fields[0]}"; rule_name="${raw_fields[1]}"; priority="${raw_fields[2]}"
      action="${raw_fields[3]}"; protocols="${raw_fields[4]}"; source_addresses="${raw_fields[5]}"
      target_fqdns="${raw_fields[6]}"; fqdn_tags="${raw_fields[7]}"
      ;;
  esac

  collection_name=$(trim "$collection_name")
  rule_name=$(trim "$rule_name")
  priority=$(trim "$priority")
  action=$(trim "$action")
  protocols=$(trim "$protocols")
  source_addresses=$(trim "$source_addresses")
  destination_addresses=$(trim "$destination_addresses")
  destination_ports=$(trim "$destination_ports")
  translated_address=$(trim "$translated_address")
  translated_port=$(trim "$translated_port")
  target_fqdns=$(trim "$target_fqdns")
  fqdn_tags=$(trim "$fqdn_tags")

  if [[ -z "$collection_name" || -z "$rule_name" || -z "$protocols" ]]; then
    echo "[Linha $LINE_NUM] Ignorada: campos obrigatórios ausentes (collection_name, rule_name, protocols)."
    FAIL=$((FAIL + 1))
    continue
  fi

  # -------------------------------------------------------------------
  # Idempotência: se a regra já existe nessa coleção, pula sem duplicar
  # e sem sobrescrever.
  # -------------------------------------------------------------------
  rule_key="${collection_name}|${rule_name}"
  if [[ -n "${EXISTING_RULES[$rule_key]:-}" ]]; then
    echo "[Linha $LINE_NUM] Regra '$rule_name' já existe na coleção '$collection_name' -> ignorada (idempotente)."
    echo "    Solicitado no CSV: $(format_rule_summary)"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Valida priority (100 a 65000), se informado — comum aos três tipos
  if [[ -n "$priority" ]] && ! [[ "$priority" =~ ^[0-9]+$ && "$priority" -ge 100 && "$priority" -le 65000 ]]; then
    echo "[Linha $LINE_NUM] Ignorada: priority '$priority' inválida (deve ser um número entre 100 e 65000)."
    FAIL=$((FAIL + 1))
    continue
  fi

  source_list="${source_addresses//;/ }"
  CMD=()

  case "$RULE_TYPE" in

    network)
      if [[ -z "$destination_ports" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: destination_ports é obrigatório."
        FAIL=$((FAIL + 1))
        continue
      fi

      if [[ -z "$action" ]]; then
        action="Allow"
      else
        action_key="${action^^}"
        if [[ -z "${VALID_ACTIONS[$action_key]:-}" ]]; then
          echo "[Linha $LINE_NUM] Ignorada: action '$action' inválida (use Allow ou Deny)."
          FAIL=$((FAIL + 1))
          continue
        fi
        action="${VALID_ACTIONS[$action_key]}"
      fi

      protocols_list=""
      invalid_protocol=""
      for proto in ${protocols//;/ }; do
        proto_key="${proto^^}"
        if [[ -z "${VALID_PROTOCOLS[$proto_key]:-}" ]]; then
          invalid_protocol="$proto"
          break
        fi
        protocols_list+="${VALID_PROTOCOLS[$proto_key]} "
      done
      if [[ -n "$invalid_protocol" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: protocolo '$invalid_protocol' inválido (use Any, ICMP, TCP ou UDP)."
        FAIL=$((FAIL + 1))
        continue
      fi

      dest_addr_list="${destination_addresses//;/ }"
      dest_ports_list="${destination_ports//;/ }"

      CMD=(az network firewall network-rule create
           --resource-group "$RESOURCE_GROUP"
           --firewall-name "$FIREWALL_NAME"
           --collection-name "$collection_name"
           --name "$rule_name"
           --protocols $protocols_list
           --destination-ports $dest_ports_list
           --action "$action"
           --only-show-errors)
      [[ -n "$priority" ]] && CMD+=(--priority "$priority")
      [[ -n "$source_list" ]] && CMD+=(--source-addresses $source_list)
      [[ -n "$dest_addr_list" ]] && CMD+=(--destination-addresses $dest_addr_list)
      ;;

    nat)
      if [[ -z "$destination_addresses" || -z "$destination_ports" || -z "$translated_address" || -z "$translated_port" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: destination_addresses, destination_ports, translated_address e translated_port são obrigatórios."
        FAIL=$((FAIL + 1))
        continue
      fi

      protocols_list=""
      invalid_protocol=""
      for proto in ${protocols//;/ }; do
        proto_key="${proto^^}"
        if [[ "$proto_key" != "TCP" && "$proto_key" != "UDP" ]]; then
          invalid_protocol="$proto"
          break
        fi
        protocols_list+="$proto_key "
      done
      if [[ -n "$invalid_protocol" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: protocolo '$invalid_protocol' inválido (use TCP ou UDP)."
        FAIL=$((FAIL + 1))
        continue
      fi

      dest_addr_list="${destination_addresses//;/ }"
      dest_ports_list="${destination_ports//;/ }"

      CMD=(az network firewall nat-rule create
           --resource-group "$RESOURCE_GROUP"
           --firewall-name "$FIREWALL_NAME"
           --collection-name "$collection_name"
           --name "$rule_name"
           --protocols $protocols_list
           --destination-ports $dest_ports_list
           --destination-addresses $dest_addr_list
           --translated-address "$translated_address"
           --translated-port "$translated_port"
           --action "Dnat"
           --only-show-errors)
      [[ -n "$priority" ]] && CMD+=(--priority "$priority")
      [[ -n "$source_list" ]] && CMD+=(--source-addresses $source_list)
      ;;

    application)
      if [[ -z "$target_fqdns" && -z "$fqdn_tags" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: pelo menos um entre target_fqdns e fqdn_tags é obrigatório."
        FAIL=$((FAIL + 1))
        continue
      fi

      if [[ -z "$action" ]]; then
        action="Allow"
      else
        action_key="${action^^}"
        if [[ -z "${VALID_ACTIONS[$action_key]:-}" ]]; then
          echo "[Linha $LINE_NUM] Ignorada: action '$action' inválida (use Allow ou Deny)."
          FAIL=$((FAIL + 1))
          continue
        fi
        action="${VALID_ACTIONS[$action_key]}"
      fi

      protocols_list=""
      invalid_protocol=""
      for proto_pair in ${protocols//;/ }; do
        proto_name="${proto_pair%%=*}"
        proto_port="${proto_pair#*=}"
        proto_name_key="${proto_name^^}"
        if [[ "$proto_pair" != *=* || -z "${VALID_APP_PROTOCOLS[$proto_name_key]:-}" || ! "$proto_port" =~ ^[0-9]+$ ]]; then
          invalid_protocol="$proto_pair"
          break
        fi
        protocols_list+="${VALID_APP_PROTOCOLS[$proto_name_key]}=${proto_port} "
      done
      if [[ -n "$invalid_protocol" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: protocolo '$invalid_protocol' inválido (use o formato Protocolo=Porta, ex.: Http=80; protocolos aceitos: Http, Https, Mssql)."
        FAIL=$((FAIL + 1))
        continue
      fi

      CMD=(az network firewall application-rule create
           --resource-group "$RESOURCE_GROUP"
           --firewall-name "$FIREWALL_NAME"
           --collection-name "$collection_name"
           --name "$rule_name"
           --protocols $protocols_list
           --action "$action"
           --only-show-errors)
      [[ -n "$priority" ]] && CMD+=(--priority "$priority")
      [[ -n "$source_list" ]] && CMD+=(--source-addresses $source_list)
      [[ -n "$target_fqdns" ]] && CMD+=(--target-fqdns ${target_fqdns//;/ })
      [[ -n "$fqdn_tags" ]] && CMD+=(--fqdn-tags ${fqdn_tags//;/ })
      ;;
  esac

  echo "[Linha $LINE_NUM] Criando regra '$rule_name' na coleção '$collection_name': $(format_rule_summary)"

  if [[ "$DRY_RUN" == true ]]; then
    printf '    comando:'
    printf ' %q' "${CMD[@]}"
    echo
    OK=$((OK + 1))
    EXISTING_RULES["$rule_key"]=1
    continue
  fi

  if run_with_retry "${CMD[@]}" >/dev/null; then
    echo "  -> OK (regra '$rule_name' criada na coleção '$collection_name')"
    OK=$((OK + 1))
    EXISTING_RULES["$rule_key"]=1
  else
    retry_rc=$?
    if [[ "$retry_rc" -eq 2 ]]; then
      echo
      echo "Erro fatal: a sessão do Azure CLI expirou/ficou inválida durante a execução (linha $LINE_NUM, regra '$rule_name')."
      echo "Execute 'az login' novamente e rode o script mais uma vez: as regras já criadas não serão duplicadas (o script é idempotente)."
      exit 1
    fi
    echo "  -> FALHOU (regra '$rule_name' na coleção '$collection_name')"
    FAIL=$((FAIL + 1))
  fi

done < "$CSV_FILE"

echo
echo "Resumo (rule_type=$RULE_TYPE): $TOTAL regra(s) processada(s), $OK criada(s), $SKIPPED já existente(s) (ignorada(s)), $FAIL com falha."

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
