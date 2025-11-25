# 🪙 KeyCoin (KCN) Smart Contract: ICO com Lógica de Valorização Automática

## 🌟 Visão Geral do Projeto

Este projeto demonstra a construção de um Smart Contract robusto para uma **Initial Coin Offering (ICO)** do token KeyCoin (`KCN`) na Ethereum Virtual Machine (EVM). O foco principal está na **segurança de nível industrial** (utilizando padrões OpenZeppelin) e na implementação de uma **Tokenomics financeira complexa** com preço crescente e adição automática de liquidez.

O contrato **KeyCoin** é o resultado de um desafio prático de desenvolvimento em Solidity, validando funcionalidades críticas contra falhas de segurança e lógica de negócio.

---

## 🛡️ Principais Camadas de Segurança e Funcionalidade

O contrato herda e implementa os modificadores e padrões mais seguros para garantir a integridade da venda.

| Recurso | Tipo | Detalhamento |
| :--- | :--- | :--- |
| **Padrão Token** | `ERC-20` / `ERC-20Burnable` | Totalmente compatível com o ecossistema EVM e permite que o Owner queime tokens não vendidos. |
| **Controle de Fluxo** | `ReentrancyGuard` | Impede chamadas externas reentrantes (especialmente em `buyTokens` e `withdrawFunds`), eliminando um vetor de ataque crítico. |
| **Controle de Acesso** | `Ownable` | Funções críticas (cunhagem, adição de liquidez, retirada de fundos) são restritas ao deployer/proprietário do contrato. |
| **Emergência** | `Pausable` | Permite ao Owner pausar a venda (`buyTokens`) instantaneamente em caso de ameaça de segurança. |
| **Eficiência** | `Custom Errors` | Utilização de `revert InvalidAddress()` e outros para melhor diagnóstico e **menor custo de gás** em transações que falham. |

---

## 💰 Tokenomics: Mecanismo de Preço Crescente (Rampa de Valorização)

O preço do token $KCN$ aumenta automaticamente, incentivando a urgência e a valorização inicial para os primeiros participantes.

### Detalhes da Venda

| Parâmetro | Valor de Teste | Lógica de Negócio |
| :--- | :--- | :--- |
| **Supply Total** | `1.000.000 KCN` | O total de tokens que podem ser cunhados. |
| **Preço Inicial** | `1 x 10¹⁵ Wei` (0.001 ETH) | O custo base para o primeiro token. |
| **Limite por Carteira**| `50 KCN` | Regra de distribuição justa (`MAX_PURCHASE_PER_WALLET`). |
| **Lote de Aumento** | `10.000 KCN` | Volume de vendas necessário para acionar o salto de preço. |

### Fases de Valorização

A taxa de aumento de preço (Incremento) muda ao atingir 50% do supply.

| Fase | Limite de Supply | Incremento (BPS) | Taxa de Aumento |
| :--- | :--- | :--- | :--- |
| **Alpha (Início)** | 50% | `500 BPS` | **5.0%** de aumento por lote |
| **Omega (Final)** | 50% | `200 BPS` | **2.0%** de aumento por lote |

### 🔗 Lógica de Liquidez e Bloqueio

O contrato inclui funções para finalizar a venda e listar o token em uma DEX (Uniswap V2):

* **Alocação de Tokens:** 70% dos tokens $KCN$ restantes são alocados para o pool de liquidez.
* **Alocação de ETH:** 80% do $ETH$ arrecadado na venda é alocado para o pool.
* **Adição:** A função `addLiquidityToUniswap()` automatiza a criação do par $KCN/ETH$ e garante a liquidez pós-venda.

---

## 💻 Estrutura do Código em Solidity

O código é escrito em Solidity ^0.8.20 e está organizado para máxima clareza e segurança (conforme validado no Remix IDE).

1.  **Interfaces:** `IUniswapV2Router02` e `IUniswapV2Factory` são declaradas em nível superior, fora do contrato.
2.  **Inicialização Separada:** As operações de alto custo/risco (Cunhagem e Configuração do Router) foram separadas em **`initializeSupply()`** e **`setRouterDetails()`** para garantir que o construtor seja leve e a implantação seja sempre bem-sucedida.
3.  **Eventos:** Todos os eventos críticos (`TokensPurchased`, `PriceUpdated`, `LiquidityAdded`) estão presentes para rastreamento de dados em exploradores de blocos.

```solidity
// Arquivo principal: KeyCoin.sol
contract KeyCoin is ERC20, ERC20Burnable, Ownable, ReentrancyGuard, Pausable {
    // ... (Variáveis e Mapeamentos)

    // Construtor minimalista, sem chamadas externas
    constructor(...) ERC20("KeyCoin", "KCN") Ownable(msg.sender) { /* ... */ }

    // Funções de Inicialização (Executadas pelo Owner após o Deploy)
    function initializeSupply() external onlyOwner { /* ... */ }
    function setRouterDetails() external onlyOwner { /* ... */ }

    // Funções de Venda e Lógica Central
    function buyTokens(address referrer) public payable nonReentrant whenNotPaused { /* ... */ }
    function _updatePriceIfNeeded() internal { /* ... */ }

    // ...
}
