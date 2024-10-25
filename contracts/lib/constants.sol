// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// ===================== Contract Addresses =====================================
uint8 constant NUM_ECOSYSTEM_TOKENS = 5;

address constant WETH9 = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
address constant TITANX = 0xF19308F923582A6f7c465e5CE7a9Dc1BEC6665B1;
address constant DRAGONX_ADDRESS = 0x96a5399D07896f757Bd4c6eF56461F58DB951862;
address constant BDX_ADDRESS = 0x9f278Dc799BbC61ecB8e5Fb8035cbfA29803623B;
address constant HYDRA_ADDRESS = 0xCC7ed2ab6c3396DdBc4316D2d7C1b59ff9d2091F;
address constant E280_ADDRESS = 0xe9A53C43a0B58706e67341C4055de861e29Ee943;

address constant DRAGONX_HYDRA_POOL = 0xF8F0Ef9f6A12336A1e035adDDbD634F3B0962F54;
address constant TITANX_DRAGONX_POOL = 0x25215d9ba4403b3DA77ce50606b54577a71b7895;

// ===================== Presale ================================================
uint256 constant MAX_VALUE = ~uint256(0);
uint256 constant PRESALE_LENGTH = 14 days;

// ===================== Presale Allocations ====================================
uint256 constant LP_POOL_PERCENT = 35;
uint256 constant BDX_BUY_BURN_PERCENT = 35;
uint256 constant DRAGONX_VAULT_PERCENT = 5;
uint256 constant HELIOS_VAULT_PERCENT = 5;
uint256 constant SHED_PERCENT = 11;
uint256 constant DEV_PERCENT = 8;
uint256 constant GENESIS_PERCENT = 1;

// ===================== HYDRA Interface ========================================
uint256 constant START_MAX_MINT_COST = 1e11 ether;
uint256 constant MAX_MINT_POWER_CAP = 10_000;
uint256 constant MAX_MINT_LENGTH = 88;
uint256 constant MAX_MINT_PER_WALLET = 1000;
uint8 constant MAX_AVAILABLE_MINERS = 20;
uint8 constant MIN_AVAILABLE_MINERS = 4;

// ===================== UNISWAP Interface ======================================

address constant UNISWAP_V2_FACTORY = 0x5C69bEe701ef814a2B6a3EDD4B1652CB9cc5aA6f;
address constant UNISWAP_V2_ROUTER = 0x7a250d5630B4cF539739dF2C5dAcb4c659F2488D;
address constant UNISWAP_V3_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;
uint24 constant POOL_FEE_1PERCENT = 10000;
