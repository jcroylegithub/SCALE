// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.10;

interface ITITANX {
    error TitanX_InvalidAmount();
    error TitanX_InsufficientBalance();
    error TitanX_NotSupportedContract();
    error TitanX_InsufficientProtocolFees();
    error TitanX_FailedToSendAmount();
    error TitanX_NotAllowed();
    error TitanX_NoCycleRewardToClaim();
    error TitanX_NoSharesExist();
    error TitanX_EmptyUndistributeFees();
    error TitanX_InvalidBurnRewardPercent();
    error TitanX_InvalidBatchCount();
    error TitanX_InvalidMintLadderInterval();
    error TitanX_InvalidMintLadderRange();
    error TitanX_MaxedWalletMints();
    error TitanX_LPTokensHasMinted();
    error TitanX_InvalidAddress();
    error TitanX_InsufficientBurnAllowance();

    function getBalance() external;

    /**
     * @dev Emitted when `value` tokens are moved from one account (`from`) to
     * another (`to`).
     *
     * Note that `value` may be zero.
     */
    event Transfer(address indexed from, address indexed to, uint256 value);

    /**
     * @dev Emitted when the allowance of a `spender` for an `owner` is set by
     * a call to {approve}. `value` is the new allowance.
     */
    event Approval(address indexed owner, address indexed spender, uint256 value);

    /**
     * @dev Returns the value of tokens in existence.
     */
    function totalSupply() external view returns (uint256);

    /**
     * @dev Returns the value of tokens owned by `account`.
     */
    function balanceOf(address account) external view returns (uint256);

    /**
     * @dev Moves a `value` amount of tokens from the caller's account to `to`.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transfer(address to, uint256 value) external returns (bool);

    /**
     * @dev Returns the remaining number of tokens that `spender` will be
     * allowed to spend on behalf of `owner` through {transferFrom}. This is
     * zero by default.
     *
     * This value changes when {approve} or {transferFrom} are called.
     */
    function allowance(address owner, address spender) external view returns (uint256);

    /**
     * @dev Sets a `value` amount of tokens as the allowance of `spender` over the
     * caller's tokens.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * IMPORTANT: Beware that changing an allowance with this method brings the risk
     * that someone may use both the old and the new allowance by unfortunate
     * transaction ordering. One possible solution to mitigate this race
     * condition is to first reduce the spender's allowance to 0 and set the
     * desired value afterwards:
     * https://github.com/ethereum/EIPs/issues/20#issuecomment-263524729
     *
     * Emits an {Approval} event.
     */
    function approve(address spender, uint256 value) external returns (bool);

    /**
     * @dev Moves a `value` amount of tokens from `from` to `to` using the
     * allowance mechanism. `value` is then deducted from the caller's
     * allowance.
     *
     * Returns a boolean value indicating whether the operation succeeded.
     *
     * Emits a {Transfer} event.
     */
    function transferFrom(address from, address to, uint256 value) external returns (bool);

    function burnTokensToPayAddress(
        address user,
        uint256 amount,
        uint256 userRebatePercentage,
        uint256 rewardPaybackPercentage,
        address rewardPaybackAddress
    ) external;

    function burnTokens(address user, uint256 amount, uint256 userRebatePercentage, uint256 rewardPaybackPercentage)
        external;

    function userBurnTokens(uint256 amount) external;
}
