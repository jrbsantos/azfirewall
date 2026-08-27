#!/usr/bin/env bash
#
# criar_regras_firewall.sh
#
# Lê um arquivo CSV e cria regras no Azure Firewall usando o Azure CLI.
# Suporta os três tipos de regra do Azure Firewall "clássico":
#
#   rule_type=network      -> az network firewall network-rule create
#   rule_type=nat          -> az network firewall nat-rule create      (DNAT)
#   rule_type=application  -> az network firewall application-rule create
#
# Referências oficiais consultadas (Microsoft Learn):
#   - Tutorial: https://learn.microsoft.com/azure/firewall/deploy-cli
#   - Network rule: https://learn.microsoft.com/cli/azure/network/firewall/network-rule
#   - NAT rule: https://learn.microsoft.com/cli/azure/network/firewall/nat-rule
#   - Application rule: https://learn.microsoft.com/cli/azure/network/firewall/application-rule
#
# ---------------------------------------------------------------------------
# IDEMPOTÊNCIA (importante):
#
#   Antes de criar qualquer regra, o script consulta as rule collections já
#   existentes no firewall (uma única chamada "az network firewall show",
#   cobrindo os três tipos) e monta um índice em memória de
#   "tipo|coleção|regra" já cadastradas.
#
#   Para cada linha do CSV, se a combinação rule_type + collection_name +
#   rule_name já existir no firewall, a linha é PULADA (não duplica e não
#   sobrescreve). Regras que já existem não são atualizadas mesmo que os
#   demais campos do CSV sejam diferentes dos valores atuais no Azure — se
#   for necessário alterar uma regra existente, isso deve ser feito de forma
#   explícita (fora deste script), por exemplo com o comando "*-rule update"
#   correspondente, ou removendo a regra antes de rodar o script novamente.
#
#   Isso permite executar o script quantas vezes forem necessárias com o
#   mesmo CSV (ou um CSV incremental) sem risco de duplicar regras.
#
# NOTA SOBRE "priority" E "action":
#
#   Na Azure Firewall "clássica", priority e action pertencem à *coleção*
#   de regras, não à regra individual (nos três tipos). Isso quer dizer que
#   esses valores só têm efeito na primeira regra que cria a coleção —
#   linhas seguintes do CSV que apontem para a mesma coleção com
#   priority/action diferentes são silenciosamente ignoradas pela API. O
#   script valida isso e emite um aviso caso detecte valores divergentes
#   para a mesma coleção (coleções de tipos diferentes com o mesmo nome são
#   tratadas separadamente, pois ocupam "namespaces" distintos no Azure).
#
# ---------------------------------------------------------------------------
# FORMATO DO CSV (com cabeçalho obrigatório na primeira linha):
#
#   collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports,rule_type,translated_address,translated_port,target_fqdns,fqdn_tags
#
# As 8 primeiras colunas são as mesmas de versões anteriores deste script
# (CSVs antigos continuam funcionando sem alteração: rule_type vazio é
# tratado como "network"). As 5 últimas colunas são novas e só são usadas
# conforme o rule_type de cada linha; deixe-as em branco quando não se
# aplicarem.
#
# Campos comuns a todos os tipos:
#   - collection_name : nome da coleção de regras (criada automaticamente
#                        se ainda não existir)
#   - rule_name        : nome da regra
#   - priority         : número de 100 a 65000 (só tem efeito na 1ª regra
#                        que cria a coleção; opcional nas demais)
#   - rule_type        : network (padrão), nat ou application
#
# rule_type=network (regra de rede — Allow/Deny por IP/porta/protocolo):
#   - action                : Allow ou Deny (padrão: Allow)
#   - protocols             : Any, ICMP, TCP ou UDP, separados por ";"
#   - source_addresses      : IP(s)/CIDR de origem, separados por ";". "*" = qualquer origem
#   - destination_addresses : IP(s)/CIDR de destino, separados por ";"
#   - destination_ports     : porta(s) de destino, separadas por ";". "*" = qualquer porta
#   (translated_address, translated_port, target_fqdns, fqdn_tags: ignorados)
#
# rule_type=nat (DNAT — redireciona tráfego que chega no firewall para um
# endereço/porta internos):
#   - action                : sempre Dnat (pode deixar em branco)
#   - protocols             : TCP ou UDP, separados por ";" (não suporta Any/ICMP)
#   - source_addresses      : IP(s)/CIDR de origem, separados por ";"
#   - destination_addresses : endereço público/IP do firewall que recebe o tráfego
#   - destination_ports     : porta em que o tráfego chega
#   - translated_address    : endereço interno para onde o tráfego é traduzido
#   - translated_port       : porta interna para onde o tráfego é traduzido
#   (target_fqdns, fqdn_tags: ignorados)
#
# rule_type=application (regra de aplicação — Allow/Deny por FQDN):
#   - action           : Allow ou Deny (padrão: Allow)
#   - protocols        : pares "Protocolo=Porta" separados por ";", ex.: "Http=80;Https=443"
#                        (protocolos aceitos: Http, Https, Mssql)
#   - source_addresses : IP(s)/CIDR de origem, separados por ";"
#   - target_fqdns      : FQDN(s) de destino, separados por ";" (ex.: "www.contoso.com;*.contoso.net")
#   - fqdn_tags         : FQDN tag(s) do Azure, separadas por ";" (ex.: "WindowsUpdate")
#                        (pelo menos um entre target_fqdns e fqdn_tags é obrigatório)
#   (destination_addresses, destination_ports: ignorados — application rule não usa IP de destino)
#
# Exemplos de linha (uma de cada tipo):
#   Net-Coll01,Allow-DNS,200,Allow,UDP,10.0.2.0/24,168.63.129.16;8.8.8.8,53,network,,,,
#   Nat-Coll01,DNAT-RDP,210,,TCP,0.0.0.0/0,20.1.2.3,3389,nat,10.0.2.10,3389,,
#   App-Coll01,Allow-Web,220,Allow,Http=80;Https=443,10.0.2.0/24,,,application,,,www.microsoft.com;*.ubuntu.com,
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
# a mesma chamada para carregar as coleções/regras existentes (evita
# chamadas extras "az network firewall show" só para isso).
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
# Índice de idempotência: "tipo|collection_name|rule_name" -> 1 para toda
# regra já existente no firewall, nos três tipos de coleção.
# ---------------------------------------------------------------------------
declare -A EXISTING_RULES
while IFS=$'\t' read -r rtype coll rule; do
  [[ -z "$rtype" || -z "$coll" || -z "$rule" ]] && continue
  EXISTING_RULES["${rtype}|${coll}|${rule}"]=1
