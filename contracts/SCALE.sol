// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/interfaces/IERC165.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import "@uniswap/v2-periphery/contracts/interfaces/IUniswapV2Router02.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Factory.sol";
import "@uniswap/v2-core/contracts/interfaces/IUniswapV2Pair.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./interfaces/IWETH9.sol";
import "./interfaces/IDragonX.sol";
import "./lib/FullMath.sol";
import "./lib/constants.sol";

contract SCALE is ERC20, Ownable2Step, IERC165 {
    using SafeERC20 for IERC20;

    // --------------------------- STATE VARIABLES --------------------------- //

    address public heliosVault;
    address public dragonXVault;
    address public devWallet;
    address public marketingWallet;
    address public shedContract;
    address public bdxBuyBurnAddress;

    /// @notice Basis point percentage of SCALE tokens sent to caller as a reward for calling distributeReserve.
    uint16 public incentiveFee = 30;

    /// @notice Basis point percentage of SCALE token reflections.
    uint16 public reflectionFee = 150;

    /// @notice Total SCALE tokens burned to date.
    uint256 public totalBurned;

    /// @notice Minimum size of the Reserve to be available for distribution.
    uint256 public minReserveDistribution = 1_000_000 * 10 ** 9;

    /// @notice <aximum size of the Reserve to be used for distribution.
    uint256 public maxReserveDistribution = 500_000_000 * 10 ** 9;

    /// @notice TitanX tokens allocated for ecosystem token purchases.
    uint256 public titanLpPool;

    /// @notice TitanX tokens used in ecosystem token purchases.
    uint256 public totalLpPoolUsed;

    /// @notice Scale tokens allocated for creation of the LPs.
    uint256 public scaleLpPool;

    /// @notice TitanX tokens allocated for swaps to DragonX and transfer to BDX Buy & Burn.
    uint256 public bdxBuyBurnPool;

    /// @notice DragonX tokens allocated for transfer to BDX Buy & Burn.
    uint256 public buyBurnDragonXAllocation;

    /// @notice Total LPs created.
    uint8 public totalLPsCreated;

    /// @notice Number of performed purchases for the BDX Buy & Burn.
    uint8 public buyBurnPurchases;

    /// @notice Number of purchases required for TitanX/DragonX & TitanX/BDX swaps.
    /// @dev Can only be changed before the presale is finalized.
    uint8 public purchasesRequired = 10;

    /// @notice Timestamp in seconds of the presale end date.
    uint256 public presaleEnd;

    /// @notice Has the presale been finalized.
    bool public presaleFinalized;

    /// @notice Have all token purchases for the LPs been performed.
    bool public lpPurchaseFinished;

    /// @notice Is trading enabled.
    bool public tradingEnabled;

    /// @notice Returns the total amount of ecosystem tokens purchased for LP creation for a specific token.
    mapping(address token => uint256) public tokenPool;

    /// @notice Total number of purchases performed per each ecosystem token.
    mapping(address token => uint8) public lpPurchases;

    /// @notice Percent of the lpPool to calculate the allocation per ecosystem token purchases.
    mapping(address token => uint8) public tokenLpPercent;

    uint256 private _totalMinted;
    bytes32 private _merkleRoot;

    mapping(address => uint256) private _tOwned;
    mapping(address => uint256) private _rOwned;
    mapping(address => bool) private _isExcludedFromReflections;
    address[] private _excluded;

    uint256 private _tTotal = 100 * 10 ** 12 * 10 ** 9;
    uint256 private _rTotal = (MAX_VALUE - (MAX_VALUE % _tTotal));

    // --------------------------- ERRORS --------------------------- //

    error ZeroInput();
    error ZeroAddress();
    error PresaleInactive();
    error PresaleActive();
    error MaxSupply();
    error TradingDisabled();
    error Prohibited();
    error DuplicateToken();
    error IncorrectPercentage();
    error IncorrectTokenNumber();
    error IncorrectBonus();
    error InsuffucientBalance();
    error ExcludedAddress();

    // ------------------------ EVENTS & MODIFIERS ----------------------- //

    event PresaleStarted();
    event TradingEnabled();
    event ReserveDistributed();

    modifier onlyPresale() {
        if (!isPresaleActive()) revert PresaleInactive();
        _;
    }

    // --------------------------- CONSTRUCTOR --------------------------- //

    constructor(
        address _owner,
        address _devWallet,
        address _marketingWallet,
        address _heliosVault,
        address _dragonxVault,
        address _bdxBuyBurnAddress,
        address[] memory _ecosystemTokens,
        uint8[] memory _lpPercentages
    ) ERC20("SCALE", "SCALE") Ownable(_owner) {
        if (_ecosystemTokens.length != NUM_ECOSYSTEM_TOKENS) revert IncorrectTokenNumber();
        if (_lpPercentages.length != NUM_ECOSYSTEM_TOKENS) revert IncorrectTokenNumber();
        if (_owner == address(0)) revert ZeroAddress();
        if (_devWallet == address(0)) revert ZeroAddress();
        if (_marketingWallet == address(0)) revert ZeroAddress();
        if (_heliosVault == address(0)) revert ZeroAddress();
        if (_dragonxVault == address(0)) revert ZeroAddress();
        if (_bdxBuyBurnAddress == address(0)) revert ZeroAddress();

        _rOwned[address(this)] = _rTotal;
        devWallet = _devWallet;
        marketingWallet = _marketingWallet;
        heliosVault = _heliosVault;
        dragonXVault = _dragonxVault;
        bdxBuyBurnAddress = _bdxBuyBurnAddress;

        uint8 totalPercentage;
        for (uint256 i = 0; i < _ecosystemTokens.length; i++) {
            address token = _ecosystemTokens[i];
            uint8 allocation = _lpPercentages[i];
            if (token == address(0)) revert ZeroAddress();
            if (allocation == 0) revert ZeroInput();
            if (tokenLpPercent[token] != 0) revert DuplicateToken();
            tokenLpPercent[token] = allocation;
            totalPercentage += allocation;
        }
        if (totalPercentage != 100) revert IncorrectPercentage();
    }

    // --------------------------- PUBLIC FUNCTIONS --------------------------- //

    /// @notice Allows users to mint tokens during the presale using TitanX tokens.
    /// @param amount The amount of SCALE tokens to mint.
    /// @param bonus Bonus percentage for the user.
    /// @param merkleProof Proof for the user.
    function mintWithTitanX(uint256 amount, uint16 bonus, bytes32[] memory merkleProof) external onlyPresale {
        if (amount == 0) revert ZeroInput();
        IERC20(TITANX).safeTransferFrom(msg.sender, address(this), amount * 10 ** 9);
        amount = _processBonus(amount, bonus, merkleProof);
        if ((_totalMinted + amount) * 135 / 100 > _tTotal) revert MaxSupply();
        _rMint(msg.sender, amount);
    }

    /// @notice Allows users to purchase tokens during the presale using ETH.
    /// @param amount The amount of SCALE tokens to mint.
    /// @param bonus Bonus percentage for the user.
    /// @param merkleProof Proof for the user.
    /// @param deadline Deadline for executing the swap.
    function mintWithETH(uint256 amount, uint16 bonus, bytes32[] memory merkleProof, uint256 deadline)
        external
        payable
        onlyPresale
    {
        if (amount == 0) revert ZeroInput();
        uint256 titanXAmount = amount * 10 ** 9;
        uint256 swappedAmount = _swapETHForTitanX(titanXAmount, deadline);
        if (swappedAmount > titanXAmount) IERC20(TITANX).safeTransfer(msg.sender, swappedAmount - titanXAmount);
        amount = _processBonus(amount, bonus, merkleProof);
        if ((_totalMinted + amount) * 135 / 100 > _tTotal) revert MaxSupply();
        _rMint(msg.sender, amount);
    }

    /// @notice Burns SCALE from user's wallet.
    /// @param amount The amount of SCALE tokens to burn.
    function burn(uint256 amount) public {
        if (!tradingEnabled) revert TradingDisabled();
        _rBurn(msg.sender, amount);
    }

    /// @notice Reflects SCALE tokens to all holders from user's wallet.
    /// @param amount The amount of SCALE tokens to reflect.
    function reflect(uint256 amount) public {
        if (!tradingEnabled) revert TradingDisabled();
        address sender = msg.sender;
        if (_isExcludedFromReflections[sender]) revert ExcludedAddress();
        uint256 rAmount = amount * _getRate();
        _balanceCheck(sender, rAmount, amount);
        _rOwned[sender] -= rAmount;
        _rTotal -= rAmount;
    }

    /// @notice Distributes the accumulated reserve.
    /// @param minDragonXAmount The minimum amount of DragonX tokens received for BDX Buy & Burn.
    /// @param deadline Deadline for executing the swap.
    function distributeReserve(uint256 minDragonXAmount, uint256 deadline) external {
        if (!tradingEnabled) revert TradingDisabled();
        uint256 balance = balanceOf(address(this));
        if (balance < minReserveDistribution) revert InsuffucientBalance();
        uint256 distribution = balance > maxReserveDistribution ? maxReserveDistribution : balance;
        distribution = _processIncentiveFee(msg.sender, distribution);

        uint256 buyBurnShare = distribution / 2;
        _swapScaleToDragonX(buyBurnShare, minDragonXAmount, deadline);

        uint256 quarter = distribution / 4;

        uint256 rTransferAmount = reflectionFromToken(quarter);
        _rOwned[address(this)] -= rTransferAmount;
        _rOwned[marketingWallet] += rTransferAmount;
        if (_isExcludedFromReflections[marketingWallet]) _tOwned[marketingWallet] += quarter;
        _rBurn(address(this), quarter);
        emit ReserveDistributed();
    }

    // --------------------------- PRESALE MANAGEMENT FUNCTIONS --------------------------- //

    /// @notice Starts the presale for the SCALE token.
    function startPresale() external onlyOwner {
        if (presaleEnd != 0) revert Prohibited();
        if (_merkleRoot == bytes32(0)) revert IncorrectBonus();
        unchecked {
            presaleEnd = block.timestamp + PRESALE_LENGTH;
        }
        emit PresaleStarted();
    }

    /// @notice Finalizes the presale and distributes liquidity pool tokens.
    function finalizePresale() external onlyOwner {
        if (presaleEnd == 0) revert PresaleInactive();
        if (isPresaleActive()) revert PresaleActive();
        if (shedContract == address(0)) revert ZeroAddress();
        if (presaleFinalized) revert Prohibited();

        _distributeTokens();

        // burn not minted
        uint256 tBurn = _tTotal - _totalMinted - scaleLpPool;
        uint256 rBurn = tBurn * _getRate();
        _rOwned[address(this)] -= rBurn;
        _rTotal -= rBurn;
        _tTotal = _totalMinted + scaleLpPool;

        presaleFinalized = true;
        emit Transfer(address(0), address(this), scaleLpPool);
    }

    /// @notice Allows the owner to purchase tokens for liquidity pool allocation.
    /// @param token The address of the token to purchase.
    /// @param minAmountOut The minimum amount of tokens to receive from the swap.
    /// @param deadline The deadline for the swap transaction.
    function purchaseTokenForLP(address token, uint256 minAmountOut, uint256 deadline) external onlyOwner {
        if (!presaleFinalized) revert PresaleActive();
        if (lpPurchaseFinished) revert Prohibited();
        uint256 requiredAmount = token == BDX_ADDRESS ? purchasesRequired : 1;
        if (lpPurchases[token] == requiredAmount) revert Prohibited();
        uint256 allocation = tokenLpPercent[token];
        if (allocation == 0) revert Prohibited();
        uint256 amountToSwap = FullMath.mulDiv(titanLpPool, allocation, 100 * requiredAmount);
        totalLpPoolUsed += amountToSwap;
        uint256 swappedAmount = _swapTitanXToToken(token, amountToSwap, minAmountOut, deadline);
        unchecked {
            tokenPool[token] += swappedAmount;
            lpPurchases[token]++;
            // account for rounding error
            if (totalLpPoolUsed >= titanLpPool - NUM_ECOSYSTEM_TOKENS - purchasesRequired) lpPurchaseFinished = true;
        }
    }

    /// @notice Allows the owner to purchase DragonX tokens for the BDX Buy & Burn contract.
    /// @param minAmountOut The minimum amount of DragonX tokens to receive from the swap.
    /// @param deadline The deadline for the swap transaction.
    function purchaseDragonXForBuyBurn(uint256 minAmountOut, uint256 deadline) external onlyOwner {
        if (!presaleFinalized) revert PresaleActive();
        if (buyBurnPurchases == purchasesRequired) revert Prohibited();

        uint256 amountToSwap = bdxBuyBurnPool / purchasesRequired;
        uint256 swappedAmount = _swapTitanXToToken(DRAGONX_ADDRESS, amountToSwap, minAmountOut, deadline);
        unchecked {
            buyBurnDragonXAllocation += swappedAmount;
            buyBurnPurchases++;
        }
        if (buyBurnPurchases == purchasesRequired) {
            IERC20(DRAGONX_ADDRESS).safeTransfer(bdxBuyBurnAddress, buyBurnDragonXAllocation);
        }
    }

    /// @notice Deploys a liquidity pool for SCALE tokens paired with another token.
    /// @param tokenAddress The address of the token to pair with SCALE in the liquidity pool.
    function deployLiquidityPool(address tokenAddress)
        external
        onlyOwner
    {
        if (!lpPurchaseFinished) revert Prohibited();
        uint256 tokenAmount = tokenPool[tokenAddress];
        if (tokenAmount == 0) revert Prohibited();
        uint256 scaleAllocation = FullMath.mulDiv(scaleLpPool, tokenLpPercent[tokenAddress], 100);

        _addLiquidity(tokenAddress, tokenAmount, scaleAllocation);
        tokenPool[tokenAddress] = 0;
        unchecked {
            totalLPsCreated++;
        }
        if (totalLPsCreated == NUM_ECOSYSTEM_TOKENS) _enableTrading();
    }

    /// @notice Claim any leftover dust from divisions when performing TitanX swaps.
    /// @dev Can only be claimed after all purchases have been made.
    function claimDust() external onlyOwner {
        if (!tradingEnabled || buyBurnPurchases != purchasesRequired) revert Prohibited();
        IERC20 titanX = IERC20(TITANX);
        titanX.safeTransfer(msg.sender, titanX.balanceOf(address(this)));
    }

    // --------------------------- ADMINISTRATIVE FUNCTIONS --------------------------- //

    /// @notice Excludes the account from receiving reflections.
    /// @param account Address of the account to be excluded.
    function excludeAccountFromReflections(address account) public onlyOwner {
        if (_isExcludedFromReflections[account]) revert ExcludedAddress();
        if (_excluded.length == 22)revert Prohibited();
        if (account == address(this)) revert Prohibited();
        if (_rOwned[account] > 0) {
            _tOwned[account] = tokenFromReflection(_rOwned[account]);
        }
        _isExcludedFromReflections[account] = true;
        _excluded.push(account);
    }

    /// @notice Includes the account back to receiving reflections.
    /// @param account Address of the account to be included.
    function includeAccountToReflections(address account) public onlyOwner {
        if (!_isExcludedFromReflections[account]) revert ExcludedAddress();
        uint256 difference = _rOwned[account] - (_getRate() * _tOwned[account]);
        for (uint256 i = 0; i < _excluded.length; i++) {
            if (_excluded[i] == account) {
                _excluded[i] = _excluded[_excluded.length - 1];
                _tOwned[account] = 0;
                _rOwned[account] -= difference;
                _rTotal -= difference;
                _isExcludedFromReflections[account] = false;
                _excluded.pop();
                break;
            }
        }
    }

    /// @notice Sets the amount of purchases for tokens.
    /// @param amount Number of purchases needed for each token.
    /// @dev Can only be called by the owner before presale if finalized.
    function setPurchasesRequired(uint8 amount) external onlyOwner {
        if (amount == 0) revert ZeroInput();
        if (amount > 50) revert Prohibited();
        if (presaleFinalized) revert Prohibited();
        purchasesRequired = amount;
    }

    /// @notice Sets the DragonX Vault address.
    /// @param _address The address of the DragonX Vault.
    /// @dev Can only be called by the owner.
    function setDragonXVault(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        dragonXVault = _address;
    }

    /// @notice Sets the Helios Vault address.
    /// @param _address The address of the Helios Vault.
    /// @dev Can only be called by the owner.
    function setHeliosVault(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        heliosVault = _address;
    }

    /// @notice Sets the Developer wallet address.
    /// @param _address The address of the Developer wallet.
    /// @dev Can only be called by the owner.
    function setDevWallet(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        devWallet = _address;
    }

    /// @notice Sets the Marketing wallet address.
    /// @param _address The address of the Marketing wallet.
    /// @dev Can only be called by the owner.
    function setMarketingWallet(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        marketingWallet = _address;
    }

    /// @notice Sets the SHED contract address.
    /// @param _address The address of the SHED contract.
    /// @dev Can only be called by the owner.
    function setSHED(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        shedContract = _address;
    }

    /// @notice Sets the BDX Buy & Burn contract address.
    /// @param _address The address of the BDX Buy & Burn contract.
    /// @dev Can only be called by the owner.
    function setBDXBuyBurn(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        bdxBuyBurnAddress = _address;
    }

    /// @notice Sets the merkle root for minting bonuses.
    /// @param root The merkle root.
    /// @dev Can only be called by the owner.
    function setMerkleRoot(bytes32 root) external onlyOwner {
        if (root == bytes32(0)) revert ZeroInput();
        _merkleRoot = root;
    }

    /// @notice Sets the reflection fee size.
    /// @param bps Reflection fee in basis points (150 = 1.5%).
    /// @dev Can only be called by the owner.
    function setReflectionFee(uint16 bps) external onlyOwner {
        if (bps != 150 && bps != 300 && bps != 450 && bps != 600) revert Prohibited();
        reflectionFee = bps;
    }

    /// @notice Sets the Incentive fee size.
    /// @param bps Incentive fee in basis points (30 = 0.3%).
    /// @dev Can only be called by the owner.
    function setIncentiveFee(uint16 bps) external onlyOwner {
        if (bps < 30 || bps > 500) revert Prohibited();
        incentiveFee = bps;
    }

    /// @notice Sets the minimum Reserve distribution size.
    /// @param limit Reserve limit size.
    /// @dev Can only be called by the owner.
    function setMinReserveDistribution(uint256 limit) external onlyOwner {
        if (limit < 100 || limit > maxReserveDistribution) revert Prohibited();
        minReserveDistribution = limit;
    }

    /// @notice Sets the maximum Reserve distribution size.
    /// @param limit Reserve limit size.
    /// @dev Can only be called by the owner.
    function setMaxReserveDistribution(uint256 limit) external onlyOwner {
        if (limit < minReserveDistribution || limit > _tTotal) revert Prohibited();
        maxReserveDistribution = limit;
    }

    // --------------------------- VIEW FUNCTIONS --------------------------- //

    /// @notice Checks if the presale is currently active.
    /// @return A boolean indicating whether the presale is active.
    function isPresaleActive() public view returns (bool) {
        return presaleEnd > block.timestamp;
    }

    function decimals() public pure override returns (uint8) {
        return 9;
    }

    function totalSupply() public view override returns (uint256) {
        if (!presaleFinalized) return _totalMinted;
        return _tTotal;
    }

    function balanceOf(address account) public view override returns (uint256) {
        if (!presaleFinalized && account == address(this)) return 0;
        if (_isExcludedFromReflections[account]) return _tOwned[account];
        return tokenFromReflection(_rOwned[account]);
    }

    function isExcluded(address account) public view returns (bool) {
        return _isExcludedFromReflections[account];
    }

    function reflectionFromToken(uint256 tAmount) public view returns (uint256) {
        if (tAmount > _tTotal) revert MaxSupply();
        uint256 rAmount = tAmount * _getRate();
        return rAmount;
    }

    function tokenFromReflection(uint256 rAmount) public view returns (uint256) {
        if (rAmount > _rTotal) revert MaxSupply();
        return rAmount / _getRate();
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC20).interfaceId || interfaceId == type(IERC165).interfaceId;
    }

    // --------------------------- INTERNAL FUNCTIONS --------------------------- //

    function _processBonus(uint256 amount, uint16 bonus, bytes32[] memory merkleProof)
        internal
        view
        returns (uint256)
    {
        if (bonus > 0) {
            bytes32 leaf = keccak256(abi.encodePacked(msg.sender, bonus));
            if (!MerkleProof.verify(merkleProof, _merkleRoot, leaf)) revert IncorrectBonus();
            uint256 bonusAmount = amount * bonus / 10000;
            amount += bonusAmount;
        }
        return amount;
    }

    function _processIncentiveFee(address receiver, uint256 amount) internal returns (uint256) {
        uint256 rValue = reflectionFromToken(amount);
        uint256 rIncentive = FullMath.mulDiv(rValue, incentiveFee, 10000);
        uint256 tIncentive = FullMath.mulDiv(amount, incentiveFee, 10000);
        _rOwned[address(this)] -= rIncentive;
        _rOwned[receiver] += rIncentive;
        if (_isExcludedFromReflections[receiver]) _tOwned[receiver] += tIncentive;
        return amount - tIncentive;
    }

    function _distributeTokens() internal {
        IERC20 titanX = IERC20(TITANX);
        uint256 availableTitanX = titanX.balanceOf(address(this));
        titanLpPool = availableTitanX * LP_POOL_PERCENT / 100;
        scaleLpPool = titanLpPool / 10 ** 9;
        bdxBuyBurnPool = availableTitanX * BDX_BUY_BURN_PERCENT / 100;
        uint256 dragonVaultAmount = availableTitanX * DRAGONX_VAULT_PERCENT / 100;
        uint256 heliosVaultAmount = availableTitanX * HELIOS_VAULT_PERCENT / 100;
        uint256 devAmount = availableTitanX * DEV_PERCENT / 100;
        uint256 genesisAmount = availableTitanX * GENESIS_PERCENT / 100;
        uint256 shedAmount = availableTitanX - titanLpPool - bdxBuyBurnPool - dragonVaultAmount - heliosVaultAmount
            - devAmount - genesisAmount;

        titanX.safeTransfer(dragonXVault, dragonVaultAmount);
        titanX.safeTransfer(heliosVault, heliosVaultAmount);
        titanX.safeTransfer(devWallet, devAmount);
        titanX.safeTransfer(owner(), genesisAmount);
        titanX.safeTransfer(shedContract, shedAmount);
        IDragonX(dragonXVault).updateVault();
    }

    function _addLiquidity(
        address tokenAddress,
        uint256 tokenAmount,
        uint256 scaleAmount
    ) internal {
        (uint256 pairBalance, address pairAddress) = _checkPoolValidity(tokenAddress);
        if (pairBalance > 0) _fixPool(pairAddress, tokenAmount, scaleAmount, pairBalance);

        if (tokenAddress == BDX_ADDRESS) {
            if (pairAddress == address(0)) {
                pairAddress = IUniswapV2Factory(UNISWAP_V2_FACTORY).createPair(address(this), tokenAddress);
            }
            excludeAccountFromReflections(pairAddress);
        }
        if (pairBalance > 0) {
            _update(address(this), pairAddress, scaleAmount);
            IERC20(tokenAddress).transfer(pairAddress, tokenAmount);
            IUniswapV2Pair(pairAddress).mint(address(0));
        } else {
            IERC20(address(this)).safeIncreaseAllowance(UNISWAP_V2_ROUTER, scaleAmount);
            IERC20(tokenAddress).safeIncreaseAllowance(UNISWAP_V2_ROUTER, tokenAmount);
            IUniswapV2Router02(UNISWAP_V2_ROUTER).addLiquidity(
                address(this),
                tokenAddress,
                scaleAmount,
                tokenAmount,
                scaleAmount,
                tokenAmount,
                address(0), //send governance tokens directly to zero address
                block.timestamp
            );
        }
    }

    function _checkPoolValidity(address target) internal returns (uint256, address) {
        address pairAddress = IUniswapV2Factory(UNISWAP_V2_FACTORY).getPair(address(this), target);
        if (pairAddress == address(0)) return (0, pairAddress);
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);

        pair.skim(owner());
        (uint112 reserve0, uint112 reserve1,) = pair.getReserves();
        if (reserve0 != 0) return (reserve0, pairAddress);
        if (reserve1 != 0) return (reserve1, pairAddress);
        return (0, pairAddress);
    }

    function _fixPool(address pairAddress, uint256 tokenAmount, uint256 scaleAmount, uint256 currentBalance) internal {
        uint256 requiredScale = currentBalance * scaleAmount / tokenAmount;
        if(requiredScale == 0) requiredScale = 1;
        uint256 rAmount = requiredScale * _getRate();
        _rOwned[pairAddress] += rAmount;
        if (_isExcludedFromReflections[pairAddress]) _tOwned[pairAddress] += requiredScale;
        _rTotal += rAmount;
        _tTotal += requiredScale;
        emit Transfer(address(0), pairAddress, requiredScale);
        IUniswapV2Pair(pairAddress).sync();
    }

    function _enableTrading() internal {
        tradingEnabled = true;
        emit TradingEnabled();
    }

    // --------------------------- SWAP FUNCTIONS --------------------------- //

    function _swapETHForTitanX(uint256 minAmountOut, uint256 deadline) internal returns (uint256) {
        IWETH9(WETH9).deposit{value: msg.value}();

        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: WETH9,
            tokenOut: TITANX,
            fee: POOL_FEE_1PERCENT,
            recipient: address(this),
            deadline: deadline,
            amountIn: msg.value,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });
        IERC20(WETH9).safeIncreaseAllowance(UNISWAP_V3_ROUTER, msg.value);
        uint256 amountOut = ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(params);
        return amountOut;
    }

    function _swapScaleToDragonX(uint256 amountIn, uint256 minAmountOut, uint256 deadline) internal {
        IERC20(address(this)).safeIncreaseAllowance(UNISWAP_V2_ROUTER, amountIn);
        address[] memory path = new address[](2);
        path[0] = address(this);
        path[1] = DRAGONX_ADDRESS;

        IUniswapV2Router02(UNISWAP_V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minAmountOut, path, bdxBuyBurnAddress, deadline
        );
    }

    function _swapTitanXToToken(address outputToken, uint256 amount, uint256 minAmountOut, uint256 deadline)
        internal
        returns (uint256)
    {
        if (outputToken == DRAGONX_ADDRESS) return _swapUniswapV3Pool(outputToken, amount, minAmountOut, deadline);
        if (outputToken == E280_ADDRESS) return _swapUniswapV2Pool(outputToken, amount, minAmountOut, deadline);
        return _swapMultihop(outputToken, DRAGONX_ADDRESS, amount, minAmountOut, deadline);
    }

    function _swapUniswapV3Pool(address outputToken, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        internal
        returns (uint256)
    {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: TITANX,
            tokenOut: outputToken,
            fee: POOL_FEE_1PERCENT,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });
        IERC20(TITANX).safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountIn);
        uint256 amountOut = ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(params);
        return amountOut;
    }

    function _swapUniswapV2Pool(address outputToken, uint256 amountIn, uint256 minAmountOut, uint256 deadline)
        internal
        returns (uint256)
    {
        IERC20(TITANX).safeIncreaseAllowance(UNISWAP_V2_ROUTER, amountIn);
        uint256 previous = IERC20(outputToken).balanceOf(address(this));
        address[] memory path = new address[](2);
        path[0] = TITANX;
        path[1] = outputToken;

        IUniswapV2Router02(UNISWAP_V2_ROUTER).swapExactTokensForTokensSupportingFeeOnTransferTokens(
            amountIn, minAmountOut, path, address(this), deadline
        );

        return IERC20(outputToken).balanceOf(address(this)) - previous;
    }

    function _swapMultihop(
        address outputToken,
        address midToken,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256) {
        bytes memory path = abi.encodePacked(TITANX, POOL_FEE_1PERCENT, midToken, POOL_FEE_1PERCENT, outputToken);

        ISwapRouter.ExactInputParams memory params = ISwapRouter.ExactInputParams({
            path: path,
            recipient: address(this),
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut
        });
        IERC20(TITANX).safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountIn);
        uint256 amoutOut = ISwapRouter(UNISWAP_V3_ROUTER).exactInput(params);
        return amoutOut;
    }

    // --------------------------- REFLECTIONS FUNCTIONS --------------------------- //

    function _rMint(address account, uint256 tAmount) internal {
        uint256 rAmount = tAmount * _getRate();
        _rOwned[address(this)] -= rAmount;
        _rOwned[msg.sender] += rAmount;
        if (_isExcludedFromReflections[account]) _tOwned[msg.sender] += tAmount;
        _totalMinted += tAmount;
        emit Transfer(address(0), account, tAmount);
    }

    function _rBurn(address account, uint256 tAmount) internal {
        uint256 rBurn = tAmount * _getRate();
        _balanceCheck(account, rBurn, tAmount);
        _rOwned[account] -= rBurn;
        if (_isExcludedFromReflections[account]) _tOwned[account] -= tAmount;
        _rTotal -= rBurn;
        _tTotal -= tAmount;
        totalBurned += tAmount;
        emit Transfer(account, address(0), tAmount);
    }

    function _update(address from, address to, uint256 value) internal override {
        if (tradingEnabled) {
            (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 rReserve, uint256 tTransferAmount) =
                _getValues(value);
            _balanceCheck(from, rAmount, value);
            _rOwned[from] -= rAmount;
            if (_isExcludedFromReflections[from]) _tOwned[from] -= value;
            _rOwned[to] += rTransferAmount;
            if (_isExcludedFromReflections[to]) _tOwned[to] += tTransferAmount;
            _rOwned[address(this)] += rReserve;
            _reflectFee(rFee);
            emit Transfer(from, to, tTransferAmount);
        } else {
            if (from != address(this)) revert TradingDisabled();
            // no fees during LP deployment
            uint256 rValue = value * _getRate();
            _rOwned[from] -= rValue;
            _rOwned[to] += rValue;
            if (_isExcludedFromReflections[to]) _tOwned[to] += value;
            emit Transfer(from, to, value);
        }
    }

    function _balanceCheck(address from, uint256 rAmount, uint256 value) internal view {
        uint256 fromBalance = _rOwned[from];
        if (fromBalance < rAmount) {
            revert ERC20InsufficientBalance(from, tokenFromReflection(fromBalance), value);
        }
    }

    function _reflectFee(uint256 rFee) private {
        _rTotal -= rFee;
    }

    function _getValues(uint256 tAmount) private view returns (uint256, uint256, uint256, uint256, uint256) {
        (uint256 tTransferAmount, uint256 tFee, uint256 tReserve) = _getTValues(tAmount);
        uint256 currentRate = _getRate();
        (uint256 rAmount, uint256 rTransferAmount, uint256 rFee, uint256 rReserve) =
            _getRValues(tAmount, tFee, tReserve, currentRate);
        return (rAmount, rTransferAmount, rFee, rReserve, tTransferAmount);
    }

    function _getTValues(uint256 tAmount) private view returns (uint256, uint256, uint256) {
        uint256 tFee = FullMath.mulDivRoundingUp(tAmount, reflectionFee, 10000);
        uint256 tReserve = tAmount / 100;
        uint256 tTransferAmount = tAmount - tFee - tReserve;
        return (tTransferAmount, tFee, tReserve);
    }

    function _getRValues(uint256 tAmount, uint256 tFee, uint256 tReserve, uint256 currentRate)
        private
        pure
        returns (uint256, uint256, uint256, uint256)
    {
        uint256 rAmount = tAmount * currentRate;
        uint256 rFee = tFee * currentRate;
        uint256 rReserve = tReserve * currentRate;
        uint256 rTransferAmount = rAmount - rFee - rReserve;
        return (rAmount, rTransferAmount, rFee, rReserve);
    }

    function _getRate() private view returns (uint256) {
        (uint256 rSupply, uint256 tSupply) = _getCurrentSupply();
        return rSupply / tSupply;
    }

    function _getCurrentSupply() private view returns (uint256, uint256) {
        uint256 rSupply = _rTotal;
        uint256 tSupply = _tTotal;
        for (uint256 i = 0; i < _excluded.length; i++) {
            address account = _excluded[i];
            uint256 rValue = _rOwned[account];
            uint256 tValue = _tOwned[account];
            if (rValue > rSupply || tValue > tSupply) return (_rTotal, _tTotal);
            rSupply -= rValue;
            tSupply -= tValue;
        }
        if (rSupply < _rTotal / _tTotal) return (_rTotal, _tTotal);
        return (rSupply, tSupply);
    }
}
