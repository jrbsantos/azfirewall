#!/usr/bin/env bash
#
# criar_regras_firewall.sh
#
# Lê um arquivo CSV e cria "network rules" (regras de rede) no Azure Firewall
# usando o Azure CLI, através do comando oficial:
#
#   az network firewall network-rule create
#
# Referências oficiais consultadas (Microsoft Learn):
#   - Tutorial: https://learn.microsoft.com/azure/firewall/deploy-cli
#   - Referência do comando: https://learn.microsoft.com/cli/azure/network/firewall/network-rule
#
# ---------------------------------------------------------------------------
# IDEMPOTÊNCIA (importante):
#
#   Antes de criar qualquer regra, o script consulta as network rule
#   collections já existentes no firewall (uma única chamada
#   "az network firewall show") e monta um índice em memória de
#   "coleção|regra" já cadastradas.
#
#   Para cada linha do CSV, se a combinação collection_name + rule_name já
#   existir no firewall, a linha é PULADA (não duplica e não sobrescreve).
#   Regras que já existem não são atualizadas mesmo que os demais campos do
#   CSV sejam diferentes dos valores atuais no Azure — se for necessário
#   alterar uma regra existente, isso deve ser feito de forma explícita
#   (fora deste script), por exemplo com "az network firewall network-rule
#   update" ou removendo a regra antes de rodar o script novamente.
#
#   Isso permite executar o script quantas vezes forem necessárias com o
#   mesmo CSV (ou um CSV incremental) sem risco de duplicar regras.
#
# NOTA SOBRE "priority" E "action":
#
#   Na Azure Firewall "clássica", priority e action pertencem à *coleção*
#   de regras, não à regra individual. Isso quer dizer que esses valores
#   só têm efeito na primeira regra que cria a coleção — linhas seguintes
#   do CSV que apontem para a mesma coleção com priority/action diferentes
#   são silenciosamente ignoradas pela API. O script agora valida isso e
#   emite um aviso caso detecte valores divergentes para a mesma coleção.
#
# ---------------------------------------------------------------------------
# FORMATO DO CSV (com cabeçalho obrigatório na primeira linha):
#
#   collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports
#
# Regras de preenchimento:
#   - collection_name          : nome da coleção de regras (é criada automaticamente
#                                 se ainda não existir)
#   - rule_name                : nome da regra
#   - priority                 : número de 100 a 65000 (usado só quando a coleção
#                                 é criada pela primeira vez; opcional nas demais)
#   - action                   : Allow ou Deny (mesma observação acima)
#   - protocols                : Any, ICMP, TCP ou UDP. Vários valores separados por ";"
#   - source_addresses          : IP(s)/CIDR de origem, separados por ";". Use "*" para qualquer origem
#   - destination_addresses     : IP(s)/CIDR de destino, separados por ";"
#   - destination_ports         : porta(s) de destino, separadas por ";". Use "*" para qualquer porta
#
# Exemplo de linha:
#   Net-Coll01,Allow-DNS,200,Allow,UDP,10.0.2.0/24,168.63.129.16;8.8.8.8,53
#
# ---------------------------------------------------------------------------
# USO:
#
#   ./criar_regras_firewall.sh -g <resource-group> -f <firewall-name> -c <arquivo.csv> [-n] [-l <log-file>]
#
#   -g   Resource group onde está o Azure Firewall
#   -f   Nome do Azure Firewall
#   -c   Caminho do arquivo CSV com as regras
#   -n   Modo dry-run: apenas exibe os comandos que seriam executados
#   -l   Caminho de um arquivo de log (a saída também é gravada nele)
#   -h   Exibe esta ajuda
#
# Pré-requisitos: Azure CLI (az) e jq instalados e "az login" já executado.
# Ambos já vêm pré-instalados no Azure Cloud Shell.
# ---------------------------------------------------------------------------

set -uo pipefail
set -f  # desabilita expansão de glob (importante: campos como "*" não podem virar nomes de arquivo)

RESOURCE_GROUP=""
FIREWALL_NAME=""
CSV_FILE=""
DRY_RUN=false
LOG_FILE=""

