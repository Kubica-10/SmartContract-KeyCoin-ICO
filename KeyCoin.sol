// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/security/Pausable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

// =========================================================================
// 1. INTERFACES UNISWAP V2 (Nível Superior)
// =========================================================================
interface IUniswapV2Router02 {
    function factory() external view returns (address);
    function WETH() external view returns (address);
    function addLiquidityETH(
        address token,
        uint amountTokenDesired,
        uint amountTokenMin,
        uint amountETHMin,
        address to,
        uint deadline
    ) external payable returns (uint amountToken, uint amountETH, uint liquidity);
}
interface IUniswapV2Factory {
    function createPair(address tokenA, address tokenB) external returns (address pair);
    function getPair(address tokenA, address tokenB) external view returns (address pair);
}

/**
 * @title KeyCoin (KCN) V5 - Final e Otimizado
 * @notice Supply e Configuração do Router separados para evitar falhas no construtor.
 */
contract KeyCoin is ERC20, ERC20Burnable, Ownable, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20; 

    // =========================================================================
    // 2. CUSTOM ERRORS
    // =========================================================================
    error SaleNotActive();
    error SaleEndedTradeOnDEX();
    error ZeroValueSent();
    error InsufficientValueForToken();
    error SupplyExceeded();
    error MaxPurchaseLimitReached(uint maxPurchase);
    error RefundFailed();
    error WhitelistPhaseActive();
    error NotWhitelisted();
    error InvalidAddress(address addr);
    error InvalidBatchSize();
    error NoTokensToWithdraw();
    error InvalidRouterAddress();
    error LiquidityAlreadyAdded();
    error InvalidPercentage(uint percentage);
    error SupplyNotInitialized(); 

    // =========================================================================
    // 3. EVENTOS
    // =========================================================================
    event TokensPurchased(
        address indexed buyer,
        uint amount,
        uint priceWei,
        uint totalCost,
        uint refund,
        bool isWhitelist,
        uint timestamp
    );
    event ReferralReward(
        address indexed referrer,
        address indexed referee,
        uint referrerBonus,
        uint refereeBonus,
        uint timestamp
    );
    event SaleEnded(uint finalTokensSold, uint totalEthRaised, uint timestamp);
    event PriceUpdated(uint newPriceWei, uint newBatch, uint timestamp);
    event LiquidityAdded(
        address indexed pair,
        uint tokenAmount,
        uint ethAmount,
        uint liquidity,
        uint timestamp
    );
    event UnsoldTokensBurned(uint amount, uint timestamp);
    event FundsWithdrawn(address indexed to, uint amount, uint timestamp);
    event RescueTokens(address indexed token, address indexed to, uint amount, uint timestamp);

    // =========================================================================
    // 4. CONSTANTES E ESTADO
    // =========================================================================
    uint public constant TOTAL_SUPPLY = 1_000_000 * (10 ** 18);
    uint public constant PHASE_ALPHA_SUPPLY = 500_000 * (10 ** 18);
    uint public constant BATCH_SIZE = 10_000 * (10 ** 18);
    uint public constant MAX_PURCHASE_PER_WALLET = 50 * (10 ** 18);
    uint public constant MAX_BATCH_JUMPS = 10;
    uint public constant WHITELIST_DISCOUNT_BPS = 2000;
    uint public constant WHITELIST_MAX_PURCHASE = 100 * (10 ** 18);
    uint public constant REFERRAL_BONUS_BPS = 500;
    uint public constant REFEREE_BONUS_BPS = 300;
    uint public constant MAX_REFERRAL_DEPTH = 1000;
    uint public constant LIQUIDITY_TOKEN_PERCENTAGE = 7000;
    uint public constant LIQUIDITY_ETH_PERCENTAGE = 8000;
    uint private constant BPS_DENOMINATOR = 10000;
    uint public constant MAX_WHITELIST_BATCH = 200;

    // Variáveis Imutáveis (Definidas no Construtor)
    uint public immutable initialPriceWei; 
    uint public immutable priceIncrementBpsAlpha; 
    uint public immutable priceIncrementBpsOmega; 
    address public immutable UNISWAP_V2_ROUTER; 

    // Variáveis Mutáveis (Configuradas após o Deploy)
    address public UNISWAP_V2_FACTORY;
    address public UNISWAP_WETH;
    bool public supplyInitialized = false;
    bool public liquidityAdded;

    // Estado da Venda/Referral/Controle
    uint public tokensSold;
    mapping(address => uint) public purchasesByWallet;
    bool public saleActive;
    uint public currentPriceWei;
    uint public currentBatch;
    uint public totalEthRaised;
    bool public whitelistPhaseActive;
    mapping(address => bool) public whitelist;
    mapping(address => uint) public whitelistPurchases;
    uint public whitelistCount;
    mapping(address => address) public referredBy;
    mapping(address => uint) public referralCount;
    mapping(address => uint) public referralEarnings;
    uint public totalReferralBonusPaid;
    address public liquidityPair;
    uint public liquidityTokenAmount;
    uint public liquidityEthAmount;


    // =========================================================================
    // 5. CONSTRUTOR (Apenas Salva os Parâmetros Imutáveis)
    // =========================================================================
    constructor(
        uint _initialPriceWei,
        uint _priceIncrementBpsAlpha,
        uint _priceIncrementBpsOmega,
        address _uniswapV2Router
    ) ERC20("KeyCoin", "KCN") Ownable(msg.sender) {
        if (_initialPriceWei == 0) revert InvalidAddress(address(0));
        if (_priceIncrementBpsAlpha == 0 || _priceIncrementBpsAlpha > 5000) revert InvalidPercentage(_priceIncrementBpsAlpha);
        if (_priceIncrementBpsOmega == 0 || _priceIncrementBpsOmega > 5000) revert InvalidPercentage(_priceIncrementBpsOmega);
        if (_uniswapV2Router == address(0)) revert InvalidRouterAddress();

        initialPriceWei = _initialPriceWei;
        priceIncrementBpsAlpha = _priceIncrementBpsAlpha;
        priceIncrementBpsOmega = _priceIncrementBpsOmega;
        UNISWAP_V2_ROUTER = _uniswapV2Router;

        currentPriceWei = _initialPriceWei;
        saleActive = true;
        whitelistPhaseActive = true;
    }

    // =========================================================================
    // 6. FUNÇÕES DE INICIALIZAÇÃO PÓS-DEPLOY (Owner Only)
    // =========================================================================

    /// @notice Cunha o total supply no contrato após o deploy. Só pode ser chamado uma vez.
    function initializeSupply() external onlyOwner {
        if (supplyInitialized) revert LiquidityAlreadyAdded(); 
        _mint(address(this), TOTAL_SUPPLY);
        supplyInitialized = true;
    }

    /// @notice Configura os endereços da Factory e WETH do Router.
    function setRouterDetails() external onlyOwner {
        if (UNISWAP_V2_FACTORY != address(0)) revert LiquidityAlreadyAdded(); 
        
        // As chamadas externas que revertiam o construtor:
        IUniswapV2Router02 router = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        UNISWAP_V2_FACTORY = router.factory();
        UNISWAP_WETH = router.WETH();
    }

    // =========================================================================
    // 7. FUNÇÕES DE COMPRA (buyTokens)
    // =========================================================================
    function buyTokens(address referrer) public payable nonReentrant whenNotPaused {
        if (!supplyInitialized) revert SupplyNotInitialized(); 
        if (!saleActive) revert SaleNotActive();
        if (liquidityAdded) revert SaleEndedTradeOnDEX();
        if (msg.value == 0) revert ZeroValueSent();

        bool isWhitelistPurchase = isWhitelisted(msg.sender) && whitelistPhaseActive;

        if (whitelistPhaseActive && !isWhitelistPurchase && whitelistCount > 0) {
            revert WhitelistPhaseActive();
        }

        uint priceForThisPurchase = getCurrentPriceWei(isWhitelistPurchase);
        uint tokensToBuy = (msg.value * (10 ** decimals())) / priceForThisPurchase;
        if (tokensToBuy == 0) revert InsufficientValueForToken();

        uint tokensRemaining = TOTAL_SUPPLY - tokensSold;
        if (tokensToBuy > tokensRemaining) {
            tokensToBuy = tokensRemaining;
        }

        // Aplicação de Limite de Compra
        if (isWhitelistPurchase) {
            uint whitelistLimitAvailable = WHITELIST_MAX_PURCHASE - whitelistPurchases[msg.sender];
            if (whitelistLimitAvailable == 0) revert MaxPurchaseLimitReached(WHITELIST_MAX_PURCHASE);
            if (tokensToBuy > whitelistLimitAvailable) tokensToBuy = whitelistLimitAvailable;
            whitelistPurchases[msg.sender] += tokensToBuy;
        } else {
            uint walletLimitAvailable = MAX_PURCHASE_PER_WALLET - purchasesByWallet[msg.sender];
            if (walletLimitAvailable == 0) revert MaxPurchaseLimitReached(MAX_PURCHASE_PER_WALLET);
            if (tokensToBuy > walletLimitAvailable) tokensToBuy = walletLimitAvailable;
            purchasesByWallet[msg.sender] += tokensToBuy;
        }
        
        if (tokensToBuy == 0) revert InsufficientValueForToken();

        uint actualCost = (tokensToBuy * priceForThisPurchase) / (10 ** decimals());
        uint refund = msg.value - actualCost;

        // Execução
        _transfer(address(this), msg.sender, tokensToBuy);
        tokensSold += tokensToBuy;
        totalEthRaised += actualCost;

        _processReferral(msg.sender, referrer, tokensToBuy);

        // Reembolso
        if (refund > 0) {
            (bool refundSuccess, ) = payable(msg.sender).call{value: refund}("");
            if (!refundSuccess) revert RefundFailed();
        }

        emit TokensPurchased(msg.sender, tokensToBuy, priceForThisPurchase, actualCost, refund, isWhitelistPurchase, block.timestamp);

        _updatePriceIfNeeded();

        if (tokensSold == TOTAL_SUPPLY) {
            _endSale();
        }
    }

    // =========================================================================
    // 8. LÓGICA INTERNA E ADMIN (Restante do contrato)
    // =========================================================================
    
    function _processReferral(address buyer, address referrer, uint tokensPurchased) internal {
        if (referrer == address(0) || referrer == buyer || referredBy[buyer] != address(0) || referralCount[referrer] >= MAX_REFERRAL_DEPTH) {
            return;
        }

        uint referrerBonus = (tokensPurchased * REFERRAL_BONUS_BPS) / BPS_DENOMINATOR;
        uint refereeBonus = (tokensPurchased * REFEREE_BONUS_BPS) / BPS_DENOMINATOR;
        uint totalBonus = referrerBonus + refereeBonus;

        if (balanceOf(address(this)) < totalBonus) return;

        referredBy[buyer] = referrer;
        referralCount[referrer]++;
        referralEarnings[referrer] += referrerBonus;
        totalReferralBonusPaid += totalBonus;

        _transfer(address(this), referrer, referrerBonus);
        _transfer(address(this), buyer, refereeBonus);

        emit ReferralReward(referrer, buyer, referrerBonus, refereeBonus, block.timestamp);
    }

    function _updatePriceIfNeeded() internal {
        if (BATCH_SIZE == 0) return; 

        uint newBatch = tokensSold / BATCH_SIZE;
        if (newBatch > currentBatch) {
            uint batchesToUpdate = newBatch - currentBatch;
            if (batchesToUpdate > MAX_BATCH_JUMPS) {
                batchesToUpdate = MAX_BATCH_JUMPS;
                newBatch = currentBatch + MAX_BATCH_JUMPS;
            }

            uint newPrice = currentPriceWei;
            for (uint i = 0; i < batchesToUpdate; i++) {
                uint batchIndex = currentBatch + i;
                uint tokensAtBatchStart = batchIndex * BATCH_SIZE;
                
                uint incrementBPS = (tokensAtBatchStart < PHASE_ALPHA_SUPPLY) 
                    ? priceIncrementBpsAlpha 
                    : priceIncrementBpsOmega;

                newPrice = (newPrice * (BPS_DENOMINATOR + incrementBPS)) / BPS_DENOMINATOR;
            }

            currentPriceWei = newPrice;
            currentBatch = newBatch;
            emit PriceUpdated(newPrice, newBatch, block.timestamp);
        }
    }

    function _endSale() internal {
        saleActive = false;
        whitelistPhaseActive = false;
        emit SaleEnded(tokensSold, totalEthRaised, block.timestamp);
    }

    function getCurrentPriceWei(bool applyWhitelistDiscount) public view returns (uint) {
        if (applyWhitelistDiscount && whitelistPhaseActive) {
            return (currentPriceWei * (BPS_DENOMINATOR - WHITELIST_DISCOUNT_BPS)) / BPS_DENOMINATOR;
        }
        return currentPriceWei;
    }

    function isWhitelisted(address account) public view returns (bool) {
        return whitelist[account];
    }

    function addLiquidityToUniswap() external onlyOwner nonReentrant {
        if (!supplyInitialized) revert SupplyNotInitialized();
        if (liquidityAdded) revert LiquidityAlreadyAdded();
        if (saleActive) revert SaleNotActive();

        uint contractTokenBalance = balanceOf(address(this));
        uint contractEthBalance = address(this).balance;

        if (contractTokenBalance == 0 || contractEthBalance == 0) revert NoTokensToWithdraw();

        uint tokensForLiquidity = (contractTokenBalance * LIQUIDITY_TOKEN_PERCENTAGE) / BPS_DENOMINATOR;
        uint ethForLiquidity = (contractEthBalance * LIQUIDITY_ETH_PERCENTAGE) / BPS_DENOMINATOR;

        _approve(address(this), UNISWAP_V2_ROUTER, tokensForLiquidity);
        
        // A transação só passa se UNISWAP_V2_FACTORY e UNISWAP_WETH foram configurados!
        if (UNISWAP_V2_FACTORY == address(0) || UNISWAP_WETH == address(0)) revert InvalidRouterAddress();

        IUniswapV2Router02 router = IUniswapV2Router02(UNISWAP_V2_ROUTER);
        (uint amountToken, uint amountEth, uint liquidity) = router.addLiquidityETH{ value: ethForLiquidity }(
            address(this),
            tokensForLiquidity,
            0,
            0,
            owner(),
            block.timestamp + 15 minutes
        );

        if (liquidityPair == address(0)) {
            liquidityPair = IUniswapV2Factory(UNISWAP_V2_FACTORY).getPair(address(this), UNISWAP_WETH);
        }

        liquidityAdded = true;
        liquidityTokenAmount = amountToken;
        liquidityEthAmount = amountEth;

        emit LiquidityAdded(liquidityPair, amountToken, amountEth, liquidity, block.timestamp);

        uint remainingTokens = balanceOf(address(this));
        if (remainingTokens > 0) {
            _burn(address(this), remainingTokens);
            emit UnsoldTokensBurned(remainingTokens, block.timestamp);
        }
    }

    function addToWhitelist(address[] calldata accounts) external onlyOwner {
        if (accounts.length == 0 || accounts.length > MAX_WHITELIST_BATCH) revert InvalidBatchSize();

        for (uint i = 0; i < accounts.length; i++) {
            address account = accounts[i];
            if (account == address(0)) revert InvalidAddress(account);
            if (!whitelist[account]) {
                whitelist[account] = true;
                whitelistCount++;
            }
        }
    }

    function withdrawFunds() external onlyOwner nonReentrant {
        uint balance = address(this).balance;
        if (balance == 0) revert NoTokensToWithdraw();

        (bool success, ) = payable(owner()).call{ value: balance }("");
        if (!success) revert RefundFailed();
        emit FundsWithdrawn(owner(), balance, block.timestamp);
    }

    function endSale() external onlyOwner {
        if (!saleActive) revert SaleNotActive();
        _endSale();
    }

    function burnUnsoldTokens() external onlyOwner {
        if (!supplyInitialized) revert SupplyNotInitialized();
        if (saleActive) revert SaleNotActive();
        if (liquidityAdded) revert LiquidityAlreadyAdded(); 

        uint unsoldTokens = balanceOf(address(this));
        if (unsoldTokens == 0) revert NoTokensToWithdraw();
        
        _burn(address(this), unsoldTokens);
        emit UnsoldTokensBurned(unsoldTokens, block.timestamp);
    }

    function forceUpdatePrice() external onlyOwner {
        _updatePriceIfNeeded();
    }

    function rescueTokens(address tokenAddress, uint amount) external onlyOwner {
        if (tokenAddress == address(this) || tokenAddress == address(0)) revert InvalidAddress(tokenAddress);
        
        IERC20(tokenAddress).safeTransfer(owner(), amount);
        emit RescueTokens(tokenAddress, owner(), amount, block.timestamp);
    }

    // =========================================================================
    // 9. FALLBACKS
    // =========================================================================
    receive() external payable {
        if (saleActive && !liquidityAdded) {
            buyTokens(address(0));
        }
    }

    fallback() external payable {
        if (saleActive && !liquidityAdded) {
            buyTokens(address(0));
        }
    }
}
