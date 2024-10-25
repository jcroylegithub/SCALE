// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@openzeppelin/contracts/interfaces/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "@uniswap/v3-periphery/contracts/interfaces/ISwapRouter.sol";
import "./SHEDMiner.sol";
import "./interfaces/ISHEDMiner.sol";
import "./interfaces/IHydra.sol";
import "./lib/constants.sol";
import "./lib/OracleLibrary.sol";
import "./lib/TickMath.sol";
import "./lib/FullMath.sol";

contract SHED is Ownable2Step {
    using SafeERC20 for IERC20;

    // --------------------------- STATE VARIABLES --------------------------- //

    uint256 public numInstances;
    address public activeInstance;
    address public bdxBuyBurnAddress;
    address public futureRewardsAddress;

    /// @notice Reserve SHED Fund.
    uint256 public reserve;

    /// @notice Max TitanX allocation per miner.
    uint256 public maxPerMiner = 50_000_000_000 ether;

    /// @notice Basis point percentage of HYDRA tokens sent to caller as a reward for calling claimMiner.
    uint16 public incentiveFee = 30;

    /// @notice Time used for TWAP calculation
    uint32 public secondsAgo = 5 * 60;

    /// @notice Allowed deviation of the minAmountOut from historical price.
    uint32 public deviation = 2000;

    /// @notice Percentage of the Hydra tokens to be swapped to TitanX and reinvested in miners.
    uint32 public reinvestPercentage = 3000;

    /// @notice Percentage of the Hydra tokens to be swapped to DragonX and sent to BDX Buy & Burn.
    uint32 public buyBurnPercentage = 3000;

    /// @notice Percentage of the Hydra tokens to be swapped to DragonX and kept in the SHED Reserve Fund.
    uint32 public reservePercentage = 4000;

    /// @notice Total miners deployed right now.
    uint8 public totalActiveMiners;

    /// @notice Is SHED currently active.
    bool public isActive;

    /// @notice Number of acitve miners per a specific miner type (length).
    mapping(uint8 minerType => uint8) public numActiveMiners;

    /// @notice SHEDMiner instances.
    mapping(uint256 instanceId => address) public instances;

    mapping(address => bool) private _isShedMinerInstance;
    uint8[] private _availableMinerTypes;

    // ------------------------------- ERRORS -------------------------------- //

    error ZeroAddress();
    error Unauthorized();
    error SHED_Inactive();
    error InsufficientPower();
    error MinerTypeUnavailable();
    error IncorrectMinersAmount();
    error IncorrectMinerType();
    error Prohibited();
    error IncorrectInput();
    error TWAP();

    // --------------------------- EVENTS & MODIFIERS ------------------------ //

    event MinerDeployed(uint8 minerType);
    event MinerClaimed(uint256 minerId, uint256 buyBurnShare);
    event ReseveDistribution(uint256 buyBurnShare, uint256 reinvestShare, uint256 futureRewardsShare);
    event NewSHEDInstance(uint256 instanceId, address instanceAddress);
    event MinerTypesUpdate();

    modifier originCheck() {
        if (address(msg.sender).code.length != 0 || msg.sender != tx.origin) revert Unauthorized();
        _;
    }

    // --------------------------- CONSTRUCTOR --------------------------- //

    constructor(address _owner, address _bdxBuyBurnAddress, address _futureRewardsAddress) Ownable(_owner) {
        if (_owner == address(0)) revert ZeroAddress();
        if (_bdxBuyBurnAddress == address(0)) revert ZeroAddress();
        if (_futureRewardsAddress == address(0)) revert ZeroAddress();

        _deployInstance();
        bdxBuyBurnAddress = _bdxBuyBurnAddress;
        futureRewardsAddress = _futureRewardsAddress;
    }

    // --------------------------- PUBLIC FUNCTIONS --------------------------- //

    /// @notice Deploys a Hydra Miner of the specified type.
    /// @param minerType The type of the miner to deploy (length).
    function deployMiner(uint8 minerType) external originCheck {
        if (!isActive) revert SHED_Inactive();
        uint256 availableMinerNum = _availableMinerTypes.length;
        uint8 allowedMinerTypeAmount;
        for (uint256 i = 0; i < availableMinerNum; i++) {
            if (_availableMinerTypes[i] == minerType) allowedMinerTypeAmount++;
        }
        if (numActiveMiners[minerType] >= allowedMinerTypeAmount) revert MinerTypeUnavailable();
        (uint256 minerPower, uint256 minerCost) = getCurrentMinerParams();
        if (minerPower == 0) revert InsufficientPower();
        IERC20(TITANX).safeTransfer(activeInstance, minerCost);
        ISHEDMiner(activeInstance).deployMiner(minerPower, minerType, minerCost);
        numActiveMiners[minerType]++;
        totalActiveMiners++;
        emit MinerDeployed(minerType);
    }

    /// @notice Claim a miner and distributes Hydra.
    /// @param instance Address of the SHEDMiner instance.
    /// @param id The ID of the miner being claimed.
    /// @param minAmountOutDragonX The minimum amount of DragonX tokens to receive from the swap.
    /// @param minAmountOutTitanX The minimum amount of TitanX tokens to receive from the swap.
    /// @param deadline The deadline for executing the swap transactions.
    function claimMiner(address instance, uint256 id, uint256 minAmountOutDragonX, uint256 minAmountOutTitanX, uint256 deadline)
        external
        originCheck
    {
        if (!_isShedMinerInstance[instance]) revert Prohibited();
        uint8 minerType = IHydra(HYDRA_ADDRESS).getUserMintInfo(instance, id).numOfDays;
        ISHEDMiner(instance).claimMiner(id);
        uint256 hydraAmount = IERC20(HYDRA_ADDRESS).balanceOf(address(this));
        hydraAmount = _processIncentiveFee(msg.sender, hydraAmount);

        _twapCheck(HYDRA_ADDRESS, DRAGONX_ADDRESS, hydraAmount, minAmountOutDragonX);
        _swapUniswapV3Pool(HYDRA_ADDRESS, DRAGONX_ADDRESS, address(this), hydraAmount, minAmountOutDragonX, deadline);

        uint256 dragonXAmount = IERC20(DRAGONX_ADDRESS).balanceOf(address(this)) - reserve;
        uint256 buyBurnShare = FullMath.mulDiv(dragonXAmount, buyBurnPercentage, 10000);
        IERC20(DRAGONX_ADDRESS).safeTransfer(bdxBuyBurnAddress, buyBurnShare);

        uint256 reserveShare = FullMath.mulDiv(dragonXAmount, reservePercentage, 10000);
        reserve += reserveShare;

        uint256 reinvestShare = FullMath.mulDiv(dragonXAmount, reinvestPercentage, 10000);
        _twapCheck(DRAGONX_ADDRESS, TITANX, reinvestShare, minAmountOutTitanX);
        _swapUniswapV3Pool(DRAGONX_ADDRESS, TITANX, address(this), reinvestShare, minAmountOutTitanX, deadline);

        numActiveMiners[minerType]--;
        totalActiveMiners--;
        emit MinerClaimed(id, buyBurnShare);
    }

    /// @notice Creates a new instance of the SHEDMiner contract.
    function createNewInstance() external {
        uint256 lastId = IHydra(HYDRA_ADDRESS).getUserLatestMintId(activeInstance);
        if (lastId < MAX_MINT_PER_WALLET) revert Prohibited();
        _deployInstance();
    }

    // --------------------------- ADMINISTRATIVE FUNCTIONS --------------------------- //

    /// @notice Distributes the reserve fund into BDX Buy & Burn, reinvestment, and future rewards allocations.
    /// @param bdxBuyBurn The percentage of the reserve to send to BDX Buy & Burn.
    /// @param reinvest The percentage of the reserve to swap to TitanX and reinvest in miners.
    /// @param futureRewards The percentage of the reserve to send to future rewards.
    /// @param minAmountOutTitanX The minimum amount of TitanX tokens to receive from the reinvestment swap.
    /// @param deadline The deadline for executing the swap transactions.
    /// @dev Can only be called by the owner.
    function distributeReserveFund(
        uint32 bdxBuyBurn,
        uint32 reinvest,
        uint32 futureRewards,
        uint256 minAmountOutTitanX,
        uint256 deadline
    ) external onlyOwner {
        if (reserve == 0) revert Prohibited();
        if (bdxBuyBurn + reinvest + futureRewards > 10000) revert IncorrectInput();
        uint256 buyBurnShare;
        uint256 reinvestShare;
        uint256 futureRewardsShare;
        if (bdxBuyBurn > 0) {
            buyBurnShare = FullMath.mulDiv(reserve, bdxBuyBurn, 10000);
            IERC20(DRAGONX_ADDRESS).safeTransfer(bdxBuyBurnAddress, buyBurnShare);
        }
        if (futureRewards > 0) {
            futureRewardsShare = FullMath.mulDiv(reserve, futureRewards, 10000);
            IERC20(DRAGONX_ADDRESS).safeTransfer(futureRewardsAddress, futureRewardsShare);
        }
        if (reinvest > 0) {
            reinvestShare = FullMath.mulDiv(reserve, reinvest, 10000);
            _swapUniswapV3Pool(DRAGONX_ADDRESS, TITANX, address(this), reinvestShare, minAmountOutTitanX, deadline);
        }
        reserve -= buyBurnShare + reinvestShare + futureRewardsShare;
        emit ReseveDistribution(buyBurnShare, reinvestShare, futureRewardsShare);
    }

    /// @notice Sets the available miner types that can be deployed.
    /// @param types An array of miner types (legths) to set as available.
    /// @dev Can only be called by the owner.
    function setAvailableMinerTypes(uint8[] calldata types) external onlyOwner {
        if (types.length < MIN_AVAILABLE_MINERS || types.length > MAX_AVAILABLE_MINERS) revert IncorrectMinersAmount();
        for (uint256 i = 0; i < types.length; i++) {
            uint8 type_ = types[i];
            if (type_ == 0 || type_ > MAX_MINT_LENGTH) revert IncorrectMinerType();
        }
        _availableMinerTypes = types;
        emit MinerTypesUpdate();
    }

    /// @notice Sets the maximum allocation per miner in the contract.
    /// @param limit The maximum limit for tokens allocated per miner.
    /// @dev Can only be called by the owner.
    function setMaxPerMiner(uint256 limit) external onlyOwner {
        if (limit == 0) revert IncorrectInput();
        maxPerMiner = limit;
    }

    /// @notice Sets the BDX Buy & Burn contract address.
    /// @param _address The address of the BDX Buy & Burn contract.
    /// @dev Can only be called by the owner.
    function setBDXBuyBurn(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        bdxBuyBurnAddress = _address;
    }

    /// @notice Sets the Future Rewards wallet address.
    /// @param _address The address of the Future Rewards wallet.
    /// @dev Can only be called by the owner.
    function setFutureRewards(address _address) external onlyOwner {
        if (_address == address(0)) revert ZeroAddress();
        futureRewardsAddress = _address;
    }

    /// @notice Sets the percentages for reinvestment, BDX Buy & Burn, and SHED Reserve Fund allocation during claims.
    /// @param _reinvestPercentage The percentage allocated for reinvestment.
    /// @param _buyBurnPercentage The percentage allocated for BDX Buy & Burn.
    /// @param _reservePercentage The percentage allocated for SHED Reserve Fund.
    /// @dev Can only be called by the owner.
    function setClaimPercentages(uint32 _reinvestPercentage, uint32 _buyBurnPercentage, uint32 _reservePercentage)
        external
        onlyOwner
    {
        if (_reinvestPercentage + _buyBurnPercentage + _reservePercentage != 10000) revert IncorrectInput();
        reinvestPercentage = _reinvestPercentage;
        buyBurnPercentage = _buyBurnPercentage;
        reservePercentage = _reservePercentage;
    }

    /// @notice Sets the number of seconds to look back for TWAP price calculations.
    /// @param limit The number of seconds to use for TWAP price lookback.
    function setSecondsAgo(uint32 limit) external onlyOwner {
        if (limit == 0) revert IncorrectInput();
        secondsAgo = limit;
    }

    /// @notice Sets the allowed price deviation for TWAP checks.
    /// @param limit The allowed deviation in basis points (e.g., 500 = 5%).
    function setDeviation(uint32 limit) external onlyOwner {
        if (limit == 0) revert IncorrectInput();
        if (limit > 10000) revert IncorrectInput();
        deviation = limit;
    }

    /// @notice Sets the Incentive fee size.
    /// @param bps Incentive fee in basis points (30 = 0.3%).
    /// @dev Can only be called by the owner.
    function setIncentiveFee(uint16 bps) external onlyOwner {
        if (bps < 30 || bps > 500) revert Prohibited();
        incentiveFee = bps;
    }

    /// @notice Activates the SHED contract, allowing miners to be deployed.
    /// @dev The SHED can only be activated if there are available miner types.
    function activateSHED() external onlyOwner {
        if (_availableMinerTypes.length == 0) revert IncorrectMinersAmount();
        isActive = true;
    }

    // --------------------------- VIEW FUNCTIONS --------------------------- //

    /// @notice Returns the current mint power and miner cost for deploying a miner.
    /// @return mintPower The power allocated to the miner based on the available funds.
    /// @return minerCost The cost to deploy a miner, limited by the max per miner cap.
    function getCurrentMinerParams() public view returns (uint256 mintPower, uint256 minerCost) {
        if (totalActiveMiners >= _availableMinerTypes.length) return (0, 0);
        uint256 availableAmount = IERC20(TITANX).balanceOf(address(this));
        uint256 share = availableAmount / (_availableMinerTypes.length - totalActiveMiners);
        minerCost = share > maxPerMiner ? maxPerMiner : share;
        mintPower = (minerCost * MAX_MINT_POWER_CAP) / (START_MAX_MINT_COST);
        return mintPower > MAX_MINT_POWER_CAP ? (MAX_MINT_POWER_CAP, START_MAX_MINT_COST) : (mintPower, minerCost);
    }

    /// @notice Returns the IDs of all active miners in the current and previous instances.
    /// @return ids An array of active miner IDs.
    /// @return minerInstances An array of the respective SHEDMiner instances.
    function getActiveMinerIds() external view returns (uint256[] memory ids, address[] memory minerInstances) {
        (ids, minerInstances) = _getActiveIds(activeInstance, totalActiveMiners);
        if (totalActiveMiners > 0 && ids[totalActiveMiners - 1] == 0) {
            uint256 emptyIds;
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == 0) emptyIds++;
            }
            (uint256[] memory oldIds, address[] memory oldInstances) = _getActiveIds(instances[numInstances - 2], emptyIds);
            uint256 counter;
            for (uint256 i = 0; i < ids.length; i++) {
                if (ids[i] == 0) {
                    ids[i] = oldIds[counter];
                    minerInstances[i] = oldInstances[counter++];
                }
            }
        }
        return (ids, minerInstances);
    }

    /// @notice Returns the list of available miner types that can be deployed.
    /// @return An array of available miner types (lengths).
    function availableMinerTypes() external view returns (uint8[] memory) {
        return _availableMinerTypes;
    }

    // --------------------------- INTERNAL FUNCTIONS --------------------------- //

    function _processIncentiveFee(address receiver, uint256 amount) internal returns (uint256) {
        uint256 incentive = FullMath.mulDiv(amount, incentiveFee, 10000);
        IERC20(HYDRA_ADDRESS).safeTransfer(receiver, incentive);
        return amount - incentive;
    }

    function _twapCheck(address tokenIn, address tokenOut, uint256 amountIn, uint256 minAmountOut) internal view {
        address poolAddress = tokenIn == HYDRA_ADDRESS ? DRAGONX_HYDRA_POOL : TITANX_DRAGONX_POOL;
        uint32 _secondsAgo = secondsAgo;
        uint32 oldestObservation = OracleLibrary.getOldestObservationSecondsAgo(poolAddress);
        if (oldestObservation < _secondsAgo) {
            _secondsAgo = oldestObservation;
        }

        (int24 arithmeticMeanTick,) = OracleLibrary.consult(poolAddress, _secondsAgo);
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(arithmeticMeanTick);
        uint256 twapAmountOut =
            OracleLibrary.getQuoteForSqrtRatioX96(sqrtPriceX96, uint128(amountIn), tokenIn, tokenOut);
        
        uint256 lowerBound = (twapAmountOut * (10000 - deviation)) / 10000;
        if (minAmountOut < lowerBound) revert TWAP();
    }

    function _getActiveIds(address instance, uint256 amount) internal view returns (uint256[] memory ids, address[] memory minerInstances) {
        ids = new uint256[](amount);
        minerInstances = new address[](amount);
        if (amount == 0) return (ids, minerInstances);
        IHydra hydra = IHydra(HYDRA_ADDRESS);
        uint256 lastId = hydra.getUserLatestMintId(instance);
        uint256 counter;
        for (uint256 i = lastId; i > 0; i--) {
            if (hydra.getUserMintInfo(instance, i).status == IHydra.MintStatus.ACTIVE) {
                ids[counter] = i;
                minerInstances[counter++] = instance;
                if (counter == amount) break;
            }
        }
        return (ids, minerInstances);
    }

    function _deployInstance() private {
        bytes memory bytecode = type(SHEDMiner).creationCode;
        uint256 instanceId = numInstances++;
        bytes32 salt = keccak256(abi.encodePacked(address(this), instanceId));
        address newInstance = Create2.deploy(0, salt, bytecode);
        activeInstance = newInstance;
        instances[instanceId] = newInstance;
        _isShedMinerInstance[newInstance] = true;
        emit NewSHEDInstance(instanceId, newInstance);
    }

    function _swapUniswapV3Pool(
        address inputToken,
        address outputToken,
        address recipient,
        uint256 amountIn,
        uint256 minAmountOut,
        uint256 deadline
    ) internal returns (uint256) {
        ISwapRouter.ExactInputSingleParams memory params = ISwapRouter.ExactInputSingleParams({
            tokenIn: inputToken,
            tokenOut: outputToken,
            fee: POOL_FEE_1PERCENT,
            recipient: recipient,
            deadline: deadline,
            amountIn: amountIn,
            amountOutMinimum: minAmountOut,
            sqrtPriceLimitX96: 0
        });
        IERC20(inputToken).safeIncreaseAllowance(UNISWAP_V3_ROUTER, amountIn);
        return ISwapRouter(UNISWAP_V3_ROUTER).exactInputSingle(params);
    }
}
