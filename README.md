# criar_regras_firewall.sh

Script Bash para criar regras no **Azure Firewall** em lote, a partir de um
arquivo CSV, usando o Azure CLI. Feito para rodar no **Azure Cloud Shell**
(mas funciona em qualquer máquina com `az` e `jq` instalados).

Suporta os três tipos de regra do Azure Firewall "clássico" (sem Firewall
Policy):

| `rule_type`   | O que faz                                   | Comando do Azure CLI usado                    |
|---------------|----------------------------------------------|------------------------------------------------|
| `network`     | Allow/Deny por IP + porta + protocolo         | `az network firewall network-rule create`       |
| `nat`         | DNAT — redireciona tráfego de entrada         | `az network firewall nat-rule create`           |
| `application` | Allow/Deny por FQDN (domínio)                 | `az network firewall application-rule create`   |

**É idempotente**: pode rodar o mesmo CSV (ou um CSV incremental) quantas
vezes for preciso — regras que já existem no firewall são detectadas e
puladas, nunca duplicadas nem sobrescritas.

---

## Índice

- [Pré-requisitos](#pré-requisitos)
- [Uso rápido](#uso-rápido)
- [Como funciona](#como-funciona)
  - [Idempotência](#idempotência)
  - [Diagnóstico de sessão/erros](#diagnóstico-de-sessãoerros)
  - [Validações](#validações)
- [Formato do CSV](#formato-do-csv)
  - [Campos comuns](#campos-comuns-a-todos-os-tipos)
  - [`rule_type=network`](#rule_typenetwork)
  - [`rule_type=nat`](#rule_typenat-dnat)
  - [`rule_type=application`](#rule_typeapplication)
  - [Compatibilidade com CSVs antigos](#compatibilidade-com-csvs-antigos)
- [Exemplos](#exemplos)
- [Saída do script](#saída-do-script)
- [Códigos de saída](#códigos-de-saída)
- [Limitações conhecidas](#limitações-conhecidas)
- [Solução de problemas](#solução-de-problemas)

---

## Pré-requisitos

- **Azure CLI** (`az`) autenticado (`az login` já executado).
- **jq** (usado para ler a configuração atual do firewall e montar o índice
  de idempotência).

Ambos já vêm pré-instalados no **Azure Cloud Shell** — não é preciso
instalar nada lá.

O script também garante sozinho que a extensão `azure-firewall` do Azure
CLI está instalada/atualizada (`az extension add --name azure-firewall
--upgrade`).

## Uso rápido

```bash
chmod +x criar_regras_firewall.sh

# Ver o que seria feito, sem alterar nada (recomendado antes de rodar de verdade)
./criar_regras_firewall.sh -g meu-resource-group -f meu-firewall -c regras.csv -n

# Rodar de verdade
./criar_regras_firewall.sh -g meu-resource-group -f meu-firewall -c regras.csv

# Rodar de verdade e também gravar tudo em um arquivo de log
./criar_regras_firewall.sh -g meu-resource-group -f meu-firewall -c regras.csv -l execucao.log
```

| Opção | Obrigatória | Descrição |
|-------|-------------|-----------|
| `-g <resource-group>` | sim | Resource group onde está o Azure Firewall |
| `-f <firewall-name>`  | sim | Nome do Azure Firewall |
| `-c <arquivo.csv>`    | sim | Caminho do CSV com as regras |
| `-n`                  | não | **Dry-run**: mostra o que seria feito, sem chamar a API |
| `-l <log-file>`       | não | Grava toda a saída também neste arquivo (além da tela) |
| `-h`                  | não | Mostra a ajuda |

## Como funciona

1. Valida os parâmetros da linha de comando e a existência do CSV.
2. Confere se `az` e `jq` estão instalados.
3. Confere a sessão do Azure CLI (veja [Diagnóstico de sessão](#diagnóstico-de-sessãoerros)).
4. Garante a extensão `azure-firewall` instalada.
5. Consulta o firewall informado (`az network firewall show`) — essa mesma
   chamada é reaproveitada para: (a) confirmar que o firewall existe e (b)
   carregar todas as regras já cadastradas nele (network, NAT e
   application), montando um índice em memória.
6. Faz uma pré-varredura do CSV avisando se a mesma coleção aparece com
   `priority`/`action` divergentes entre linhas (ver nota abaixo).
7. Processa o CSV linha a linha: valida os campos, verifica se a regra já
   existe (idempotência) e, se não existir, monta e executa o comando
   `az network firewall <tipo>-rule create` correspondente.
8. Ao final, imprime um resumo com totais gerais e por tipo de regra.

### Idempotência

Antes de criar qualquer regra, o script já carregou (passo 5 acima) todas
as regras existentes no firewall, indexadas por
`tipo_de_regra|nome_da_coleção|nome_da_regra`.

Para cada linha do CSV, se essa combinação já existir no firewall, a linha
é **pulada** — o script nunca chama `create` para uma regra que já existe,
então **nunca duplica e nunca sobrescreve** uma regra existente, mesmo que
os demais campos da linha (protocolo, portas, IPs etc.) sejam diferentes do
que está hoje no Azure.

> Se você precisa *alterar* uma regra que já existe, isso é proposital e
> tem que ser feito fora deste script (por exemplo com o comando
> `az network firewall <tipo>-rule update` correspondente, ou apagando a
> regra antes de rodar o script de novo). O script avisa que a regra já
> existe e mostra o que estava pedindo no CSV, para facilitar comparar
> manualmente:
>
> ```
> [Linha 4] Regra 'Allow-DNS' já existe na coleção 'Net-Coll01' -> ignorada (idempotente).
>     Solicitado no CSV: tipo=network action=Allow protocolo(s)=UDP origem=10.0.2.0/24 destino=168.63.129.16 porta(s)=53 priority=200
> ```

Isso também significa que o script pode ser executado várias vezes com o
mesmo CSV (por exemplo, numa esteira de CI/CD ou reexecutado manualmente
depois de uma falha) sem medo de duplicar nada — regras já criadas em uma
execução anterior simplesmente são puladas nas execuções seguintes.

**Sobre `priority` e `action`**: no Azure Firewall clássico, esses dois
campos pertencem à *coleção* de regras, não à regra individual — só têm
efeito na primeira regra que cria a coleção. Se o CSV tiver linhas
diferentes para a mesma coleção com `priority`/`action` diferentes, o
script detecta isso na pré-varredura e emite um aviso (não bloqueia a
execução, é só um alerta para você não ser pego de surpresa por um valor
que a Azure ignorou silenciosamente):

```
Aviso: a coleção 'Net-Coll01' (tipo network) tem valores de 'action' divergentes no CSV ('Allow' e 'Deny'). A Azure só usa a action definida na primeira regra que cria a coleção.
```

### Diagnóstico de sessão/erros

Um dos objetivos deste script é nunca deixar você adivinhando "por que
falhou". Por isso ele faz três níveis de checagem, cada um com mensagem
específica:

1. **Antes de começar** — `az account show` sozinho só lê o cache local
   (`~/.azure`) e pode "passar" mesmo com o token de atualização expirado.
   O script complementa isso com `az account get-access-token`, que força
   uma renovação de token de verdade junto ao Azure AD. Se a sessão caiu,
   você vê isso *antes* de qualquer tentativa de mexer no firewall:

   ```
   Erro: sua sessão do Azure CLI expirou ou é inválida. Execute 'az login' novamente antes de continuar.
   Detalhe retornado pelo Azure CLI: ERROR: AADSTS700082: The refresh token has expired due to inactivity.
   ```

2. **Ao consultar o firewall** — o erro devolvido por `az network firewall
   show` é interpretado e reportado de forma específica: sessão expirada,
   resource group não encontrado, firewall não encontrado, ou erro
   genérico (nesse último caso, o texto original do Azure CLI é sempre
   mostrado, nunca descartado):

   ```
   Erro: o resource group 'rg-producao' não foi encontrado (ou você não tem permissão para acessá-lo).
   Detalhe retornado pelo Azure CLI: ERROR: (ResourceGroupNotFound) Resource group 'rg-producao' could not be found.
   ```

3. **Durante o processamento do CSV** — se a sessão expirar no meio da
   execução (comum em CSVs grandes, já que um token dura cerca de 1 hora),
   o script reconhece o padrão do erro e **aborta imediatamente** com uma
   mensagem clara, em vez de continuar tentando criar as regras seguintes
   e reportando "FALHOU" em cada uma delas sem dizer por quê:

   ```
   Erro fatal: a sessão do Azure CLI expirou/ficou inválida durante a execução (linha 138, regra 'Allow-Web-42').
   Execute 'az login' novamente e rode o script mais uma vez: as regras já criadas não serão duplicadas (o script é idempotente).
   ```

   Graças à idempotência, a recomendação nesse caso é sempre a mesma:
   rodar `az login` e executar o script de novo com o mesmo CSV — nada do
   que já foi criado será duplicado.

Falhas que **não** são de sessão (ex.: conflito temporário do Azure
Firewall, como `AnotherOperationInProgress`) são tratadas de forma
diferente: o script tenta de novo automaticamente até 3 vezes, com
espera crescente (5s, 10s, 20s), antes de marcar a linha como `FALHOU` e
seguir para a próxima.

### Validações

Antes de chamar a API, o script valida (e rejeita com mensagem clara,
contando a linha como falha, sem interromper o restante do CSV):

- Campos obrigatórios ausentes (`collection_name`, `rule_name`, `protocols`
  sempre; os demais variam por `rule_type` — veja a seção do CSV abaixo).
- `rule_type` inválido (só aceita `network`, `nat` ou `application`).
- `priority` fora da faixa 100–65000.
- `action` inválida (`Allow`/`Deny`, ou `Dnat` no caso de `nat`).
- `protocols` com valor não suportado pelo tipo da regra (por exemplo,
  `ICMP` não é aceito em `nat`; o formato de `application` tem que ser
  `Protocolo=Porta`).
- Campos específicos obrigatórios por tipo (ex.: `nat` exige
  `translated_address` e `translated_port`; `application` exige
  `target_fqdns` e/ou `fqdn_tags`).

Letras minúsculas/maiúsculas em `action` e `protocols` são normalizadas
automaticamente (ex.: `allow`, `tcp` viram `Allow`, `TCP`).

## Formato do CSV

A primeira linha deve ser o cabeçalho, exatamente com estes nomes de
coluna, nesta ordem:

```
collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports,rule_type,translated_address,translated_port,target_fqdns,fqdn_tags
```

Linhas em branco e linhas começando com `#` são ignoradas (podem ser usadas
como comentário no meio do arquivo).

### Campos comuns a todos os tipos

| Coluna | Obrigatório | Descrição |
|---|---|---|
| `collection_name` | sim | Nome da coleção de regras. Criada automaticamente se ainda não existir. |
| `rule_name` | sim | Nome da regra. |
| `priority` | não | Número de 100 a 65000. Só tem efeito na 1ª regra que cria a coleção. |
| `rule_type` | não | `network` (padrão se vazio), `nat` ou `application`. |

### `rule_type=network`

Regra de rede: Allow/Deny por IP + porta + protocolo.

| Coluna | Obrigatório | Descrição |
|---|---|---|
| `action` | não (padrão `Allow`) | `Allow` ou `Deny`. |
| `protocols` | sim | `Any`, `ICMP`, `TCP` ou `UDP`, separados por `;`. |
| `source_addresses` | não | IP(s)/CIDR de origem, separados por `;`. `*` = qualquer origem. |
| `destination_addresses` | não | IP(s)/CIDR de destino, separados por `;`. |
| `destination_ports` | sim | Porta(s) de destino, separadas por `;`. `*` = qualquer porta. |

Colunas `translated_address`, `translated_port`, `target_fqdns`,
`fqdn_tags`: **ignoradas** para esse tipo, deixe em branco.

### `rule_type=nat` (DNAT)

Redireciona tráfego que chega no firewall para um endereço/porta internos.

| Coluna | Obrigatório | Descrição |
|---|---|---|
| `action` | não | Sempre `Dnat` — pode deixar em branco. |
| `protocols` | sim | `TCP` ou `UDP`, separados por `;` (**não** aceita `Any`/`ICMP`). |
| `source_addresses` | não | IP(s)/CIDR de origem, separados por `;`. |
| `destination_addresses` | sim | Endereço público/IP do firewall que recebe o tráfego. |
| `destination_ports` | sim | Porta em que o tráfego chega. |
| `translated_address` | sim | Endereço interno para onde o tráfego é traduzido. |
| `translated_port` | sim | Porta interna para onde o tráfego é traduzido. |

Colunas `target_fqdns`, `fqdn_tags`: **ignoradas**, deixe em branco.

### `rule_type=application`

Regra de aplicação: Allow/Deny por FQDN (domínio).

| Coluna | Obrigatório | Descrição |
|---|---|---|
| `action` | não (padrão `Allow`) | `Allow` ou `Deny`. |
| `protocols` | sim | Pares `Protocolo=Porta` separados por `;`, ex.: `Http=80;Https=443`. Protocolos aceitos: `Http`, `Https`, `Mssql`. |
| `source_addresses` | não | IP(s)/CIDR de origem, separados por `;`. |
| `target_fqdns` | condicional | FQDN(s) de destino, separados por `;` (ex.: `www.contoso.com;*.contoso.net`). |
| `fqdn_tags` | condicional | FQDN tag(s) do Azure, separadas por `;` (ex.: `WindowsUpdate`). |

Pelo menos um entre `target_fqdns` e `fqdn_tags` é obrigatório.

Colunas `destination_addresses`, `destination_ports`: **ignoradas** (uma
application rule não usa IP de destino — só FQDN).

### Compatibilidade com CSVs antigos

Se você já tinha um CSV só com as 8 primeiras colunas (versão anterior
deste script, só com `network-rule`), ele continua funcionando **sem
nenhuma alteração**: `rule_type` vazio é tratado como `network`, e as
colunas novas simplesmente não existirão nas linhas lidas (ficam vazias).

## Exemplos

Um exemplo com uma regra de cada tipo:

```csv
collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports,rule_type,translated_address,translated_port,target_fqdns,fqdn_tags
Net-Coll01,Allow-DNS,200,Allow,UDP,10.0.2.0/24,168.63.129.16;8.8.8.8,53,network,,,,
Nat-Coll01,DNAT-RDP,210,,TCP,0.0.0.0/0,20.1.2.3,3389,nat,10.0.2.10,3389,,
App-Coll01,Allow-Web,220,Allow,Http=80;Https=443,10.0.2.0/24,,,application,,,www.microsoft.com;*.ubuntu.com,
```

Rodando em dry-run para conferir os comandos antes de aplicar:

```bash
./criar_regras_firewall.sh -g rg-rede -f fw-prod -c regras.csv -n
```

Saída (resumida):

```
Consultando o Azure Firewall 'fw-prod'...
Encontradas 12 regra(s) já existente(s) no firewall (todos os tipos).
[Linha 2] Criando regra 'Allow-DNS' na coleção 'Net-Coll01': tipo=network action=Allow protocolo(s)=UDP origem=10.0.2.0/24 destino=168.63.129.16, 8.8.8.8 porta(s)=53 priority=200
    comando: az network firewall network-rule create --resource-group rg-rede --firewall-name fw-prod --collection-name Net-Coll01 --name Allow-DNS --protocols UDP --destination-ports 53 --action Allow --only-show-errors --priority 200 --source-addresses 10.0.2.0/24 --destination-addresses 168.63.129.16 8.8.8.8
...
Resumo: 3 regra(s) processada(s), 3 criada(s), 0 já existente(s) (ignorada(s)), 0 com falha.
  - network: 1 criada(s), 0 ignorada(s), 0 com falha.
  - nat: 1 criada(s), 0 ignorada(s), 0 com falha.
  - application: 1 criada(s), 0 ignorada(s), 0 com falha.
```

Depois de conferir, rodar de verdade (mesmo CSV, sem `-n`):

```bash
./criar_regras_firewall.sh -g rg-rede -f fw-prod -c regras.csv -l /tmp/regras-$(date +%F).log
```

Rodar de novo o **mesmo comando** depois é seguro — as 3 regras já criadas
aparecerão como "já existe -> ignorada" e nada será duplicado.

## Saída do script

Para cada linha do CSV processada, uma destas mensagens aparece:

| Mensagem | Significado |
|---|---|
| `Criando regra 'X' na coleção 'Y': ...` seguido de `-> OK` | Regra criada com sucesso (mostra os campos usados). |
| `Regra 'X' já existe na coleção 'Y' -> ignorada (idempotente)` | Regra já existia; nada foi alterado. Mostra o que o CSV pedia, para comparação manual. |
| `Ignorada: ...` | Linha inválida (campo obrigatório faltando, valor fora do permitido). Não chega a chamar a API. |
| `Aviso: ...` | Não impede o processamento; alerta sobre `priority`/`action` divergente na coleção, ou campo ignorado para o tipo da regra. |
| `-> FALHOU` | A chamada à API falhou mesmo após as tentativas automáticas (erro que não é de sessão expirada). |
| `Erro fatal: a sessão do Azure CLI expirou...` | Sessão caiu no meio da execução — o script aborta imediatamente. |

Ao final, um resumo com totais gerais e por tipo de regra:

```
Resumo: 40 regra(s) processada(s), 35 criada(s), 4 já existente(s) (ignorada(s)), 1 com falha.
  - network: 30 criada(s), 3 ignorada(s), 1 com falha.
  - nat: 3 criada(s), 1 ignorada(s), 0 com falha.
  - application: 2 criada(s), 0 ignorada(s), 0 com falha.
```

## Códigos de saída

| Código | Significado |
|---|---|
| `0` | Tudo certo — nenhuma linha falhou (linhas puladas por já existirem não contam como falha). |
| `1` | Erro de pré-requisito/validação inicial (parâmetros, CSV ausente, `az`/`jq` ausentes, sessão expirada, firewall não encontrado), sessão expirada no meio da execução, **ou** pelo menos uma linha do CSV falhou ao ser processada. |

Use o código de saída para decidir se uma esteira de CI/CD deve considerar
a execução bem-sucedida.

## Limitações conhecidas

- Não interpreta CSV com campos entre aspas contendo vírgulas — cada
  vírgula é tratada como separador de coluna. Não use vírgulas dentro de
  um valor de campo.
- Não oferece suporte a `destination_fqdns`/`destination_ip_groups` em
  network rules, nem a `translated_fqdn` em NAT rules (variantes menos
  comuns da API que a Azure também aceita).
- Regras que já existem nunca são atualizadas por este script, mesmo que
  os campos no CSV sejam diferentes dos valores atuais — isso é
  proposital (idempotência "não sobrescreve"), mas significa que
  atualizar uma regra existente é uma operação manual, fora daqui.
- Roda as chamadas ao Azure Firewall sequencialmente (uma regra por vez).
  Cada `create` faz um GET+PUT do recurso inteiro do firewall, então CSVs
  muito grandes podem demorar — o retry com backoff ajuda com falhas
  transitórias, mas não paraleliza as chamadas.

## Solução de problemas

**"Erro: você não está autenticado no Azure CLI"**
Rode `az login` (no Cloud Shell isso normalmente já está feito
automaticamente ao abrir a sessão).

**"Erro: sua sessão do Azure CLI expirou ou é inválida"**
Rode `az login` novamente e execute o script de novo com o mesmo CSV —
regras já criadas não serão duplicadas.

**"Erro: o resource group 'X' não foi encontrado"**
Confira o nome do resource group (`-g`) e se a conta logada tem permissão
para ler recursos nele (`az group show -n X`).

**"Erro: firewall 'X' não encontrado no resource group 'Y'"**
Confira o nome do firewall (`-f`) e o resource group (`az network firewall
list -g Y -o table`).

**Uma linha específica sempre falha com `-> FALHOU`**
Rode com `-n` (dry-run) para ver o comando `az` exato que seria executado
com aquela linha, e rode esse comando manualmente para ver o erro completo
do Azure CLI (o script já imprime o erro cru quando a causa não é
reconhecida, mas o dry-run ajuda a isolar o problema).

**Uma regra que eu esperava que fosse criada aparece como "já existe -> ignorada"**
Confira se você não está reaproveitando sem querer um `rule_name` que já
existe em outra coleção do mesmo tipo com conteúdo diferente — o script só
compara por nome (tipo + coleção + regra), não pelo conteúdo da regra.
