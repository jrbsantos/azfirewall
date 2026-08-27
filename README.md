# criar_regras_firewall.sh

Script Bash para criar regras no **Azure Firewall** em lote, a partir de um
arquivo CSV, usando o Azure CLI. Feito para rodar no **Azure Cloud Shell**
(mas funciona em qualquer máquina com `az` e `jq` instalados).

Suporta os três tipos de regra do Azure Firewall "clássico" (sem Firewall
Policy), escolhido pela opção **`-t`** — cada tipo tem seu **próprio
formato de CSV**, enxuto, só com as colunas que fazem sentido para ele:

| `-t`          | O que faz                                   | Comando do Azure CLI usado                    |
|---------------|----------------------------------------------|------------------------------------------------|
| `network`     | Allow/Deny por IP + porta + protocolo         | `az network firewall network-rule create`       |
| `nat`         | DNAT — redireciona tráfego de entrada         | `az network firewall nat-rule create`           |
| `application` | Allow/Deny por FQDN (domínio)                 | `az network firewall application-rule create`   |

**É idempotente**: pode rodar o mesmo CSV (ou um CSV incremental) quantas
vezes for preciso — regras que já existem no firewall são detectadas e
puladas, nunca duplicadas nem sobrescritas.

> **Por que um CSV diferente por tipo de regra?** As três regras têm campos
> bem diferentes entre si (só NAT tem `translated_address`/`translated_port`;
> só Application tem `target_fqdns`). Um CSV único com todas as colunas de
> todos os tipos obrigaria a deixar várias células em branco em toda linha
> — fácil de errar ao preencher manualmente. Por isso cada `-t` tem seu
> próprio formato de CSV, e uma execução do script sempre lida com um tipo
> por vez.

---

## Índice