usage() {
  echo "Uso: $0 -g <resource-group> -f <firewall-name> -c <arquivo.csv> [-n] [-l <log-file>]"
  echo
  echo "  -g   Resource group do Azure Firewall"
  echo "  -f   Nome do Azure Firewall"
  echo "  -c   Arquivo CSV com as regras"
  echo "  -n   Dry-run (apenas exibe os comandos, sem executar)"
  echo "  -l   Também grava a saída neste arquivo de log"
  echo "  -h   Exibe esta ajuda"
  exit 1
}

while getopts ":g:f:c:nl:h" opt; do
  case "$opt" in
    g) RESOURCE_GROUP="$OPTARG" ;;
    f) FIREWALL_NAME="$OPTARG" ;;
    c) CSV_FILE="$OPTARG" ;;
    n) DRY_RUN=true ;;
    l) LOG_FILE="$OPTARG" ;;
    h) usage ;;
    :) echo "Erro: a opção -$OPTARG requer um argumento." >&2; usage ;;
    \?) echo "Erro: opção inválida -$OPTARG." >&2; usage ;;
  esac
done

[[ -z "$RESOURCE_GROUP" || -z "$FIREWALL_NAME" || -z "$CSV_FILE" ]] && usage

if [[ -n "$LOG_FILE" ]]; then
  exec > >(tee -a "$LOG_FILE") 2>&1
  echo "===== Execução iniciada em $(date -Iseconds) ====="
fi

if [[ ! -f "$CSV_FILE" ]]; then
  echo "Erro: arquivo '$CSV_FILE' não encontrado."
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

# Verifica se está autenticado no Azure CLI
if ! az account show >/dev/null 2>&1; then
  echo "Erro: você não está autenticado no Azure CLI. Execute 'az login' antes de continuar."
  exit 1
fi

# Garante que a extensão azure-firewall está instalada/atualizada
az extension add --name azure-firewall --upgrade --only-show-errors >/dev/null 2>&1 || true

# Confirma que o firewall existe no resource group informado e já aproveita
# a mesma chamada para carregar as coleções/regras existentes (evita uma
# segunda chamada "az network firewall show" só para isso).
echo "Consultando o Azure Firewall '$FIREWALL_NAME'..."
FIREWALL_JSON=$(az network firewall show \
  --resource-group "$RESOURCE_GROUP" \
  --name "$FIREWALL_NAME" \
  --only-show-errors -o json 2>/dev/null)

if [[ -z "$FIREWALL_JSON" ]]; then
  echo "Erro: firewall '$FIREWALL_NAME' não encontrado no resource group '$RESOURCE_GROUP'."
  exit 1
fi

# ---------------------------------------------------------------------------
# Índice de idempotência: "collection_name|rule_name" -> 1 para toda regra
# já existente no firewall.
# ---------------------------------------------------------------------------
declare -A EXISTING_RULES
while IFS=$'\t' read -r coll rule; do
  [[ -z "$coll" || -z "$rule" ]] && continue
  EXISTING_RULES["${coll}|${rule}"]=1
