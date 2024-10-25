// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

import "./interfaces/IHydra.sol";
import "./lib/constants.sol";

contract SHEDMiner is Ownable {
    using SafeERC20 for IERC20;

    constructor() Ownable(msg.sender) {}

    function deployMiner(uint256 mintPower, uint256 numOfDays, uint256 minerCost) external onlyOwner {
        IERC20(TITANX).safeIncreaseAllowance(HYDRA_ADDRESS, minerCost);
        IHydra(HYDRA_ADDRESS).startMint(mintPower, numOfDays);
    }

    function claimMiner(uint256 id) external onlyOwner returns (uint256) {
        IHydra(HYDRA_ADDRESS).claimMint(id);
        IERC20 hydra = IERC20(HYDRA_ADDRESS);
        uint256 balance = hydra.balanceOf(address(this));
        hydra.safeTransfer(owner(), balance);
        return balance;
    }

    function sendTitanX() external {
        IERC20 titanX = IERC20(TITANX);
        titanX.safeTransfer(owner(), titanX.balanceOf(address(this)));
    }
}