- [Pré-requisitos](#pré-requisitos)
- [Uso rápido](#uso-rápido)
- [Como funciona](#como-funciona)
  - [Idempotência](#idempotência)
  - [Diagnóstico de sessão/erros](#diagnóstico-de-sessãoerros)
  - [Validações](#validações)
- [Formato do CSV](#formato-do-csv)
  - [`-t network`](#-t-network)
  - [`-t nat` (DNAT)](#-t-nat-dnat)
  - [`-t application`](#-t-application)
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
./criar_regras_firewall.sh -g meu-resource-group -f meu-firewall -t network -c network.csv -n

# Rodar de verdade
./criar_regras_firewall.sh -g meu-resource-group -f meu-firewall -t network -c network.csv

# Regras NAT (DNAT), outro CSV, mesmo firewall
./criar_regras_firewall.sh -g meu-resource-group -f meu-firewall -t nat -c nat.csv

# Regras de aplicação (FQDN), e grava tudo em um log
./criar_regras_firewall.sh -g meu-resource-group -f meu-firewall -t application -c application.csv -l execucao.log
```

| Opção | Obrigatória | Descrição |
|-------|-------------|-----------|
| `-g <resource-group>` | sim | Resource group onde está o Azure Firewall |
| `-f <firewall-name>`  | sim | Nome do Azure Firewall |
| `-t <tipo>`           | sim | Tipo de regra do CSV: `network`, `nat` ou `application` |
| `-c <arquivo.csv>`    | sim | Caminho do CSV com as regras, no formato do `-t` escolhido |
| `-n`                  | não | **Dry-run**: mostra o que seria feito, sem chamar a API |
| `-l <log-file>`       | não | Grava toda a saída também neste arquivo (além da tela) |
| `-h`                  | não | Mostra a ajuda |

Para criar os três tipos de regra no mesmo firewall, rode o script três
vezes, uma para cada `-t`, cada uma com seu próprio CSV.

## Como funciona

1. Valida os parâmetros da linha de comando, incluindo o `-t` escolhido.
2. Valida se o **cabeçalho do CSV** bate exatamente com o esperado para
   esse `-t` — isso pega de imediato um CSV no formato errado (por
   exemplo, apontar sem querer um CSV de NAT enquanto roda com
   `-t network`), antes de qualquer chamada ao Azure.
3. Confere se `az` e `jq` estão instalados.
4. Confere a sessão do Azure CLI (veja [Diagnóstico de sessão](#diagnóstico-de-sessãoerros)).
5. Garante a extensão `azure-firewall` instalada.
6. Consulta o firewall informado (`az network firewall show`) — essa mesma
   chamada é reaproveitada para: (a) confirmar que o firewall existe e (b)
   carregar todas as regras do tipo escolhido já cadastradas nele, montando
   um índice em memória.
7. Faz uma pré-varredura do CSV avisando se a mesma coleção aparece com
   `priority`/`action` divergentes entre linhas (ver nota abaixo).
8. Processa o CSV linha a linha: confere o número de campos, valida os
   valores, verifica se a regra já existe (idempotência) e, se não
   existir, monta e executa o comando `az network firewall <tipo>-rule
   create` correspondente.
9. Ao final, imprime um resumo com os totais da execução.

### Idempotência

Antes de criar qualquer regra, o script já carregou (passo 6 acima) todas
as regras do tipo escolhido existentes no firewall, indexadas por
`nome_da_coleção|nome_da_regra`.

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
Aviso: a coleção 'Net-Coll01' tem valores de 'action' divergentes no CSV ('Allow' e 'Deny'). A Azure só usa a action definida na primeira regra que cria a coleção.
```

(No formato `-t nat` não existe coluna `action` — a action de uma regra NAT
é sempre `Dnat` — então esse aviso específico só se aplica a `network` e
`application`.)

### Diagnóstico de sessão/erros

Um dos objetivos deste script é nunca deixar você adivinhando "por que
falhou". Por isso ele faz várias checagens, cada uma com mensagem
específica:

0. **Formato do CSV** — antes de tocar no Azure, o script confere se o
   cabeçalho do CSV bate com o esperado para o `-t` escolhido, e se cada
   linha de dados tem exatamente o número de colunas esperado. Uma vírgula
   a mais ou a menos numa linha não passa despercebida nem desalinha
   silenciosamente os campos — o script recusa a linha (ou o arquivo
   inteiro, no caso do cabeçalho) com uma mensagem específica:

   ```
   [Linha 5] Ignorada: número de campos incorreto (esperado 8 para -t network, encontrado 7) — confira as vírgulas da linha.
   ```

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

- Cabeçalho do CSV incompatível com o `-t` escolhido (aborta a execução
  inteira, antes de processar qualquer linha).
- Número de campos da linha diferente do esperado para o `-t` escolhido.
- Campos obrigatórios ausentes (`collection_name`, `rule_name`,
  `protocols` sempre; os demais variam por tipo — veja a seção do CSV
  abaixo).
- `priority` fora da faixa 100–65000.
- `action` inválida (`Allow`/`Deny`; não existe coluna `action` no formato
  `nat`, a action já é sempre `Dnat`).
- `protocols` com valor não suportado pelo tipo da regra (por exemplo,
  `ICMP` não é aceito em `nat`; o formato de `application` tem que ser
  `Protocolo=Porta`).
- Campos específicos obrigatórios por tipo (ex.: `nat` exige
  `translated_address` e `translated_port`; `application` exige
  `target_fqdns` e/ou `fqdn_tags`).

Letras minúsculas/maiúsculas em `action` e `protocols` são normalizadas
automaticamente (ex.: `allow`, `tcp` viram `Allow`, `TCP`).

## Formato do CSV

A primeira linha deve ser exatamente o cabeçalho abaixo (nessa ordem) para
o `-t` escolhido — o script recusa a execução se não bater. Linhas em
branco e linhas começando com `#` são ignoradas (podem ser usadas como
comentário no meio do arquivo).

### `-t network`

Regra de rede: Allow/Deny por IP + porta + protocolo.

```
collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports
```

| Coluna | Obrigatório | Descrição |
|---|---|---|
| `collection_name` | sim | Nome da coleção de regras. Criada automaticamente se ainda não existir. |
| `rule_name` | sim | Nome da regra. |
| `priority` | não | Número de 100 a 65000. Só tem efeito na 1ª regra que cria a coleção. |
| `action` | não (padrão `Allow`) | `Allow` ou `Deny`. |
| `protocols` | sim | `Any`, `ICMP`, `TCP` ou `UDP`, separados por `;`. |
| `source_addresses` | não | IP(s)/CIDR de origem, separados por `;`. `*` = qualquer origem. |
| `destination_addresses` | não | IP(s)/CIDR de destino, separados por `;`. |
| `destination_ports` | sim | Porta(s) de destino, separadas por `;`. `*` = qualquer porta. |

Exemplo:
```csv
collection_name,rule_name,priority,action,protocols,source_addresses,destination_addresses,destination_ports
Net-Coll01,Allow-DNS,200,Allow,UDP,10.0.2.0/24,168.63.129.16;8.8.8.8,53
Net-Coll01,Allow-HTTP,200,Allow,TCP,10.0.2.0/24,8.8.8.8,80
```

### `-t nat` (DNAT)

Redireciona tráfego que chega no firewall para um endereço/porta internos.
Não tem coluna `action` — a action de uma NAT rule é sempre `Dnat`.

```
collection_name,rule_name,priority,protocols,source_addresses,destination_addresses,destination_ports,translated_address,translated_port
```

| Coluna | Obrigatório | Descrição |
|---|---|---|
| `collection_name` | sim | Nome da coleção. |
| `rule_name` | sim | Nome da regra. |
| `priority` | não | Número de 100 a 65000. Só tem efeito na 1ª regra que cria a coleção. |
| `protocols` | sim | `TCP` ou `UDP`, separados por `;` (**não** aceita `Any`/`ICMP`). |
| `source_addresses` | não | IP(s)/CIDR de origem, separados por `;`. |
| `destination_addresses` | sim | Endereço público/IP do firewall que recebe o tráfego. |
| `destination_ports` | sim | Porta em que o tráfego chega. |
| `translated_address` | sim | Endereço interno para onde o tráfego é traduzido. |
| `translated_port` | sim | Porta interna para onde o tráfego é traduzido. |

Exemplo:
```csv
collection_name,rule_name,priority,protocols,source_addresses,destination_addresses,destination_ports,translated_address,translated_port
Nat-Coll01,DNAT-RDP,210,TCP,0.0.0.0/0,20.1.2.3,3389,10.0.2.10,3389
Nat-Coll01,DNAT-SSH,210,TCP,0.0.0.0/0,20.1.2.3,2222,10.0.2.11,22
```

### `-t application`

Regra de aplicação: Allow/Deny por FQDN (domínio). Não tem colunas
`destination_addresses`/`destination_ports` — uma application rule não usa
IP de destino, só FQDN.

```
collection_name,rule_name,priority,action,protocols,source_addresses,target_fqdns,fqdn_tags
```

| Coluna | Obrigatório | Descrição |
|---|---|---|
| `collection_name` | sim | Nome da coleção. |
| `rule_name` | sim | Nome da regra. |
| `priority` | não | Número de 100 a 65000. Só tem efeito na 1ª regra que cria a coleção. |
| `action` | não (padrão `Allow`) | `Allow` ou `Deny`. |
| `protocols` | sim | Pares `Protocolo=Porta` separados por `;`, ex.: `Http=80;Https=443`. Protocolos aceitos: `Http`, `Https`, `Mssql`. |
| `source_addresses` | não | IP(s)/CIDR de origem, separados por `;`. |
| `target_fqdns` | condicional | FQDN(s) de destino, separados por `;` (ex.: `www.contoso.com;*.contoso.net`). |
| `fqdn_tags` | condicional | FQDN tag(s) do Azure, separadas por `;` (ex.: `WindowsUpdate`). |

Pelo menos um entre `target_fqdns` e `fqdn_tags` é obrigatório (o outro
pode ficar em branco, mas a coluna precisa existir na linha — veja o
exemplo abaixo).

Exemplo:
```csv
collection_name,rule_name,priority,action,protocols,source_addresses,target_fqdns,fqdn_tags
App-Coll01,Allow-Web,220,Allow,Https=443,10.0.2.0/24,www.microsoft.com,
App-Coll01,Allow-Update,220,Allow,Http=80;Https=443,10.0.2.0/24,,WindowsUpdate
```

## Exemplos

Rodando em dry-run para conferir os comandos antes de aplicar:

```bash
./criar_regras_firewall.sh -g rg-rede -f fw-prod -t network -c network.csv -n
```

Saída (resumida):

```
Consultando o Azure Firewall 'fw-prod'...
Encontradas 10 regra(s) do tipo 'network' já existente(s) no firewall.
[Linha 2] Criando regra 'Allow-DNS' na coleção 'Net-Coll01': tipo=network action=Allow protocolo(s)=UDP origem=10.0.2.0/24 destino=168.63.129.16, 8.8.8.8 porta(s)=53 priority=200
    comando: az network firewall network-rule create --resource-group rg-rede --firewall-name fw-prod --collection-name Net-Coll01 --name Allow-DNS --protocols UDP --destination-ports 53 --action Allow --only-show-errors --priority 200 --source-addresses 10.0.2.0/24 --destination-addresses 168.63.129.16 8.8.8.8
...
Resumo (rule_type=network): 2 regra(s) processada(s), 2 criada(s), 0 já existente(s) (ignorada(s)), 0 com falha.
```

Depois de conferir, rodar de verdade (mesmo CSV, sem `-n`), gravando um log:

```bash
./criar_regras_firewall.sh -g rg-rede -f fw-prod -t network -c network.csv -l /tmp/network-$(date +%F).log
```

Rodar de novo o **mesmo comando** depois é seguro — as regras já criadas
aparecerão como "já existe -> ignorada" e nada será duplicado.

Para os outros tipos, é o mesmo padrão, trocando `-t` e o CSV:

```bash
./criar_regras_firewall.sh -g rg-rede -f fw-prod -t nat -c nat.csv -n
./criar_regras_firewall.sh -g rg-rede -f fw-prod -t application -c application.csv -n
```

## Saída do script

Para cada linha do CSV processada, uma destas mensagens aparece:

| Mensagem | Significado |
|---|---|
| `Criando regra 'X' na coleção 'Y': ...` seguido de `-> OK` | Regra criada com sucesso (mostra os campos usados). |
| `Regra 'X' já existe na coleção 'Y' -> ignorada (idempotente)` | Regra já existia; nada foi alterado. Mostra o que o CSV pedia, para comparação manual. |
| `Ignorada: ...` | Linha inválida (campo obrigatório faltando, número de colunas errado, valor fora do permitido). Não chega a chamar a API. |
| `Aviso: ...` | Não impede o processamento; alerta sobre `priority`/`action` divergente na coleção. |
| `-> FALHOU` | A chamada à API falhou mesmo após as tentativas automáticas (erro que não é de sessão expirada). |
| `Erro fatal: a sessão do Azure CLI expirou...` | Sessão caiu no meio da execução — o script aborta imediatamente. |

Ao final, um resumo:

```
Resumo (rule_type=network): 40 regra(s) processada(s), 35 criada(s), 4 já existente(s) (ignorada(s)), 1 com falha.
```

## Códigos de saída

| Código | Significado |
|---|---|
| `0` | Tudo certo — nenhuma linha falhou (linhas puladas por já existirem não contam como falha). |
| `1` | Erro de pré-requisito/validação inicial (parâmetros, `-t` inválido, cabeçalho do CSV incompatível, CSV ausente, `az`/`jq` ausentes, sessão expirada, firewall não encontrado), sessão expirada no meio da execução, **ou** pelo menos uma linha do CSV falhou ao ser processada. |

Use o código de saída para decidir se uma esteira de CI/CD deve considerar
a execução bem-sucedida.

## Limitações conhecidas

- Não interpreta CSV com campos entre aspas contendo vírgulas — cada
  vírgula é tratada como separador de coluna. Não use vírgulas dentro de
  um valor de campo. Uma vírgula a mais ou a menos é detectada (o script
  confere o número de campos por linha), mas o conteúdo continuará
  incorreto se a vírgula estiver dentro de um valor.
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
- Para criar regras dos três tipos no mesmo firewall, é preciso rodar o
  script três vezes (uma por `-t`), cada uma com seu próprio CSV.

## Solução de problemas

**"Erro: -t deve ser 'network', 'nat' ou 'application'"**
Confira o valor passado em `-t` — tem que ser exatamente um desses três
(minúsculo ou maiúsculo, o script normaliza).

**"Erro: cabeçalho do CSV não confere com o esperado para -t X"**
O CSV apontado em `-c` não é do formato esperado para o `-t` escolhido —
confira se não trocou o arquivo (ex.: apontou um CSV de NAT rodando com
`-t network`) ou se o cabeçalho da primeira linha está exatamente como
documentado na seção [Formato do CSV](#formato-do-csv).

**"Ignorada: número de campos incorreto..."**
Sobrou ou faltou uma vírgula naquela linha do CSV. Abra o arquivo num
editor de texto simples (não só no Excel) para conferir se a linha tem
exatamente o número de vírgulas esperado para o tipo de regra.

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
compara por nome (coleção + regra), não pelo conteúdo da regra.
