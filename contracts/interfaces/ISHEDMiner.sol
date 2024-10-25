// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

interface ISHEDMiner {
    function deployMiner(uint256 mintPower, uint256 numOfDays, uint256 minerCost) external;
    function claimMiner(uint256 id) external returns (uint256);
}
