// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Ethereum mainnet addresses for fork tests. Every entry was read on chain
///         (publicnode RPC) on 2026-10-16 around block-time 1792127100; the readings in
///         the comments are snapshots from that moment, not invariants.
library Mainnet {
    // ---------------------------------------------------------------- A. Tokens
    // WETH9, symbol "WETH", 18 dec
    address internal constant WETH = 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2;
    // Lido wstETH, symbol "wstETH", 18 dec, stEthPerToken() = 1.246393484391905431e18
    address internal constant WSTETH = 0x7f39C581F595B53c5cb19bD0b3f8dA6c935E2Ca0;
    // Coinbase cbBTC, symbol "cbBTC", 8 dec
    address internal constant CBBTC = 0xcbB7C0000aB88B473b1f5aFd9ef808440eed33Bf;
    // WBTC, symbol "WBTC", 8 dec
    address internal constant WBTC = 0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599;
    // Circle USDC, symbol "USDC", 6 dec
    address internal constant USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    // Tether USDT, symbol "USDT", 6 dec (non-standard ERC20: no bool return on transfer/approve)
    address internal constant USDT = 0xdAC17F958D2ee523a2206206994597C13D831ec7;
    // Sky USDS, symbol "USDS", 18 dec
    address internal constant USDS = 0xdC035D45d973E3EC169d2276DDab16f1e407384F;
    // Maker DAI, symbol "DAI", 18 dec
    address internal constant DAI = 0x6B175474E89094C44Da98b954EedeAC495271d0F;
    // Sky sUSDS ERC-4626, symbol "sUSDS", 18 dec, asset() = USDS, convertToAssets(1e18) = 1.112973325344857252e18
    address internal constant SUSDS = 0xa3931d71877C0E7a3148CB7Eb4463524FEc27fbD;

    // ------------------------------------------- B. Chainlink aggregator proxies
    // Chainlink ETH/USD, 8 dec, description "ETH / USD", heartbeat 3600s, deviation 0.5%
    address internal constant CL_ETH_USD = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    // Chainlink stETH/USD, 8 dec, description "STETH / USD", heartbeat 3600s, deviation 1%
    address internal constant CL_STETH_USD = 0xCfE54B5cD566aB89272946F602D76Ea879CAb4a8;
    // Chainlink BTC/USD, 8 dec, description "BTC / USD", heartbeat 3600s, deviation 0.5%
    address internal constant CL_BTC_USD = 0xF4030086522a5bEEa4988F8cA5B36dbC97BeE88c;
    // Chainlink WBTC/BTC, 8 dec, description "WBTC / BTC", heartbeat 86400s, deviation 0.5% (read 0.998)
    address internal constant CL_WBTC_BTC = 0xfdFD9C85aD200c506Cf9e21F1FD8dd01932FBB23;
    // Chainlink cbBTC/USD, 8 dec, description "cbBTC / USD", heartbeat 86400s, deviation 2% (standard, non-SVR)
    address internal constant CL_CBBTC_USD = 0x2665701293fCbEB223D11A08D826563EDcCE423A;
    // Chainlink USDC/USD, 8 dec, description "USDC / USD", heartbeat 82800s (23h), deviation 0.25%
    address internal constant CL_USDC_USD = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    // Chainlink USDT/USD, 8 dec, description "USDT / USD", heartbeat 86400s, deviation 0.25%
    address internal constant CL_USDT_USD = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    // Chainlink DAI/USD, 8 dec, description "DAI / USD", heartbeat 3600s, deviation 0.25%
    address internal constant CL_DAI_USD = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;
    // Chainlink USDS/USD, 8 dec, description "USDS / USD", heartbeat 82800s (23h), deviation 0.3%
    address internal constant CL_USDS_USD = 0xfF30586cD0F29eD462364C7e81375FC0C71219b1;

    // --------------------------------------------------- C. Morpho USDC/USDT vaults
    // Morpho Blue core (morpho() of every V2 adapter below)
    address internal constant MORPHO_BLUE = 0xBBBBBbbBBb9cC5e90e3b3Af64bdAF62C37EEFFCb;
    // Morpho Vault V2 "Gauntlet USDC Prime", asset USDC, curator 0x9E33..0585, totalAssets 119.07M; per-selector timelocks: addAdapter 7d, increaseCap 3d
    address internal constant MORPHO_V2_GAUNTLET_USDC_PRIME = 0x8c106EEDAd96553e64287A5A6839c3Cc78afA3D0;
    // Morpho Vault V2 "Steakhouse Prime USDC", asset USDC, curator 0x827e..eCdB, totalAssets 101.64M; addAdapter/increaseCap 7d, setIsAllocator 0, setPerformanceFee 0
    address internal constant MORPHO_V2_STEAKHOUSE_PRIME_USDC = 0xbeef088055857739C12CD3765F20b7679Def0f51;
    // MetaMorpho (V1) "Steakhouse USDC", asset USDC, curator 0x827e..eCdB, totalAssets 66.63M, timelock() 604800s (7d)
    address internal constant METAMORPHO_STEAKHOUSE_USDC = 0xBEEF01735c132Ada46AA9aA4c54623cAA92A64CB;
    // MetaMorpho (V1) "Gauntlet USDC Prime", asset USDC, curator 0x9E33..0585, totalAssets 24.01M, timelock() 604800s (7d)
    address internal constant METAMORPHO_GAUNTLET_USDC_PRIME = 0xdd0f28e19C1780eb6396170735D45153D261490d;
    // MetaMorpho (V1) "Steakhouse USDT", asset USDT, curator 0x827e..eCdB, totalAssets 77.91M, timelock() 604800s (7d)
    address internal constant METAMORPHO_STEAKHOUSE_USDT = 0xbEef047a543E45807105E51A8BBEFCc5950fcfBa;
    // Morpho Vault V2 "Spark Blue Chip USDT Vault", asset USDT, curator 0x0f96..46A3, totalAssets 79.36M; all checked timelocks 10d
    address internal constant MORPHO_V2_SPARK_USDT = 0xb0c424116172B55CbB6dD3136F5989F7959e5B91;

    // ----------------------------------------------------- D. imdUSD v1 system
    // imdUSD v1 vault (deployed block 26166417); wiring below read from its getters
    address internal constant V1_VAULT = 0x0b69F8DA8D8cE521d74Ea69a7A3475B77302EF82;
    // vault.stablecoin(): "imdUSD", 18 dec, totalSupply 19,540.76
    address internal constant V1_IMDUSD = 0x61aAF8a992A3143e2B0C9cB0030b9fE702854a25;
    // vault.gem(): StakedIMD ERC-4626 "sIMD", 24 dec, asset() = IMD, convertToAssets(1e18) = 7.976e12
    address internal constant SIMD = 0x9Efa934D9fAd4AE28c998a40195646b965a97247;
    // IMD token, symbol "IMD", 18 dec
    address internal constant IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;
    // vault.priceFeed(): ETH per IMD (1e18), latestValue 2.745092056524573e15, isStale() true at read
    address internal constant V1_PRICE_FEED = 0x070e0603737242B01aBC1D223f7C92D63E86EC97;
    // vault.spotFeed(): ETH per IMD spot (1e18), latestValue 2.747546308398796e15, isStale() true at read
    address internal constant V1_SPOT_FEED = 0x77E1684402869Bf2B7c70B8bf21E1C7Ca7104951;
    // vault.nhiFeed(): network health index (1e18), latestValue 0.981718468843365393e18, isStale() false
    address internal constant V1_NHI_FEED = 0x014DabF6F940c9C383D9ef48636F70D842F65D7A;
    // vault.usdPriceFeed(): USD per IMD (1e18), latestValue 6.729373569205468743e18, isStale() true at read
    address internal constant V1_USD_PRICE_FEED = 0x297b85afc6bbF9d9cCa636F7ED74c56DA79287A0;
    // vault.collateralPriceFeed(): SharePriceFeed, USD per sIMD share, latestValue 5.3675207350353e13, isStale() true at read
    address internal constant V1_COLLATERAL_PRICE_FEED = 0xF065C8b65AA9Ac6fd9cBAd15301738e91389d9e1;

    // INFER token, symbol "INFER", 18 dec (read 2026-10-21)
    address internal constant INFER = 0x53d0eA0A685220718Dc6a0a6e4617194C6F37921;
    // StakedInfer ERC-4626 "sINFER", 24 dec, asset() = INFER, per-lot one-block hold (verified source, 2026-10-21)
    address internal constant SINFER = 0x5e3B440156Ce928Fda68b2378578dC9333846cE4;
    // InferDripper: releases INFER into sINFER (drip(), permissionless, hourly catch-up), canDrip() true at read
    address internal constant INFER_DRIPPER = 0x0c1CE09ccfe9243c4ad23C3CAEE0C11D4E8340d3;

    // --------------------------------------------------------- E. Uniswap v4
    // Uniswap v4 PoolManager, code present (24k), owner() 0x1a9C..35BC
    address internal constant UNIV4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    // imdUSD v1 / USDC peg pool id (PegFeeHook pool), recorded not re-derived
    bytes32 internal constant V1_PEG_POOL_ID = 0x3cb8cc9c22f7da5c3169d4059131ddba9e61f68230977797c03a2f1214992035;

    // --------------------------------------------------------- F. Governance
    // Governance Safe, VERSION "1.5.0", getThreshold() 2, getOwners() length 3
    address internal constant GOVERNANCE_SAFE = 0xbeFd108085613662356aa26A2466Ad3426DA9C32;
}