done < <(echo "$FIREWALL_JSON" | jq -r '
  ( (.networkRuleCollections // [])[]     | .name as $c | (.rules // [])[] | "network\t\($c)\t\(.name)" ),
  ( (.natRuleCollections // [])[]         | .name as $c | (.rules // [])[] | "nat\t\($c)\t\(.name)" ),
  ( (.applicationRuleCollections // [])[] | .name as $c | (.rules // [])[] | "application\t\($c)\t\(.name)" )
')
echo "Encontradas ${#EXISTING_RULES[@]} regra(s) já existente(s) no firewall (todos os tipos)."

TOTAL=0
OK=0
SKIPPED=0
FAIL=0
LINE_NUM=0
declare -A OK_BY_TYPE
declare -A SKIPPED_BY_TYPE
declare -A FAIL_BY_TYPE

trim() {
  local var="$1"
  var="${var#"${var%%[![:space:]]*}"}"
  var="${var%"${var##*[![:space:]]}"}"
  echo -n "$var"
}

# Conjuntos válidos (chave em maiúsculas -> valor "canônico" esperado pela API)
declare -A VALID_PROTOCOLS=( [ANY]="Any" [ICMP]="ICMP" [TCP]="TCP" [UDP]="UDP" )
declare -A VALID_ACTIONS=( [ALLOW]="Allow" [DENY]="Deny" )
declare -A VALID_APP_PROTOCOLS=( [HTTP]="Http" [HTTPS]="Https" [MSSQL]="Mssql" )

# Resumo legível dos campos da regra (linha atual), variando por rule_type.
# Usa as variáveis do laço principal diretamente (mesma shell, sem subshell).
format_rule_summary() {
  local d="tipo=$rule_type"
  case "$rule_type" in
    nat)
      d+=" action=${action:-Dnat} protocolo(s)=${protocols//;/, } origem=${source_addresses:-*}"
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

# ---------------------------------------------------------------------------
# Pré-checagem: avisa se o CSV define priority/action divergentes para a
# mesma coleção (a Azure só usa o valor da primeira regra que cria a
# coleção). Chave por tipo+coleção, já que coleções de tipos diferentes com
# o mesmo nome são recursos independentes no Azure.
# ---------------------------------------------------------------------------
declare -A COLL_ACTION_SEEN
declare -A COLL_PRIORITY_SEEN
_pre_line=0
while IFS=',' read -r pc_name _pr_name pc_priority pc_action _p1 _p2 _p3 _p4 pc_type _p5 _p6 _p7 _p8; do
  _pre_line=$((_pre_line + 1))
  [[ "$_pre_line" -eq 1 && "$pc_name" == "collection_name" ]] && continue
  [[ -z "$pc_name" || "$pc_name" =~ ^#.*$ ]] && continue

  pc_name=$(trim "$pc_name")
  pc_priority=$(trim "$pc_priority")
  pc_action=$(trim "$pc_action")
  pc_type=$(trim "$pc_type")
  [[ -z "$pc_type" ]] && pc_type="network"
  pc_key="${pc_type}|${pc_name}"

  if [[ -n "$pc_action" ]]; then
    prev="${COLL_ACTION_SEEN[$pc_key]:-}"
    if [[ -n "$prev" && "$prev" != "$pc_action" ]]; then
      echo "Aviso: a coleção '$pc_name' (tipo $pc_type) tem valores de 'action' divergentes no CSV ('$prev' e '$pc_action'). A Azure só usa a action definida na primeira regra que cria a coleção." >&2
    fi
    COLL_ACTION_SEEN[$pc_key]="$pc_action"
  fi

  if [[ -n "$pc_priority" ]]; then
    prev="${COLL_PRIORITY_SEEN[$pc_key]:-}"
    if [[ -n "$prev" && "$prev" != "$pc_priority" ]]; then
      echo "Aviso: a coleção '$pc_name' (tipo $pc_type) tem valores de 'priority' divergentes no CSV ('$prev' e '$pc_priority'). A Azure só usa a priority definida na primeira regra que cria a coleção." >&2
    fi
    COLL_PRIORITY_SEEN[$pc_key]="$pc_priority"
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

while IFS=',' read -r collection_name rule_name priority action protocols source_addresses destination_addresses destination_ports rule_type translated_address translated_port target_fqdns fqdn_tags; do
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
  rule_type=$(trim "$rule_type")
  translated_address=$(trim "$translated_address")
  translated_port=$(trim "$translated_port")
  target_fqdns=$(trim "$target_fqdns")
  fqdn_tags=$(trim "$fqdn_tags")

  if [[ -z "$collection_name" || -z "$rule_name" || -z "$protocols" ]]; then
    echo "[Linha $LINE_NUM] Ignorada: campos obrigatórios ausentes (collection_name, rule_name, protocols)."
    FAIL=$((FAIL + 1))
    continue
  fi

  # Normaliza/valida rule_type (compatível com CSVs antigos: em branco = network)
  if [[ -z "$rule_type" ]]; then
    rule_type="network"
  else
    rule_type="${rule_type,,}"
    case "$rule_type" in
      network|nat|application) ;;
      *)
        echo "[Linha $LINE_NUM] Ignorada: rule_type '$rule_type' inválido (use network, nat ou application)."
        FAIL=$((FAIL + 1))
        continue
        ;;
    esac
  fi

  # -------------------------------------------------------------------
  # Idempotência: se a regra já existe nesse tipo+coleção, pula sem
  # duplicar e sem sobrescrever.
  # -------------------------------------------------------------------
  rule_key="${rule_type}|${collection_name}|${rule_name}"
  if [[ -n "${EXISTING_RULES[$rule_key]:-}" ]]; then
    echo "[Linha $LINE_NUM] Regra '$rule_name' já existe na coleção '$collection_name' -> ignorada (idempotente)."
    echo "    Solicitado no CSV: $(format_rule_summary)"
    SKIPPED=$((SKIPPED + 1))
    SKIPPED_BY_TYPE[$rule_type]=$(( ${SKIPPED_BY_TYPE[$rule_type]:-0} + 1 ))
    continue
  fi

  # Valida priority (100 a 65000), se informado — comum aos três tipos
  if [[ -n "$priority" ]] && ! [[ "$priority" =~ ^[0-9]+$ && "$priority" -ge 100 && "$priority" -le 65000 ]]; then
    echo "[Linha $LINE_NUM] Ignorada: priority '$priority' inválida (deve ser um número entre 100 e 65000)."
    FAIL=$((FAIL + 1))
    FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
    continue
  fi

  source_list="${source_addresses//;/ }"
  CMD=()

  case "$rule_type" in

    network)
      if [[ -z "$destination_ports" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: rule_type=network exige destination_ports."
        FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
        continue
      fi

      if [[ -z "$action" ]]; then
        action="Allow"
      else
        action_key="${action^^}"
        if [[ -z "${VALID_ACTIONS[$action_key]:-}" ]]; then
          echo "[Linha $LINE_NUM] Ignorada: action '$action' inválida (use Allow ou Deny)."
          FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
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
        echo "[Linha $LINE_NUM] Ignorada: protocolo '$invalid_protocol' inválido para rule_type=network (use Any, ICMP, TCP ou UDP)."
        FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
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
        echo "[Linha $LINE_NUM] Ignorada: rule_type=nat exige destination_addresses, destination_ports, translated_address e translated_port."
        FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
        continue
      fi

      if [[ -n "$action" && "${action^^}" != "DNAT" ]]; then
        echo "[Linha $LINE_NUM] Ignorada: action '$action' inválida para rule_type=nat (a única action suportada é Dnat; deixe em branco)."
        FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
        continue
      fi
      action="Dnat"

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
        echo "[Linha $LINE_NUM] Ignorada: protocolo '$invalid_protocol' inválido para rule_type=nat (use TCP ou UDP)."
        FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
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
        echo "[Linha $LINE_NUM] Ignorada: rule_type=application exige target_fqdns e/ou fqdn_tags."
        FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
        continue
      fi

      if [[ -n "$destination_addresses" || -n "$destination_ports" ]]; then
        echo "[Linha $LINE_NUM] Aviso: destination_addresses/destination_ports são ignorados para rule_type=application."
      fi

      if [[ -z "$action" ]]; then
        action="Allow"
      else
        action_key="${action^^}"
        if [[ -z "${VALID_ACTIONS[$action_key]:-}" ]]; then
          echo "[Linha $LINE_NUM] Ignorada: action '$action' inválida (use Allow ou Deny)."
          FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
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
        echo "[Linha $LINE_NUM] Ignorada: protocolo '$invalid_protocol' inválido para rule_type=application (use o formato Protocolo=Porta, ex.: Http=80; protocolos aceitos: Http, Https, Mssql)."
        FAIL=$((FAIL + 1)); FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
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
    OK_BY_TYPE[$rule_type]=$(( ${OK_BY_TYPE[$rule_type]:-0} + 1 ))
    EXISTING_RULES["$rule_key"]=1
    continue
  fi

  if run_with_retry "${CMD[@]}" >/dev/null; then
    echo "  -> OK (regra '$rule_name' criada na coleção '$collection_name')"
    OK=$((OK + 1))
    OK_BY_TYPE[$rule_type]=$(( ${OK_BY_TYPE[$rule_type]:-0} + 1 ))
    EXISTING_RULES["$rule_key"]=1
  else
    echo "  -> FALHOU (regra '$rule_name' na coleção '$collection_name')"
    FAIL=$((FAIL + 1))
    FAIL_BY_TYPE[$rule_type]=$(( ${FAIL_BY_TYPE[$rule_type]:-0} + 1 ))
  fi

done < "$CSV_FILE"

echo
echo "Resumo: $TOTAL regra(s) processada(s), $OK criada(s), $SKIPPED já existente(s) (ignorada(s)), $FAIL com falha."
for t in network nat application; do
  t_total=$(( ${OK_BY_TYPE[$t]:-0} + ${SKIPPED_BY_TYPE[$t]:-0} + ${FAIL_BY_TYPE[$t]:-0} ))
  [[ "$t_total" -eq 0 ]] && continue
  echo "  - $t: ${OK_BY_TYPE[$t]:-0} criada(s), ${SKIPPED_BY_TYPE[$t]:-0} ignorada(s), ${FAIL_BY_TYPE[$t]:-0} com falha."
done

[[ "$FAIL" -gt 0 ]] && exit 1
exit 0