done < <(echo "$FIREWALL_JSON" | jq -r '
  (.networkRuleCollections // [])[]
  | .name as $c
  | (.rules // [])[]
  | "\($c)\t\(.name)"
')
echo "Encontradas ${#EXISTING_RULES[@]} regra(s) já existente(s) no firewall."

TOTAL=0
OK=0
SKIPPED=0
FAIL=0
LINE_NUM=0

trim() {
  local var="$1"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo -n "$var"
}

# Conjuntos válidos (chave em maiúsculas -> valor "canônico" esperado pela API)
declare -A VALID_PROTOCOLS=( [ANY]="Any" [ICMP]="ICMP" [TCP]="TCP" [UDP]="UDP" )
declare -A VALID_ACTIONS=( [ALLOW]="Allow" [DENY]="Deny" )

# ---------------------------------------------------------------------------
# Pré-checagem: avisa se o CSV define priority/action divergentes para a
# mesma coleção (a Azure só usa o valor da primeira regra que cria a coleção).
# ---------------------------------------------------------------------------
declare -A COLL_ACTION_SEEN
declare -A COLL_PRIORITY_SEEN
_pre_line=0
while IFS=',' read -r pc_name _pr_name pc_priority pc_action _pc_rest; do
  _pre_line=$((_pre_line + 1))
  [[ "$_pre_line" -eq 1 && "$pc_name" == "collection_name" ]] && continue
  [[ -z "$pc_name" || "$pc_name" =~ ^#.*$ ]] && continue

  pc_name=$(trim "$pc_name")
  pc_priority=$(trim "$pc_priority")
  pc_action=$(trim "$pc_action")

  if [[ -n "$pc_action" ]]; then
    prev="${COLL_ACTION_SEEN[$pc_name]:-}"
    if [[ -n "$prev" && "$prev" != "$pc_action" ]]; then
      echo "Aviso: a coleção '$pc_name' tem valores de 'action' divergentes no CSV ('$prev' e '$pc_action'). A Azure só usa a action definida na primeira regra que cria a coleção." >&2
    fi
    COLL_ACTION_SEEN[$pc_name]="$pc_action"
  fi

  if [[ -n "$pc_priority" ]]; then
    prev="${COLL_PRIORITY_SEEN[$pc_name]:-}"
    if [[ -n "$prev" && "$prev" != "$pc_priority" ]]; then
      echo "Aviso: a coleção '$pc_name' tem valores de 'priority' divergentes no CSV ('$prev' e '$pc_priority'). A Azure só usa a priority definida na primeira regra que cria a coleção." >&2
    fi
    COLL_PRIORITY_SEEN[$pc_name]="$pc_priority"
  fi
done < "$CSV_FILE"

# ---------------------------------------------------------------------------
# Retry com backoff exponencial para chamadas ao Azure CLI. Chamadas ao
# Azure Firewall fazem um GET+PUT do recurso inteiro e podem falhar
# transitoriamente (ex.: "AnotherOperationInProgress") quando disparadas em
# sequência rápida.
# ---------------------------------------------------------------------------
run_with_retry() {
  local max_attempts=3
  local delay=5
  local attempt=1
  local output
  while true; do
    if output=$("$@" 2>&1); then
      return 0
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

while IFS=',' read -r collection_name rule_name priority action protocols source_addresses destination_addresses destination_ports; do
  LINE_NUM=$((LINE_NUM + 1))

  # Pula o cabeçalho
  if [[ "$LINE_NUM" -eq 1 && "$collection_name" == "collection_name" ]]; then
    continue
  fi

  # Pula linhas vazias ou comentadas com #
  [[ -z "$collection_name" || "$collection_name" =~ ^#.*$ ]] && continue

  TOTAL=$((TOTAL + 1))

  collection_name=$(trim "$collection_name")
  rule_name=$(trim "$rule_name")
  priority=$(trim "$priority")
  action=$(trim "$action")
  protocols=$(trim "$protocols")
  source_addresses=$(trim "$source_addresses")
  destination_addresses=$(trim "$destination_addresses")
  destination_ports=$(trim "$destination_ports")

  if [[ -z "$collection_name" || -z "$rule_name" || -z "$protocols" || -z "$destination_ports" ]]; then
    echo "[Linha $LINE_NUM] Ignorada: campos obrigatórios ausentes (collection_name, rule_name, protocols, destination_ports)."
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
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Valida priority (100 a 65000), se informado
  if [[ -n "$priority" ]] && ! [[ "$priority" =~ ^[0-9]+$ && "$priority" -ge 100 && "$priority" -le 65000 ]]; then
    echo "[Linha $LINE_NUM] Ignorada: priority '$priority' inválida (deve ser um número entre 100 e 65000)."
    FAIL=$((FAIL + 1))
    continue
  fi

  # Valida e normaliza action (default: Allow)
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

  # Valida e normaliza a lista de protocolos
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

  # Converte demais campos com múltiplos valores (separados por ";") em lista separada por espaço
  source_list="${source_addresses//;/ }"
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

  echo "[Linha $LINE_NUM] Criando regra '$rule_name' na coleção '$collection_name'..."

  if [[ "$DRY_RUN" == true ]]; then
    printf '  %q ' "${CMD[@]}"
    echo
    OK=$((OK + 1))
    EXISTING_RULES["$rule_key"]=1
    continue
  fi

  if run_with_retry "${CMD[@]}" >/dev/null; then
    echo "  -> OK"
    OK=$((OK + 1))
    EXISTING_RULES["$rule_key"]=1
  else
    echo "  -> FALHOU"
    FAIL=$((FAIL + 1))
  fi

done < "$CSV_FILE"

echo
echo "Resumo: $TOTAL regra(s) processada(s), $OK criada(s), $SKIPPED já existente(s) (ignorada(s)), $FAIL com falha."

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
