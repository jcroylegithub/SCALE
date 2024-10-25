// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/interfaces/IERC20.sol";

interface IHydra is IERC20 {
    error Hydra_InvalidCaller();
    error Hydra_InsufficientProtocolFees();
    error Hydra_NothingToDistribute();
    error Hydra_InvalidAmount();
    error Hydra_UnregisteredCA();
    error Hydra_LPTokensHasMinted();
    error Hydra_NotSupportedContract();
    error Hydra_InvalidAddress();
    error Hydra_MaxedWalletMints();
    error Hydra_InvalidMintLadderInterval();
    error Hydra_InvalidMintLadderRange();
    error Hydra_InvalidBatchCount();
    error Hydra_InvalidBurnRewardPercent();
    error Hydra_InsufficientBurnAllowance();
    error Hydra_InvalidMintLength();
    error Hydra_InvalidMintPower();
    error Hydra_NoMintExists();
    error Hydra_MintHasClaimed();
    error Hydra_MintNotMature();
    error Hydra_MintHasBurned();
    error Hydra_MintMaturityNotMet();
    error Hydra_MintHasEnded();

    enum MintStatus {
        ACTIVE,
        CLAIMED,
        BURNED,
        EARLYENDED
    }

    struct UserMintInfo {
        uint16 mintPower;
        uint8 numOfDays;
        uint104 mintableHydra;
        uint48 mintStartTs;
        uint48 maturityTs;
        uint104 mintedHydra;
        uint104 mintCost;
        MintStatus status;
    }

    function startMint(uint256 mintPower, uint256 numOfDays) external;
    function claimMint(uint256 id) external;
    function getUserLatestMintId(address user) external view returns (uint256);
    function getUserMintInfo(address user, uint256 id) external view returns (UserMintInfo memory mintInfo);
    function getCurrentMintableHydra() external view returns (uint256);
}
